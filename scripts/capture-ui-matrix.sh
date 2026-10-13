#!/usr/bin/env bash
# Captures the Mac UI screenshot matrix (design.md §11) with synthetic fixtures.
# Debug-only preview mode: never touches real memory, cache, or workflow stores.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/docs/previews/ui"
mkdir -p "$OUT"

echo "Building debug app…"
BIN_DIR="$(swift build --show-bin-path)"
swift build >/dev/null
BIN="$BIN_DIR/GooglyMac"
[ -x "$BIN" ] || { echo "Debug binary not found at $BIN" >&2; exit 1; }

wait_for_png() {
  local path="$1" timeout="${2:-45}" elapsed=0
  while [ ! -s "$path" ]; do
    [ "$elapsed" -ge "$timeout" ] && { echo "Timed out waiting for $path" >&2; return 1; }
    sleep 0.5; elapsed=$((elapsed + 1))
  done
}

capture() {
  local page="$1" file="$2" appearance="$3"
  shift 3
  rm -f "$file"
  echo "Capturing $page ($appearance)…"
  "$BIN" --ui-preview "$page" --screenshot-path "$file" --reduce-motion --appearance "$appearance" "$@" &
  local pid=$!
  wait_for_png "$file" 45 || { kill "$pid" 2>/dev/null || true; exit 1; }
  wait "$pid" 2>/dev/null || true
}

check_exact() {
  local path="$1" expected="$2"
  local dims
  dims="$(sips -g pixelWidth -g pixelHeight "$path" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
  [ "$dims" = "$expected" ] || { echo "Wrong dimensions for $path: $dims (expected $expected)" >&2; return 1; }
}

# Menu-bar popover (idle, light) — content-driven size.
capture popover "$OUT/popover-idle.png" light

# Workspace pages, light appearance.
capture assistant "$OUT/assistant-empty.png" light
capture focus "$OUT/focus.png" light
capture memory "$OUT/memory.png" light
capture skills "$OUT/skills.png" light
capture cache "$OUT/token-caching.png" light
capture settings "$OUT/settings.png" light

# Dark appearance and narrow window.
capture memory "$OUT/memory-dark.png" dark
capture assistant "$OUT/assistant-narrow.png" light --preview-size 860x640

for f in assistant-empty focus memory skills token-caching settings memory-dark; do
  check_exact "$OUT/$f.png" "1100x760"
done
check_exact "$OUT/assistant-narrow.png" "860x640"
[ -s "$OUT/popover-idle.png" ] || { echo "Missing popover capture" >&2; exit 1; }

echo "PASS: captured Mac UI matrix into $OUT"
