# HANDOFF — Bluey / Focus Sentinel

**Written:** end of session, model quota nearly exhausted.
**Repo:** `/Users/ponhareeshn/Documents/bluey-sentinel`
**Platform:** macOS 27 (arm64), Swift 6.4, Xcode installed, Apple Silicon.
**State:** builds clean, **100/100 self-tests pass**, verified working live.

Read this whole file before touching anything. It records not just what to do, but **what has
already been tried and proven wrong**, so you don't repeat dead ends.

---

## 0. Start here — build and test in two commands

```bash
cd /Users/ponhareeshn/Documents/bluey-sentinel
./scripts/build-mac.sh                                        # produces build/Bluey.app
GOOGLY_DEMO_SENTINEL=1 ./build/Bluey.app/Contents/MacOS/GooglyMac   # runs 100 guard-rail checks, exits
open build/Bluey.app                                          # run it for real (menu bar)
```

Expected output of the test command, last line:

```
✅  100 checks passed — the guard rails hold.
```

If that line is not there, **stop and fix it before anything else.** The suite is the safety net
for a feature that closes the user's tabs and quits their apps.

`swift build -c release --product GooglyMac` also works for a fast compile-only loop.

---

## 1. What this app is

There are **two products in one menu-bar app**:

1. **Bluey** — the original project (`rbrown101010/bluey-by-riley` upstream): a blueberry character
   with his own cursor who lives in the Mac's notch / above an iPhone, points at things, answers
   questions, and can drive the computer when asked.
2. **Focus Sentinel** — the feature the user actually asked for: it watches the front window, and
   when the user drifts from a stated focus goal, it **warns them with a countdown and then closes
   the site or app that took them there.**

Upstream used OpenAI's realtime audio model. That was replaced: **Token Harbor's
`deepseek-v4.1-flash` is the brain**, and speech is **free and local** (`AVSpeechSynthesizer`).

### The user's actual requirements (verbatim intent, accumulated across the session)

- "a local ai agent that views my screen always and sees what im doing, and if im studying and get
  distracted it closes that site/app for me with a warning"
- "cloud model is fine but i want it to be free"
- "make it work with deepseek model but instead of voice model, use tts model and deepseek as the brain"
- "integrate these features with that bluey app"
- Later: "replace the local ai model brain with token harbor api endpoint for deepseek flash model
  and delete that 1b model" — **done**
- Later: "make the character central — he points at the distraction" — **done**

**Interpretation note:** "for free" was reconciled as *fractions of a cent per check* (measured,
see §3), not literally zero cost. The user accepted this after seeing the accuracy data. Do not
re-introduce a local model to chase zero cost — it was tried and failed (§3).

---

## 2. Architecture — how a drift becomes an action

```
heartbeat (2s tick, only if autoPolling) ─┐
app-switch observer (NSWorkspace) ────────┤─→ checkWindowOrTabChange()
                                          │     ├─ probe: front app, window title, exact browser
                                          │     │   URL (AppleScript), idle seconds
                                          │     ├─ idle ≥ 90s or app exempt → reset, return
                                          │     ├─ system overlay (dialog/Spotlight) → return
                                          │     ├─ window unchanged → return (zero AI)
                                          │     ├─ matching locked target → return (zero AI)
                                          │     └─ evaluateWindowOrTabChange()
                                          │          ├─ Tier 1  topic continuity (0ms, no model)
                                          │          ├─ Tier 2  known-distraction list (0ms, no model)
                                          │          └─ Tier 3  Token Harbor model
                                          │                 └─ confirmAndWarn()  ← sustain gate
                                          │                      └─ warnAndEnforce()
                                          │                           ├─ chirp + speak + fly to point
                                          │                           ├─ HUD countdown (default 10s)
                                          │                           └─ apply(): close tab / quit app
```

### The three tiers (this is the core design — do not flatten it)

- **Tier 1 — topic continuity, ~0ms, no API call.** `Sentinel.isTopicRelated` compares significant
  keywords between the goal/locked target and the new window. This is what makes
  "Wave Optics PDF → Wave Optics practice questions" a non-event. Costs nothing.
- **Tier 2 — known distractions, 0ms, no API call.** `Sentinel.distractionDomains` /
  `distractionApps` (a static set in `Sentinel.swift`, line 458). Catches youtube.com,
  reddit.com, steam, etc. **Tier 1 runs first, so a Wave Optics lecture on YouTube is approved
  before Tier 2 can fire.** Subdomain matching is `hasSuffix("." + listed)` specifically so
  `notyoutube.com` does not match — there is a test for this.
- **Tier 3 — the model**, for genuinely ambiguous cases only.

### Files that matter

| File | Role |
|---|---|
| `Sentinel.swift` (844 lines) | The watch loop, three tiers, sustain gate, enforcement planning, target lock, audit log |
| `Brain.swift` (385) | HTTP client + **lenient JSON verdict parser** + prompts |
| `AIConfig.swift` (196) | Provider routing (Token Harbor → Gemini → DeepSeek) |
| `SentinelHUD.swift` (197) | The countdown warning card |
| `Voice.swift` (344) | TTS: native Apple, Kokoro ONNX (local), Gemini cloud |
| `SentinelGuardTests.swift` (409) | The 100 checks |
| `ScreenContext.swift` (230) | The cheap probe + AppleScript tab closing |
| `AppDelegate.swift` (859) | Menu bar, hotkeys, lifecycle, key dialogs |
| `NotchController/NotchView/NotchGeometry` | The notch character + music island |
| `MacVoiceInput.swift` (234) | On-device speech recognition (no phone needed) |
| `StudyLearner.swift` (291) | Study stats / "Hermes" learner |

---

## 3. PROVEN DEAD ENDS — do not repeat these

This is the most valuable section. Each of these was *measured*, not assumed.

### ❌ A local small model cannot do this job

`llama3.2:1b` via Ollama was tried as the Sentinel's judge, for zero cost and privacy. Measured on
the canonical cases, it returned:

| Window | Expected | `llama3.2:1b` said |
|---|---|---|
| YouTube — funny cats | drift | **on_task** ❌ |
| Reddit r/funny | drift | **on_task** ❌ |
| Steam store | drift | **on_task** ❌ |
| Wave Optics practice questions | on-task | on_task ✅ |
| NCERT PDF | on-task | on_task ✅ |

**0/3 distractions caught. It failed in the permissive direction**, so the Sentinel would run all
day and never fire. It also contradicted itself in prose ("clearly drifted to unrelated
entertainment" alongside `on_task: true`) and returned `"point"` as a *string* instead of an object.
The model has been deleted and Ollama stopped. **Do not bring it back.**

### ✅ What replaced it, measured

`deepseek-v4.1-flash` via Token Harbor — **6/6 correct**, ~1.9s per check, on the same cases
*including* telling a Wave Optics lecture on YouTube (on-task) from funny cats on YouTube (drift).

`deepseek-v4-flash` also scored 6/6 but averaged 4.06s vs 1.91s. **Use `deepseek-v4.1-flash`.**

### ❌ The `:free` tier is unusable

Every call to `deepseek-v4.1-flash:free` / `deepseek-v4-flash:free` returned **HTTP 429** (all six).
The paid-tier ids work. This is metered, roughly **1/10th of a cent per check** (~200-400 tokens).
If the user later insists on literally-free, the honest options are: a much larger local model
(needs >8 GB RAM headroom, which this 8 GB Mac does not have), or a different free-tier provider —
**not** `llama3.2:1b`.

---

## 4. Bugs already found and fixed — don't "re-fix" these

Each of these was a real defect with evidence. They are fixed; the tests cover them.

| # | Bug | Why it mattered | Where the fix is |
|---|---|---|---|
| 1 | A wrong-typed `point` field made the verdict unparseable, and the catch returned `.uncertain` = `on_task: true` | **The whole feature was silently dead.** Real drift recorded as focused work | `Brain.parse` — field-by-field lenient parsing; a bad field is dropped, never guessed |
| 2 | `on_task: "false"` (quoted) read as **true** | A Swift `String` bridges to `NSNumber`, and non-empty strings are truthy | `Brain.bool` checks `String` **before** `NSNumber` |
| 3 | Sustain logic was dead: `driftStartedAt` never set, `strikes` never incremented | **One sample** (or one wrong guess) fired a warning | `Sentinel.confirmAndWarn` |
| 4 | Kokoro TTS called `proc.waitUntilExit()` inside `Task { @MainActor }`, no timeout | **Froze the entire app** for seconds; a hung Python wedged it forever | `Voice.synthesizeWithKokoroCLI` — off-main, 12s deadline |
| 5 | `sentinel.stop()` had zero callers; start() ran unconditionally | 1s timer + observer ran forever even with the feature off; disabling left a countdown on screen | `AppDelegate.toggleSentinel` + gated launch |
| 6 | `editGoal` "Clear Goal" didn't disable the Sentinel, contradicting its own alert text | The goal modal popped on **every launch**, forever | `AppDelegate.editGoal` `.alertThirdButtonReturn` |
| 7 | ⌃⌥L / ⌃⌥C / ⌃⌥S advertised in the menu but never registered | Headline actions silently did nothing | `AppDelegate` hotkey registrations |
| 8 | A leaked audio tap: `installTap` before `start()`, and `removeTap` inside the `isRunning` check | One transient audio failure **permanently broke** Mac voice input (or crashed) | `MacVoiceInput.cleanupAudio` — unconditional `removeTap` |
| 9 | Recognition callback had no `isListening` guard | A trailing result left the notch **stuck on "Listening…"** forever | `MacVoiceInput` task callback |
| 10 | Lock state driven by display sleep/wake | Waking a still-locked Mac made Bluey jump out of the lock state | `LockScreenObserver` — lock signals only; display sleep is separate |
| 11 | Notch rendered over the lock screen regardless of the setting, and kept its last state | The setting was meaningless; a music island could sit visible on a locked screen | `NotchController.handleLockChanged` |
| 12 | Paused music collapsed the island and killed hover controls | Reaching for pause lost the controls, and `mouseExited` fired without `mouseEntered` | `NowPlayingService` returns paused state; `handleTrackChanged` guards `.musicExpanded` |
| 13 | System dialogs (`universalAccessAuthWarn`, Spotlight, Notification Center) were judged as the user's work | Spent a call on a dialog; could warn about a window the user never opened | `Sentinel.isSystemOverlay` — returns without disturbing the reference window |
| 14 | `sentinelAutoPolling` was a menu toggle that did nothing; heartbeat probed every 1s | An AppleScript round-trip to the browser every second | `Sentinel.pollIfEnabled` |
| 15 | Overlapping evaluations (heartbeat + app-switch) raced on shared state | Could double-count drift into a premature warning | `isEvaluating` re-entrancy guard |
| 16 | Nothing was ever torn down on quit | Orphaned Kokoro server held port 8765; audio tap left running | `AppDelegate.applicationWillTerminate` |
| 17 | Notch position followed `NSScreen.main`; two `NSScreen.screens.first!` force-unwraps | Character teleported to whichever display had focus; could crash during display teardown | `NotchView.anchorScreen` |
| 18 | `apply()` re-read the live frontmost browser instead of using the probe | Enforcement could act on a different browser than the one warned about | `planEnforcement` uses the probe only |

### Non-hermetic test suite (fixed — pattern to preserve)

The suite shares `UserDefaults` with the running app. Two separate incidents:

- It read `sentinelAct`, so a live "warn only" toggle made 3 checks fail.
- It read `sustainSeconds`, so my own live tuning (`=10`) made 2 checks fail.

**Rule for new tests: assert on shipped constants (`Settings.defaultSustainSeconds`,
`Sentinel.minimumStrikesBeforeWarning`), never on the machine's current stored values.** The suite
is now verified hermetic — it passes with deliberately hostile settings written into defaults, and
leaves the user's values untouched. Re-verify that property if you add settings-dependent tests.

---

## 5. REMAINING WORK — prioritised

### P1 — correctness / trust

1. **`apply()` still has the `frontBrowser()` fallback** (`Sentinel.swift` ~line 680):
   ```swift
   guard let browser = ScreenContext.isBrowser(lastProbe?.app) ? lastProbe?.app : ScreenContext.frontBrowser() else {
   ```
   `planEnforcement` was fixed to use the probe only, but `apply` still falls back to *whatever is
   frontmost now* — and 10-30s have passed since the warning was shown. If the user switched apps
   during the countdown, this can close a tab in a browser they moved to legitimately. **Carry the
   browser name inside `Plan` and use only that.** Add a guard test.

2. **`Voice.say(rate:)` is dead** — the parameter is accepted and ignored
   (`utterance.rate = AVSpeechUtteranceDefaultSpeechRate`, `Voice.swift` ~122). Either honour it
   (map `Float` onto `AVSpeechUtteranceMinimumSpeechRate...MaximumSpeechRate`) or delete the
   parameter. Related: `speakWithAppleSpeech` picks a voice by **language**, not by the name asked
   for, so `system:samantha` and `system:daniel` both resolve to the same en-GB/en-US default.

3. **Quitting an app is heavy-handed.** `Plan.quitApp` calls `NSRunningApplication.terminate()` —
   that closes *every* window of that app, not the distracting one. Prefer `hide()` (reversible),
   or ⌘W on the front window, and only escalate to quit for a hard-block list. Note `matchedRunningApp`
   will happily match `Finder`, which is currently not exempt.

4. **No git repo.** `git rev-parse` fails — this project has no version control despite ~9,000 lines
   of Swift and multiple agents editing it. **`git init` and commit before making changes.** This is
   the single highest-value 2-minute task in this document.

### P2 — dead code / wiring

5. `Voice.speakLocally` — zero call sites (dead).
6. `ScreenContext.frontBrowser` — only used by the P1 fallback; delete with it.
7. `RealtimeHost.judgeShift` — one reference (itself). Confirm whether the phone path still needs it.
8. `AIConfig.hasAnyKey` vs `Brain.hasKey` — both now resolve Token Harbor; check every menu
   `isEnabled` gate uses the same one, and that none still assume a cloud key is required.
9. `Settings.onChange` is never assigned by anything — either wire it or delete it.

### P3 — polish (from the subsystem audits, still open)

- `NowPlayingService` uses `NSWorkspace.runningApplications` + AppleScript; `TrackInfo.isPlaying`
  is now real — make sure the notch's play/pause button *reflects* it, not just toggles.
- `NotchView` compact clock redraws on mouse movement, so it can sit minutes stale; add a 30s
  invalidate while in `.compact`, and cache the `DateFormatter`.
- `MacVoiceInput`: silence timer only finalises `if !currentTranscript.isEmpty`, so saying nothing
  leaves the mic hot indefinitely. Add an idle stop (~8s, `processCommand: false`).
- `MacVoiceInput`: if the recogniser is unavailable it returns silently with no UI feedback.
- `Voice.isKokoroAvailable` doesn't check `kokoro_tts.py` exists, so the menu offers Kokoro voices
  that will fail late.
- Kokoro temp WAV name is predictable; `FileManager.default.temporaryDirectory` is used now, but
  consider a `mkstemp`-style unique name.
- `NotchView` line ~287: an unreachable `state == .compact && p.x <= bounds.width` clause.

### P4 — verify before trusting

10. **The iPhone app was never tested.** `iOS/` and `GooglyEyes.xcodeproj` need full Xcode and a
    device; the Mac-side realtime/phone path (`RealtimeHost.swift`, 825 lines) still references the
    **OpenAI** realtime model. If the user wants the phone to work, that path needs the same
    provider treatment the Sentinel got. **Ask before starting — it's a large change.**
11. **Automation permission is per-app.** The app needs one-time consent to read the browser URL
    (see TCC log: `kTCCServiceAppleEvents requires entitlement
    com.apple.security.automation.apple-events`). Without it, `probe()` silently returns no URL and
    the Sentinel falls back to window titles only — degraded but safe. Consider surfacing this in
    the menu rather than failing quietly.

---

## 6. Credentials and configuration

| Thing | Where |
|---|---|
| Token Harbor key (the app) | `~/Library/Application Support/Googly/keys.json`, key `tokenHarbor`, mode 0600 |
| Token Harbor key (harness) | `~/.dsh/.credentials.yaml` → `refs.TOKENHARBOR_API_KEY` |
| Endpoint | `https://tokenharbor.ai/v1/chat/completions` |
| Model | `deepseek-v4.1-flash` |
| Env fallback | `TOKENHARBOR_API_KEY` |
| Audit log | `~/Library/Application Support/Googly/sentinel.log` |
| Permission status | `~/Library/Application Support/Googly/status.txt` |
| App defaults | `defaults read co.visionairy.googly.mac` |

**The app cannot see the harness's environment variables.** It reads its own `keys.json`. If the
Sentinel reports "no key", that is the first thing to check — this was a real confusion earlier.

Useful live debugging:

```bash
tail -20 "$HOME/Library/Application Support/Googly/sentinel.log"
defaults read co.visionairy.googly.mac | grep -iE 'sentinel|focus|sustain|strikes'
```

---

## 7. Testing guidance

The suite is in `SentinelGuardTests.swift`, run via `GOOGLY_DEMO_SENTINEL=1`, exits non-zero on
failure. It covers: domain sanitising (including AppleScript injection attempts), running-app
matching, enforcement planning, verdict parsing (malformed/quoted/wrong-typed fields), grid-point
clamping, target locking, topic continuity, known distractions, system overlays, provider routing,
and the preserve-the-sustained-gate invariants.

**Rules for new tests:**

1. Never assert on live `UserDefaults` values (see §4).
2. Anything the model can return is **untrusted input** — test it with hostile strings. There are
   existing tests for `evil"; do shell script "rm -rf ~"`; keep that standard.
3. A new tier or bypass needs a test proving the *permissive* failure can't happen, since silently
   doing nothing is this feature's characteristic failure mode.

**Live verification pattern** (used successfully this session — it caught bug #13):

```bash
defaults write co.visionairy.googly.mac focusGoal -string "Study Wave Optics"
defaults write co.visionairy.googly.mac sentinelEnabled -bool true
open build/Bluey.app && sleep 6
osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://www.youtube.com/watch?v=jNQXAC9IVRw"'
sleep 20 && tail -8 "$HOME/Library/Application Support/Googly/sentinel.log"
```

Expected: a `window/tab change to [...]` line, then either a Tier 2 detection or an
`AI judged as drift: ... [confidence: ...]` line, then `drift not yet sustained (n/2 strikes, Xs/60s)`.
**Remember to restore the user's settings afterwards** (I set `sentinelEnabled=false`,
`focusGoal=""`, `sustainSeconds=60`, `strikes=2` at the end of the session).

---

## 8. Constraints and preferences

- **8 GB RAM.** Do not propose local models that need real headroom.
- **Never close anything without a visible, cancellable countdown.** The countdown is the contract.
- **Treat all model output as untrusted.** A `block` is acted on only if it is a valid hostname or
  the exact name of a *currently running* app. Screen text is never an instruction.
- **Zero-vision by design.** No screenshots are sent; the judge sees app, window title, URL, idle
  time. Do not add screenshot upload without asking — it changes the privacy story and the cost.
- The user is a student (JEE prep: physics, wave optics). Keep the register of Bluey's nudges warm
  and specific, never scolding.
- The user writes terse messages and iterates fast. **Show measured evidence** (accuracy, latency,
  cost) — that is what settled the local-vs-cloud decision, and it will settle the next one.

---

## 9. Suggested first moves

1. `git init && git add -A && git commit` — there is no version control. Do this first.
2. Run the build + test commands in §0 and confirm `100 checks passed`.
3. Fix **P1 #1** (`apply()` browser fallback) — it's the last correctness hole in the
   enforcement path, and it's small.
4. Ask the user whether the **iPhone app** (P4 #10) matters, before touching `RealtimeHost.swift`.
5. Only then take on polish from P3.