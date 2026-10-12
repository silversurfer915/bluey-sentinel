import AVFoundation
import AppKit
import Foundation

/// Bluey's voice: supports local Kokoro neural TTS model (100% offline, natural AI voice)
/// and Google Gemini neural speech synthesis (gemini-3.8-flash-lite-tts), with system fallback.
@MainActor
final class Voice: NSObject, AVAudioPlayerDelegate {
    static let shared = Voice()

    private var audioPlayer: AVAudioPlayer?
    private var macProcess: Process?
    private var serverProcess: Process?
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// Check if Kokoro is installed locally
    static var isKokoroAvailable: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let py = home.appendingPathComponent(".kokoro_env/bin/python3").path
        let model = home.appendingPathComponent(".kokoro/kokoro-v1.0.onnx").path
        let userModel = home.appendingPathComponent("kokoro-v1.0.onnx").path
        let hasPy = FileManager.default.fileExists(atPath: py)
        let hasModel = FileManager.default.fileExists(atPath: model) || FileManager.default.fileExists(atPath: userModel)
        return hasPy && hasModel
    }

    /// Instant Native Apple Voices (Zero Latency, In-Process)
    static let appleVoices: [(id: String, name: String)] = [
        ("system:daniel", "Apple: Daniel (British Male - Instant 0ms Latency) ★"),
        ("system:samantha", "Apple: Samantha (Natural - Instant 0ms Latency)")
    ]

    /// Local Kokoro voices
    static let kokoroVoices: [(id: String, name: String)] = [
        ("kokoro:bm_george", "Kokoro: George (British Male - Expressive & Natural) [Local AI]"),
        ("kokoro:bm_fable", "Kokoro: Fable (British Male - Witty & British) [Local AI]"),
        ("kokoro:bf_emma", "Kokoro: Emma (British Female - Crisp & Clear) [Local AI]"),
        ("kokoro:af_heart", "Kokoro: Heart (Warm AI - Studio Quality) [Local AI]"),
        ("kokoro:am_puck", "Kokoro: Puck (Natural AI) [Local AI]")
    ]

    /// Natural prebuilt voices available in Gemini TTS
    static let geminiVoices: [(id: String, name: String)] = [
        ("gemini:Puck", "Gemini: Puck (Natural British - Witty & Expressive) [Cloud]"),
        ("gemini:Kore", "Gemini: Kore (Warm, Friendly, Clear) [Cloud]"),
        ("gemini:Charon", "Gemini: Charon (Calm & Deeper) [Cloud]"),
        ("gemini:Fenrir", "Gemini: Fenrir (Energetic) [Cloud]"),
        ("gemini:Aoede", "Gemini: Aoede (Melodic & Thoughtful) [Cloud]")
    ]

    /// Legacy choices helper for menu compatibility
    struct Choice {
        let name: String
        let identifier: String
        let quality: Int
    }

    static func availableVoices() -> [Choice] {
        var list: [Choice] = []
        list.append(contentsOf: appleVoices.map { Choice(name: $0.name, identifier: $0.id, quality: 3) })
        if isKokoroAvailable {
            list.append(contentsOf: kokoroVoices.map { Choice(name: $0.name, identifier: $0.id, quality: 3) })
        }
        list.append(contentsOf: geminiVoices.map { Choice(name: $0.name, identifier: $0.id, quality: 3) })
        return list
    }

    /// Say one short line. Speaks with selected Kokoro local voice, Gemini Neural TTS, or instant Apple voice.
    func say(_ text: String, rate: Float = 1.0) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, Settings.shared.voiceEnabled else { return }

        stop()

        let pick = Settings.shared.voiceIdentifier ?? "system:daniel"

        // 1. Instant Apple native voice (0ms latency)
        if pick.hasPrefix("system:") {
            let voiceId = String(pick.dropFirst("system:".count))
            speakWithAppleSpeech(line, voiceName: voiceId)
            return
        }

        // 2. If Kokoro voice is picked
        if pick.hasPrefix("kokoro:") {
            let rawVoice = String(pick.dropFirst("kokoro:".count))
            Task { @MainActor in
                do {
                    try await speakWithKokoro(line, voice: rawVoice)
                } catch {
                    NSLog("[Voice] Kokoro error: \(error.localizedDescription), falling back to instant Apple voice")
                    speakWithAppleSpeech(line, voiceName: "daniel")
                }
            }
            return
        }

        // 3. If Gemini voice is picked
        if pick.hasPrefix("gemini:") || pick == "Puck" {
            let rawVoice = pick.hasPrefix("gemini:") ? String(pick.dropFirst("gemini:".count)) : pick
            if let key = AIConfig.geminiKey, !key.isEmpty {
                Task { @MainActor in
                    do {
                        try await speakWithGemini(line, key: key, voiceName: rawVoice)
                    } catch {
                        NSLog("[Voice] Gemini TTS error: \(error.localizedDescription), falling back to instant Apple voice")
                        speakWithAppleSpeech(line, voiceName: "daniel")
                    }
                }
                return
            }
        }

        // Fallback: Instant Apple voice
        speakWithAppleSpeech(line, voiceName: "daniel")
    }

    // MARK: - Native Apple Instant Speech (0ms Latency)

    private func speakWithAppleSpeech(_ text: String, voiceName: String = "daniel") {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let lang = voiceName.lowercased() == "samantha" ? "en-US" : "en-GB"
        if let voice = AVSpeechSynthesisVoice(language: lang) {
            utterance.voice = voice
        }
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
    }

    // MARK: - Kokoro Local Neural TTS

    private func speakWithKokoro(_ text: String, voice: String) async throws {
        let rawVoice = voice.isEmpty ? "bm_george" : voice

        // Check if the warm server is running on 127.0.0.1:8765. Built with URLComponents rather
        // than string interpolation: `.urlQueryAllowed` still permits "&" and "=", so a nudge
        // containing either would have truncated the text and could even override the voice.
        if var components = URLComponents(string: "http://127.0.0.1:8765/synthesize") {
            components.queryItems = [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "voice", value: rawVoice),
            ]
            if let srvUrl = components.url {
                var req = URLRequest(url: srvUrl)
                req.timeoutInterval = 3.0
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                    try play(data)
                    return
                }
            }
        }

        // Server not running yet: launch it for next time, and synthesize this line via the CLI.
        startKokoroServerIfNeeded()

        // The CLI is run OFF the main thread. It used to call `waitUntilExit()` inside a
        // `Task { @MainActor }`, which froze the entire app — menus, notch, the Sentinel's own
        // countdown — for the seconds synthesis takes, with no timeout if Python hung.
        let wavData = try await Self.synthesizeWithKokoroCLI(text: text, voice: rawVoice)
        try play(wavData)
    }

    /// Runs the Kokoro CLI on a background queue with a hard deadline, so a hung Python process can
    /// never wedge the app.
    private static func synthesizeWithKokoroCLI(text: String, voice: String) async throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let py = home.appendingPathComponent(".kokoro_env/bin/python3").path
        let script = home.appendingPathComponent(".kokoro/kokoro_tts.py").path
        // Per-user temp dir rather than world-writable /tmp with a guessable name.
        let outWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro_speech_\(ProcessInfo.processInfo.processIdentifier).wav")

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: py)
                proc.arguments = [script, "--text", text, "--voice", voice, "--out", outWav.path]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice

                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Wait with a deadline instead of blocking forever.
                let deadline = Date().addingTimeInterval(12)
                while proc.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    proc.terminate()
                    continuation.resume(throwing: NSError(
                        domain: "Voice", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Kokoro synthesis timed out"]))
                    return
                }

                guard proc.terminationStatus == 0,
                      let wav = try? Data(contentsOf: outWav), !wav.isEmpty else {
                    continuation.resume(throwing: NSError(
                        domain: "Voice", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Kokoro CLI synthesis failed"]))
                    return
                }
                try? FileManager.default.removeItem(at: outWav)
                continuation.resume(returning: wav)
            }
        }
    }

    private func play(_ wavData: Data) throws {
        let player = try AVAudioPlayer(data: wavData)
        player.delegate = self
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
        self.audioPlayer = player
    }

    private func startKokoroServerIfNeeded() {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let py = home.appendingPathComponent(".kokoro_env/bin/python3").path
        let script = home.appendingPathComponent(".kokoro/kokoro_tts.py").path
        guard FileManager.default.fileExists(atPath: py), FileManager.default.fileExists(atPath: script) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = [script, "--server", "--port", "8765"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // Only record it once it actually launched, so a failed start doesn't leave a dead
            // Process recorded as our server.
            self.serverProcess = proc
        } catch {
            NSLog("[Voice] Kokoro server failed to start: \(error.localizedDescription)")
            self.serverProcess = nil
        }
    }

    // MARK: - Gemini Neural TTS

    private func speakWithGemini(_ text: String, key: String, voiceName: String = "Puck") async throws {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash-lite-tts:generateContent?key=\(key)") else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid TTS endpoint"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "contents": [
                ["parts": [["text": text]]]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "voice": voiceName
                    ]
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let inlineData = parts.first?["inlineData"] as? [String: Any],
              let b64Audio = inlineData["data"] as? String,
              let wavData = Data(base64Encoded: b64Audio) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "TTS \(code): \(detail)"])
        }

        let player = try AVAudioPlayer(data: wavData)
        player.delegate = self
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
        self.audioPlayer = player
    }

    private func speakLocally(_ text: String) {
        macProcess?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Use Daniel (British voice) if available, else system default
        process.arguments = ["-v", "Daniel", text]
        try? process.run()
        self.macProcess = process
    }

    /// Short pop sound for warning alerts.
    ///
    /// Deliberately NOT gated on `voiceEnabled`: the audio cue is a safety alert, and someone who
    /// muted Bluey's voice still needs to be told they have drifted. Falls back to the system beep
    /// when the named sound is unavailable.
    func chirp() {
        if let pop = NSSound(named: "Pop") {
            pop.play()
        } else {
            NSSound.beep()
        }
    }

    func stop() {
        // Stop the native synthesizer too. It was previously left speaking, so a Kokoro or Gemini
        // line would play over the top of an Apple utterance — and the mic path, which calls stop()
        // so Bluey doesn't talk over the user, could never actually silence him.
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        macProcess?.terminate()
        macProcess = nil
    }

    /// Tears down the long-lived Kokoro server process. Called on app quit so relaunching doesn't
    /// leave the old server holding port 8765 and serving a stale model.
    func shutdown() {
        stop()
        if let serverProcess, serverProcess.isRunning { serverProcess.terminate() }
        serverProcess = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.audioPlayer === player {
                self.audioPlayer = nil
            }
        }
    }
}