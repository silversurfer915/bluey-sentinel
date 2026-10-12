#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TEMP"' EXIT
swiftc "$TASK_ROOT/iOS/Sources/LiveVoice.swift" \
  "$TASK_ROOT/iOS/Sources/ChunkRecorder.swift" \
  "$TASK_ROOT/iOS/Sources/SessionStore.swift" \
  "$TASK_ROOT/iOS/Sources/MacLink.swift" \
  "$TASK_ROOT/Shared/GooglyLink.swift" \
  "$TASK_ROOT/Tests/PhoneVoiceHarness/VoiceHarness.swift" \
  -o "$TASK_TEMP/phone-voice-test"
"$TASK_TEMP/phone-voice-test"
