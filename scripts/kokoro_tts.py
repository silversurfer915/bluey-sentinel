#!/usr/bin/env python3
"""
Kokoro Local TTS Service & CLI for Bluey Sentinel.
Provides ultra-fast local neural speech synthesis with Kokoro-ONNX.
Can run as a background HTTP daemon (port 8765) or as a one-shot CLI.
"""

import sys
import os
import io
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Locate model files
SEARCH_PATHS_ONNX = [
    os.path.expanduser("~/.kokoro/kokoro-v1.0.onnx"),
    os.path.expanduser("~/kokoro-v1.0.onnx"),
    os.path.expanduser("~/Library/Application Support/Googly/models/kokoro-v1.0.onnx"),
]
SEARCH_PATHS_VOICES = [
    os.path.expanduser("~/.kokoro/voices-v1.0.bin"),
    os.path.expanduser("~/voices-v1.0.bin"),
    os.path.expanduser("~/Library/Application Support/Googly/models/voices-v1.0.bin"),
]

def find_file(paths):
    for p in paths:
        if os.path.isfile(p) and os.path.getsize(p) > 1000000:
            return p
    return None

MODEL_PATH = find_file(SEARCH_PATHS_ONNX)
VOICES_PATH = find_file(SEARCH_PATHS_VOICES)

_kokoro_instance = None

def get_kokoro():
    global _kokoro_instance
    if _kokoro_instance is None:
        if not MODEL_PATH or not VOICES_PATH:
            raise RuntimeError(f"Kokoro model files not found. Checked: {SEARCH_PATHS_ONNX}")
        from kokoro_onnx import Kokoro
        _kokoro_instance = Kokoro(model_path=MODEL_PATH, voices_path=VOICES_PATH)
    return _kokoro_instance

def synthesize_wav_bytes(text: str, voice: str = "bm_george", speed: float = 1.0) -> bytes:
    import soundfile as sf
    kokoro = get_kokoro()
    # Normalize language: British voices start with b, American with a
    lang = "en-gb" if voice.startswith("b") else "en-us"
    samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)
    buf = io.BytesIO()
    sf.write(buf, samples, sample_rate, format='WAV')
    return buf.getvalue()

class KokoroHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
            return

        if parsed.path == "/voices":
            try:
                kokoro = get_kokoro()
                voices = kokoro.get_voices()
                import json
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(voices).encode("utf-8"))
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode("utf-8"))
            return

        if parsed.path == "/synthesize":
            params = parse_qs(parsed.query)
            text = params.get("text", [""])[0]
            voice = params.get("voice", ["bm_george"])[0]
            speed = float(params.get("speed", [1.0])[0])

            if not text:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"Missing text parameter")
                return

            try:
                wav_bytes = synthesize_wav_bytes(text, voice=voice, speed=speed)
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Content-Length", str(len(wav_bytes)))
                self.end_headers()
                self.wfile.write(wav_bytes)
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode("utf-8"))
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        # Silence HTTP access logs
        pass

def run_server(port=8765):
    # Pre-warm model in memory
    print(f"[Kokoro] Loading model from {MODEL_PATH}...")
    get_kokoro()
    server = HTTPServer(("127.0.0.1", port), KokoroHandler)
    print(f"[Kokoro] TTS server ready on http://127.0.0.1:{port}")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

def main():
    parser = argparse.ArgumentParser(description="Kokoro TTS service & CLI")
    parser.add_argument("--server", action="store_true", help="Run background HTTP server on port 8765")
    parser.add_argument("--port", type=int, default=8765, help="Server port (default: 8765)")
    parser.add_argument("--text", type=str, help="Text to speak")
    parser.add_argument("--voice", type=str, default="bm_george", help="Voice name (e.g. bm_george, bf_emma, af_heart)")
    parser.add_argument("--out", type=str, help="Output WAV path")
    args = parser.parse_args()

    if args.server:
        run_server(args.port)
        return

    if args.text and args.out:
        wav_bytes = synthesize_wav_bytes(args.text, voice=args.voice)
        with open(args.out, "wb") as f:
            f.write(wav_bytes)
        print(f"Saved {len(wav_bytes)} bytes to {args.out}")
        return

    parser.print_help()

if __name__ == "__main__":
    main()
