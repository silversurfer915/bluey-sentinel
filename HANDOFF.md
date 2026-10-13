# Bluey Sentinel — Gemini / DeepSeek Engineering Handoff

**Updated:** 2026-10-13 (Asia/Kolkata)

**Repository:** `/Users/ponhareeshn/Documents/bluey-sentinel`

**Remote:** `https://github.com/silversurfer915/bluey-sentinel.git`

**Branch:** `codex/memory-cache-overhaul` (based on `main`)

**Last implementation checkpoint:** `74d1897`

**Upstream state at handoff:** the `codex/memory-cache-overhaul` branch is local only and was not pushed; nothing in this pass was pushed to `origin`.

## Read this first

The owner asked to finish Bluey's bugs, functionality, phone controller, and UI while explicitly parking the Sanctra integration. Do not resume Sanctra work unless the owner asks. Do not claim production or physical-device behavior from simulator builds or unit tests.

The chosen active-session presentation is the **Dock companion with a progress ring**. Bluey must not add another notch beside Vorssaint. The legacy notch implementation still exists in the source tree, but `Settings.notchEnabled` returns `false`, app launch calls `NotchController.stop()`, and the Dock companion starts instead. Treat the legacy notch files as dormant cleanup debt, not the selected UI.

Never put API keys, pairing keys, Sanctra tokens, or captured secret text in source, logs, fixtures, screenshots, or this document.

## Product intent that must be preserved

- Bluey is a Mac menu-bar AI companion, focus guardian, and screen-aware agent.
- Gemini 3.1 Flash Lite and Token Harbor are the preferred fast/default providers. DeepSeek and custom OpenAI-compatible providers remain available.
- Screen context and computer control should be invoked only for tasks that need them. Normal conversation should stay lightweight.
- Computer actions support three access modes and an immediate latched Emergency Stop. A normal Stop cancels only the current task.
- Voice commands can start and control focus. The microphone route can be changed immediately without changing macOS's system input.
- iPhone/iPad is a real controller: start, pause, resume, finish, abandon, approve/decline agent actions, send quick actions, view live state, and trigger Emergency Stop.
- UI should remain calm, clear, cute, and restrained. Avoid neon, excessive glow, and intrusive overlays.

## What was audited and fixed

Three parallel audit tracks covered bugs, end-to-end wiring, and UI/UX. The fixes were committed in small checkpoints:

| Commit | Result |
|---|---|
| `a8ea668` | Exposed current task cancellation and sync state in the Mac UI; phone controls now receive acknowledgements. |
| `83d8f6a` | Fixed memory deduplication so separate facts do not erase each other and the newest update wins. |
| `0c39386` | Authenticated paired phone traffic, added replay resistance, and made Mac focus state canonical to prevent duplicate or stale phone sessions. |
| `849461f` | Replaced the harsh icon treatment with calm sky/cream Bluey artwork for Mac and phone assets. |
| `35ee21e` | Closed approval bypasses, made cancellation terminate active work, hardened voice lifecycle, added multi-display screen coordinates, and added regression tests. |
| `b45fb92` | Completed the phone controller UI, pairing confirmation, agent status, focus history plumbing, presets, haptics, quiet hours, widget/Live Activity support, immediate mic selection, and final Mac focus UI polish. |

### High-severity behavior fixed

1. **Normal Stop no longer causes permanent lockout.** It cancels the current model/tool/speech work. Emergency Stop remains latched until an explicit Resume.
2. **Emergency Stop blocks queued work.** Work created before a stop cannot silently restart after Resume.
3. **Computer action approvals are enforced at execution time.** Stale or relabeled accessibility targets cannot reuse an earlier approval.
4. **Shell cancellation now terminates the process.** Output and error pipes are drained concurrently, and timeouts do not leave work running.
5. **Direct note/tool paths respect the access mode.** They can no longer bypass Off or Ask Every Time.
6. **Sensitive prompts are cancellation-aware.** A cancelled task cannot later request a secret.
7. **Screen element references are snapshot-bound.** Click/type requires the current snapshot and rejects stale references.
8. **Multiple monitors use the union of active display coordinate spaces.** Controls on secondary displays are no longer discarded as off-screen.
9. **Phone commands require an authenticated paired transport.** Unauthenticated commands and replayed frames are rejected.
10. **Focus state has one canonical session identity and revision.** Stale phone commands and wrong-session pause/finish requests are rejected.
11. **Pairing requires visible code confirmation on the Mac.** A discovered phone is not trusted merely because it is on the same network.
12. **Delayed phone voice responses are ignored after sleep/cancel.** Stale captions and audio cannot wake or speak over a later state.
13. **Mac speech cancellation is generation-bound.** Delayed synthesis completion cannot restart playback after Stop.
14. **Disconnected preferred microphones fall back safely.** The selected route persists and updates when devices appear or disappear.
15. **Focus duration uses timestamps rather than timer tick counts.** Sleep or scheduler delays no longer corrupt elapsed time.
16. **Sentinel revalidates the observed target before intervention.** It does not act on an unrelated app after focus changes.
17. **Memory startup cleanup preserves independent facts.** Related updates replace stale duplicates without merging unrelated preferences or subjects.

### UI and phone work completed

- The Mac Focus screen now shows the real subject, topic, planned duration, elapsed duration, active/paused state, connection/sync status, and explicit Finish and Abandon actions.
- Emergency Stop/Resume is persistent and visible instead of being hidden inside a transient workflow.
- Settings includes a live microphone picker and status text.
- The Dock icon is the selected focus indicator. Its ring uses planned progress when a plan exists and count-up semantics otherwise; abandoned sessions do not show completion celebration.
- The phone layout supports Dynamic Type, iPhone and iPad size classes, minimum practical control sizes, compact history, and accessible labels.
- Phone quick actions and session presets persist locally.
- Phone session start/pause/complete events have restrained haptic and animation cues, with quiet-hour handling.
- The phone shows Mac agent busy/status/steps and pending approvals.
- Widgets and Live Activities display the last foreground-confirmed Mac state. They explicitly say when state is stale and route controls through session/revision-bound deep links.
- App Group and URL scheme configuration are present in `project.yml`, generated Xcode project settings, and entitlements.

## Architecture map

| Area | Key files |
|---|---|
| Mac app lifecycle, menu, pairing prompts, hotkeys | `Mac/Sources/GooglyMac/AppDelegate.swift` |
| Main Mac UI, Focus, Memory, Settings, mic picker | `Mac/Sources/GooglyMac/BlueyWorkspace.swift` |
| Agent loop, provider routing, conversation/tools | `Mac/Sources/GooglyMac/RealtimeHost.swift`, `AIClient.swift`, `AIConfig.swift`, `AgentRunner.swift` |
| Access policy, stop/resume, approvals | `ExecutionAccess.swift`, `BlueyApproval.swift`, `ComputerGateway.swift` |
| Screen/accessibility control | `ControlsReader.swift`, `ComputerControl.swift`, `ComputerToolDefinitions.swift`, `ScreenContext.swift` |
| Focus Sentinel | `Sentinel.swift`, `FocusWatcher.swift`, `SentinelHUD.swift`, `SentinelEventLog.swift` |
| Dock indicator | `DockCompanion.swift` |
| Voice and microphone | `Voice.swift`, `MacVoiceInput.swift`, `MicrophoneCapture.swift`, `MicrophoneStore.swift` |
| Local memory | `MemoryStore.swift` |
| Encrypted phone transport and canonical focus state | `PhoneServer.swift`, `PhoneSessionManager.swift`, `Shared/GooglyLink.swift` |
| Phone/iPad controller | `iOS/Sources/BlueyAppView.swift`, `MacLink.swift`, `LiveVoice.swift`, `SessionActivity.swift` |
| Widget and Live Activity | `iOS/Widgets/BlueyFocusWidget.swift`, `Shared/FocusActivity.swift` |
| Xcode project source | `project.yml` (generated project: `GooglyEyes.xcodeproj`) |

## Verification completed on this checkpoint

### Automated tests

```bash
swift test
```

Result on 2026-10-13: **99 tests, 0 failures**. This includes agent cancellation, access policy, stale targets, shell termination, multi-display controls, phone authentication/replay protection, focus revisions, Dock presentation, microphone fallback, memory deduplication, Sentinel safety, model routing, and voice lifecycle.

Latest full log: `/tmp/bluey-release-swift-test-final.log`

### Mac builds

```bash
swift build
./scripts/build-mac.sh
```

Both completed successfully. `swift build` was rerun after the final warning cleanup and completed without compiler warnings. The production script generated and signed `build/Bluey.app`. The release compiler still reported older deprecations/actor warnings before the final warning cleanup; rerun the production script if release-log cleanliness itself matters.

Logs:

- `/tmp/bluey-release-swift-build-final.log`
- `/tmp/bluey-release-mac-build.log`

### Phone and widget build

```bash
xcodebuild \
  -project GooglyEyes.xcodeproj \
  -scheme GooglyEyes \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Result: **BUILD SUCCEEDED**. The build validated the app plus embedded `BlueyWidgets.appex` for arm64 and x86_64 simulator slices.

Log: `/tmp/bluey-release-ios-build.log`

### Voice cancellation harness

```bash
./scripts/test-phone-voice.sh
```

Result: `PASS: sleeping phone ignores delayed replies and captions`.

Log: `/tmp/bluey-phone-voice.log`

### Source hygiene

```bash
git diff --check
```

Result: clean before each implementation commit.

## Memory, cache telemetry, and workflow learning overhaul (2026-10-13)

This pass implemented the approved design in `docs/superpowers/specs/2026-10-13-memory-cache-design.md` and plan `docs/superpowers/plans/2026-10-13-memory-cache.md`. It was executed test-first on branch `codex/memory-cache-overhaul`, one reviewable commit per task:

| Commit | Result |
|---|---|
| `8643841` | Versioned memory metadata and non-destructive v1→v2 migration. |
| `a3159e1` | Conservative extraction with sensitive-value rejection. |
| `21f4906` | Deterministic, explainable, budgeted recall. |
| `f72e563` | Stable prompt prefix isolated from dynamic context. |
| `41fc1e5` | Honest provider usage normalization. |
| `4b46272` | Persistent cache telemetry and honest aggregates. |
| `4b8c6b8` | One telemetry row per successful provider response. |
| `0c3f54f` | Premium explainable Memory dashboard. |
| `87c0405` | Premium honest Token Caching dashboard. |
| `f91cdcd` | Privacy-safe preview fixtures and captured screenshots. |
| `74d1897` | Owner-reviewed local workflow learning. |

### Local databases and schema versions

| Store | Path | `PRAGMA user_version` | Notes |
|---|---:|---:|---|
| Memory | `~/Library/Application Support/Googly/memory.sqlite` | 2 | Version-1 databases migrate non-destructively. A SQLite-API backup is written to `memory.sqlite.v1-backup` before the first v1→v2 migration and is never overwritten. |
| Cache telemetry | `~/Library/Application Support/Googly/cache.sqlite` | 1 | WAL mode. Newest 500 requests and a 90-day retention window. No prompt or response columns. |
| Workflow skills | `~/Library/Application Support/Googly/workflow-skills.sqlite` | 1 | WAL mode. Normalized observations and owner-reviewed skill proposals only. |

### Prompt composition

- Stable prefix version: `bluey-prompt-v2`.
- `PromptContextBuilder` splits the system prompt into a byte-stable `stableSystem` (personality + mode/tool/computer guidance + invariant safety text) and a per-request `dynamicSystem` (autonomy, study, learner, memory, workflow, live context).
- Message order is stable system → dynamic system → bounded session history → current user message. Tool schemas are emitted in deterministic name order.
- The stable prefix is identical for the same mode and computer-control capability; only the dynamic message changes between requests.

### Memory behavior

- Conservative extraction (`ConservativeMemoryExtractor`) learns only explicit facts, preferences, corrections, and verified task outcomes. Assistant prose is never evidence.
- Sensitive values (API-key prefixes, bearer tokens, password assignments, recovery phrases, one-time codes, card-like digits, CVV/PIN, government-ID wording) are rejected before persistence with a fixed rejection code and no verbatim logging.
- Replacement uses stable keys (for example `profile:name`, `preference:appearance:global`); unrelated facts never merge.
- Recall is deterministic lexical ranking under a hard budget (at most 12 memories, about 1,200 estimated input tokens) with an explainable reason. Only prompt inclusion updates recall metadata.

### Cache telemetry behavior

- `CacheUsageNormalizer` parses DeepSeek hit/miss fields, `prompt_tokens_details.cached_tokens`, and known cached-content aliases. `prompt_tokens` is treated as total input.
- Missing cache fields are recorded as `usageWithoutCacheField` or `usageUnavailable`, never as a zero hit. Inconsistent or impossible values are rejected with a fixed warning code.
- Aggregates include only confirmed/reported observations in the hit-rate denominator. The blended dollar-savings estimate was removed.

### Workflow learning behavior

- Only an explicitly verified `.completed` workflow produces an observation. Failed, cancelled, unfinished, and conversation-only turns are ignored.
- Only normalized tool names and coarse parameter categories are stored; original prompts, URLs, file paths, window titles, arguments, images, and results are discarded.
- A proposal appears after at least three verified successes spanning two or more local days. Skills are published only by an owner-triggered UI action; proposed/rejected/paused skills never reach planning, and published skills are suggestions that still pass every normal permission, approval, stale-target, and Emergency Stop check.

### Screenshots (1100×760, synthetic fixtures only)

Captured with `./scripts/capture-premium-ui.sh`, which uses a debug-only `--ui-preview` launch mode that never touches the real memory, cache, or workflow databases:

- `docs/previews/premium-memory.png`
- `docs/previews/premium-token-caching.png`
- `docs/previews/workflow-learning.png`

### Verification performed in this pass

- `swift test` — **198 tests, 0 failures** (log: `/tmp/bluey-memory-cache-swift-test.log`).
- `swift build` — succeeded (log: `/tmp/bluey-memory-cache-swift-build.log`).
- `./scripts/build-mac.sh` — release `build/Bluey.app` (log: `/tmp/bluey-memory-cache-release-build.log`).
- `xcodebuild … -sdk iphonesimulator … CODE_SIGNING_ALLOWED=NO build` — no-sign iOS simulator build (log: `/tmp/bluey-memory-cache-ios-build.log`).
- `./scripts/capture-premium-ui.sh` — three PNGs at 1100×760 (log: `/tmp/bluey-memory-cache-capture.log`).
- `git diff --check` — clean.

### Remaining limitations (not verified in this pass)

- **Live provider cache telemetry is unverified.** No owner-provided provider keys were used, so no real Gemini, DeepSeek, Token Harbor, or custom response was recorded. Provider cache behavior remains best-effort and provider-controlled.
- **Physical iPhone/iPad pairing, signing, widgets, and privacy-permission flows remain unverified** (unchanged from the previous handoff).
- The screenshot harness is debug-only; release builds never load fixture data.
- Workflow learning only observes agent-loop completions and injects advisory text; it does not execute stored macros.

## Intentionally parked: Sanctra

Do not work on this section unless the owner explicitly resumes it.

The Bluey repository contains Sanctra client/sync code and tests, and the separate Sanctra repository is `/Users/ponhareeshn/Documents/StudyTimer`. Earlier work created Sanctra-side integration checkpoints, but production authentication, deployment, and a real-token two-device session have not been proven end to end in this pass. The StudyTimer checkout also had unrelated local changes, so never bulk-add, reset, clean, rebase, or overwrite it.

Treat these claims as **unverified until exercised with the owner's real account**:

- token generation/regeneration and revocation in production;
- account context completeness for every study-data category;
- web-to-Mac and Mac-to-web near-real-time focus control;
- offline reconciliation against the deployed server;
- conflict warnings when both sides start sessions;
- production streak/log updates;
- phone history backed by the real Sanctra account.

## Remaining work that requires real hardware, credentials, or external state

These are not safe to call complete from the current environment:

1. **Physical iPhone/iPad pairing:** verify Bonjour discovery, compare-code UI, reconnect after app relaunch, Wi-Fi loss/recovery, and replay rejection on two real devices.
2. **Signing and capabilities:** enable the App Group and Live Activities for the actual Apple developer identifiers/profiles, then perform a signed device build. The no-sign simulator build cannot prove provisioning.
3. **Widget/Live Activity refresh:** verify the foreground-only sync wording, stale state, pause/resume/finish deep links, Dynamic Island, Lock Screen, and session revision rejection on hardware.
4. **Simulator visual launch:** CoreSimulator booted an iPhone 18 Pro but app install/launch calls hung in this environment. The compiled simulator product is valid; visual simulator inspection was not completed.
5. **macOS privacy permissions:** test Accessibility, Screen Recording, Microphone, and Speech Recognition in a fresh macOS account and after permission denial/revocation.
6. **Live providers:** test Gemini, Token Harbor, DeepSeek, and any custom endpoint with valid owner-supplied credentials, including rate limit, expired key, timeout, tool-call loop, fallback, and cancellation.
7. **Real screen-control workflows:** run multi-step tasks in Safari/Chrome, Finder, Settings, and an app with nonstandard accessibility nodes. Confirm every visible click/type consequence matches the audit log.
8. **Release relaunch persistence:** launch the freshly built `build/Bluey.app`, switch mic/access modes, start a focus session, quit/relaunch, and confirm persisted settings and correct Dock state.
9. **Dormant notch cleanup:** remove unreachable legacy notch settings/menu methods only in a dedicated cleanup after confirming no desired music feature depends on them. Do not re-enable Bluey's notch.

## Recommended resume order for Gemini or DeepSeek

1. Run `git status --short` and preserve all existing work. Do not touch StudyTimer/Sanctra.
2. Rerun `swift test`, `swift build`, and the no-sign iOS build before changing code.
3. Use a physical phone and Mac to complete the pairing/controller checklist. Fix only failures reproduced there.
4. Use a clean macOS account or reset test permissions to validate the four privacy permission states.
5. Exercise one real provider at a time with owner-provided keys stored only through Bluey's Keychain UI.
6. Record exact pass/fail evidence. Do not replace failed device tests with source inspection claims.
7. Keep commits small and descriptive. Stage exact paths; never use bulk cleanup in either repository.

## Suggested physical-device acceptance checklist

- Pairing requires matching the same six-digit code on Mac and phone.
- A rejected or mismatched pairing cannot send commands.
- Start on phone appears once on Mac with the same session identity.
- Start on Mac appears once on phone; no duplicate session is created after reconnect.
- Pause/resume/finish/abandon from each side updates the other within the expected local-network interval.
- A stale widget link cannot control a newer session.
- Emergency Stop from Mac and phone halts active agent work immediately and remains latched.
- Resume requires an explicit action and does not resurrect pre-stop queued work.
- Switching microphone changes the next recording route without changing the macOS system default.
- Voice start, pause, resume, finish, and lock-target commands work while the workspace is closed.
- Dynamic Type and iPad split sizes keep primary controls visible and tappable.
- Relaunching both apps restores pairing and the correct current focus state.

## Git safety and release notes

- At the start of this handoff, local Bluey `main` was ahead of `origin/main`; no push was performed.
- The generated Xcode project is intentionally tracked. When `project.yml` changes, regenerate using the repository's XcodeGen workflow and inspect the resulting project diff.
- The Mac app is a menu-bar/background style app whose executable remains named `GooglyMac`; the user-facing product name is Bluey.
- Do not rename bundle identifiers or App Group identifiers casually; doing so breaks pairing persistence, widget storage, signing, and installed-app upgrades.
- Do not declare the project fully production-ready until the hardware, privacy-permission, signed-build, and live-provider checks above pass.
