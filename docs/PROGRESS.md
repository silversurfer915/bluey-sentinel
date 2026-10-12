# Bluey integration progress — 2026-10-12

Approved scope: `docs/superpowers/plans/2026-10-12-bluey-integration.md`, plus overall UI improvements and instant microphone switching. Implemented sequentially in the existing checkout, branch `bluey-integration`.

## Completed

1. Shared provider routing: Gemini 3.1 Flash Lite first, Token Harbor alternative, DeepSeek and custom compatible providers. Credentials migrate safely to Keychain. Explicit provider selection is honored.
2. Shared commands/state: typed, Mac voice, and phone requests use the same focus operations and assistant task state. Direct focus commands avoid unnecessary model calls.
3. Agent execution: multi-step loop, preserved provider metadata, fresh screen observations after actions, objective verification, cancellation, budgets, repetition limits, and real consequential-action confirmations. Stop cancels executing and queued phone actions; tasks cannot overlap.
4. Focus Sentinel: bounded continuous monitoring, exact target comparisons, periodic context refresh, second drift judgments, uncertain judgments excluded from focus credit, accurate elapsed-time accounting, and exact observed-tab closure/app hiding. Intervention defaults off for new setups.
5. Native workspace: Assistant, Focus, Study memory, Settings; provider testing, permissions entry, coherent status, confirmation controls, visible task progress. Existing optional controls remain accessible.
6. Notch: shared priority for warning/task/listening, quieter appearance, optional passive music and play, reduced-motion behavior, floating coexistence below Vorssaint. Installed Vorssaint is untouched. Its inspected source offered no general supported external notch plugin interface, so coexistence is the implemented option.
7. Microphones: prompt/menu input picker, remembered preference, disconnected-device fallback, per-device capture independent of system audio settings, switching feeds the same speech recognition request without submitting the command.
8. Research/notes: actual public page retrieval with fetched sources; formatting uses the selected common provider.

## Verification

- 22 automated tests passed: provider routing, commands, multi-turn loop, cancellation, stale batched actions, confirmation matching, Sentinel target/uncertainty/time accounting, isolated persistence, notch priority, mic fallback, sanitized errors, public extraction.
- 100 existing guardrail checks passed after updating stale provider expectations and isolating their study data.
- Signed release app built successfully.
- Live Gemini and Token Harbor multi-turn tool round trips passed.
- Gemini recognized the number in a generated image fixture.
- Main-display capture/OCR/accessibility and actual public-page retrieval passed.
- Real browser exercise: Bluey opened the local test page, clicked Next page and Finish exercise, then verified “Exercise complete: 42”. The completed browser tab was independently inspected.
- Native Assistant, Focus, Settings and provider connection were inspected through the actual app UI.
- Eight input devices detected. Local capture received frames from MacBook Air Microphone and BoomAudio. The available iPhone mic returned no frames during the check.
- Spoken transcription across a device switch remains unverified: the live check requires existing Speech Recognition permission and on-device recognition. No test audio was saved/uploaded. Physical phone pairing, meeting recording, and multi-display interaction remain unverified.

## Recovery and test-data correction

Original signed app preserved at ignored `work/Bluey-before.app`. Baseline committed before changes. Logs and private recovery data remain ignored under `work/`.

The legacy self-test was found to write fictional study data to the real profile after two executions. The known 30 sample minutes, two drift additions, corresponding hourly samples and endurance adjustments were reversed, with a private recovery copy kept. Prior timestamps, streak metadata and potentially pre-existing sample notes cannot be reconstructed exactly without a pre-test profile backup. Future self-tests use an isolated temporary profile and verify that persistent user storage is unaffected.
