#!/usr/bin/env bash
# Captures the two privacy-safe premium dashboard screenshots at 1100x760.
# Uses a debug-only launch mode that renders synthetic fixtures and never
# touches the owner's real memory or cache databases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="$ROOT/docs/previews"
MEMORY_PNG="$OUT_DIR/premium-memory.png"
CACHE_PNG="$OUT_DIR/premium-token-caching.png"
EXPECTED="1100x760"

mkdir -p "$OUT_DIR"
rm -f "$MEMORY_PNG" "$CACHE_PNG"

echo "Building debug app…"
BIN_DIR="$(swift build --show-bin-path)"
swift build >/dev/null
BIN="$BIN_DIR/GooglyMac"
if [ ! -x "$BIN" ]; then
  echo "Debug binary not found at $BIN" >&2
  exit 1
fi

wait_for_png() {
  local path="$1" timeout="${2:-45}" elapsed=0
  while [ ! -s "$path" ]; do
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timed out waiting for $path" >&2
      return 1
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
  done
}

capture() {
  local page="$1" path="$2"
  echo "Capturing $page preview…"
  "$BIN" --ui-preview "$page" --screenshot-path "$path" --reduce-motion &
  local pid=$!
  wait_for_png "$path" 45 || { kill "$pid" 2>/dev/null || true; exit 1; }
  wait "$pid" 2>/dev/null || true
}

check_png() {
  local path="$1"
  [ -s "$path" ] || { echo "Empty PNG: $path" >&2; return 1; }
  local dims
  dims="$(sips -g pixelWidth -g pixelHeight "$path" 2>/dev/null \
    | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
  if [ "$dims" != "$EXPECTED" ]; then
    echo "Wrong dimensions for $path: got $dims, expected $EXPECTED" >&2
    return 1
  fi
  file "$path"
}

capture memory "$MEMORY_PNG"
capture cache "$CACHE_PNG"

check_png "$MEMORY_PNG"
check_png "$CACHE_PNG"

echo "PASS: captured $MEMORY_PNG and $CACHE_PNG at $EXPECTED"
