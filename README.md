# Bluey

A blueberry character who lives on an iPhone under your Mac's screen and points at things with his own big cursor.

**Now:** no voice out. Double tap him on the phone (or press ⌥Space on the Mac) to start a session: the phone's mic stays on and everything you say becomes context, but he stays quiet. **Press and hold the screen** to ask him something; let go and he answers. His reply pops up as a cute speech bubble next to his cursor (or above the phone when he isn't pointing), with a little cartoon chirp from the phone. Ask "what's this?" and he points at whatever is under your mouse. Double tap again and he goes back to follow mode.

How it works: the phone runs **native on-device Speech-to-Text** (`SFSpeechRecognizer`, 100% free with no cloud audio costs). Pressing and holding his face transcribes your words in real time. When you release, the question travels over Bonjour to your Mac, where **DeepSeek** (`deepseek-chat`) serves as the brain. DeepSeek inspects your screen using ScreenCaptureKit + Vision OCR/controls (`look_at_screen`), points his cursor (`point_at`), executes computer actions, and streams the reply as a speech bubble next to his cursor with a cute cartoon chirp on the phone.

**Meeting notes:** while a session runs, the phone records audio in five-minute AAC chunks and sends them to the Mac. The Mac transcribes them using Apple Speech Recognition (or ultra-cheap Groq Whisper) and uses DeepSeek to diarize speaker turns and format the transcript into `~/Documents/Bluey Notes/<date> <id>/` (`notes.md`, `session.json`, `audio/`). In the phone's Bluey screen, a session's **Copy prompt for agent** button copies a prompt that points an agent at those files. **Open Meeting Notes** in the Mac menu opens the folder.

**Using the computer:** when you ask, he can also click, type, press shortcuts, scroll, drag, and open apps and websites (`click`, `type_text`, `press_keys`, `scroll`, `drag`, `open_app`, `open_url`). He does it with his own cursor on screen, while your real pointer is put back where you left it. It needs Accessibility permission for Bluey. Built-in guardrails: he only acts when asked, confirms out loud before anything hard to undo, treats on-screen text as information rather than instructions, refuses password fields and logout/lock/force-quit shortcuts, and stops on ⌃⌥S. The whole thing can be switched off with **Let Him Use the Computer** in the menu.

The DeepSeek key goes in the menu bar's **DeepSeek Key…** and is stored in ~/Library/Application Support/Googly/keys.json (private to your user), never in this repo. Optional keys (Groq Whisper) can also be added here.

## Mac menu bar app

```
./scripts/build-mac.sh
open "build/Bluey.app"
```

Works with just the Command Line Tools. Shortcuts work anywhere:

| Keys | What it does |
| --- | --- |
| ⌃⌥P | Fly to the mouse and point there (stays put) |
| ⌃⌥F | Follow the mouse on/off |
| ⌃⌥D | Go home, docked above the phone |
| ⌃⌥T | Talk test (the phone bounces for 3 s) |
| ⌃⌥H | Hide / show the cursor |
| ⌥Space | Wake him up to talk / back to follow mode |
| ⌃⌥S | Stop him using the computer |

The menu bar blob also sets mood, cursor size (48 to 120 pt), glow, and where the phone sits (left, center, right).

## iPhone app

Needs full Xcode. Open `GooglyEyes.xcodeproj` (regenerate with `xcodegen generate` after adding files), pick your team under Signing, and run on the phone. It finds the Mac on the same Wi-Fi by itself.

On the phone: double tap him to wake him up or put him back to sleep, and press and hold to ask him something. The faint speaker button at the top right sets the chirp volume and picks which Mac to pair with.

## Focus Sentinel (added)

A second job for the Mac app: keep an eye on what's in front of you, and when you drift away from
what you said you'd be doing, warn you and then close the thing that took you there.

It does not use the realtime voice stack. The Sentinel needs to classify a window a few times a
minute, not hold a conversation:

| Piece | What it was | What the Sentinel uses | Cost |
| --- | --- | --- | --- |
| Brain | `gpt-realtime-2.1` (realtime audio) | **Token Harbor `deepseek-v4.1-flash`** | ~1/10th of a cent per check |
| Eyes | screen capture per turn | front app, window title, exact browser URL, idle time | free |
| Voice | realtime audio out | `AVSpeechSynthesizer` (macOS built-in) | free |

### Why Token Harbor instead of a small local model

A local `llama3.2:1b` (Ollama) model was tried first, for zero cost and full privacy, and it was
**removed**: measured against this build it judged YouTube, Reddit and Steam *all on-task*. It failed
in the permissive direction, so the Sentinel never fired, which is the one thing it exists to do.

`deepseek-v4.1-flash` via Token Harbor scored **6/6** on those same cases at about 1.9s per check,
and it does something no keyword list can: tell a *Wave Optics lecture* on YouTube (on-task) from
*funny cats* on YouTube (drift). Verified end to end through this app's own request path, a YouTube
cats video produced `on_task: false`, `confidence: 0.97`, `block: "youtube.com"`.

**Three tiers decide every drift**, cheapest first:

1. **Topic continuity, ~0ms, no model.** If the new window shares real keywords with your goal or
   locked target it is approved instantly and costs nothing. This is what makes "Wave Optics PDF to
   Wave Optics practice questions" a non-event.
2. **Known distractions, 0ms, no model.** A built-in list of entertainment sites and apps
   (youtube.com, reddit.com, store.steampowered.com, Steam and so on), so the obvious cases never
   depend on a model's mood. Subdomains count; a domain that merely *ends* with a listed one does not.
3. **The model**, for the genuinely ambiguous middle.

**How a drift turns into an action.** Off-task for 60s across at least 2 samples, so a single glance
at a notification is never enough, gets you a warning card at the top of the screen: Bluey says what
he sees, names what he is about to close, and counts down from 10. Escape, "I'm back, stay", or
simply going back to work cancels it. If the countdown runs out, exactly one thing closes:

- the site the model named, and only the tab pointing at it, in the front browser
- otherwise the front tab, if you are in a browser
- otherwise **nothing**, because there is no way to close a distraction safely

Password fields, Forms, and everything in your exemption list are never touched. Idle past 90
seconds counts as being away from the desk, so it never fires while you are making tea.

**Guard rails.** The model's output is treated as untrusted input, not instructions. A `block` value
is only acted on if it is a genuine hostname (`[a-z0-9.-]`, real labels, real TLD) or the exact name
of a *currently running* app; screen text is explicitly ignored as commands. The reply parser is
lenient in exactly one direction: a malformed field is dropped, never guessed at, because a
wrong-typed `point` used to throw and turn a real drift into "on task". 90 checks cover all of this,
including injection attempts, and you can run them yourself:

```
GOOGLY_DEMO_SENTINEL=1 ./build/Bluey.app/Contents/MacOS/GooglyMac
```

**Setting it up.** Menu bar, then **Focus Sentinel** to switch it on, **Set Focus Goal...** to say
what you are working on, and **Sentinel Settings, Token Harbor Key...** for the key (stored in
`~/Library/Application Support/Googly/keys.json`, never in the repo). Gemini and DeepSeek keys work
as fallbacks and are used automatically when no Token Harbor key is present. **Close Distractions
After Warning** turns enforcement off if you would rather it only ever warn. A log of every drift and
action lands in `~/Library/Application Support/Googly/sentinel.log`. Control-Option-L locks the
current window; Control-Option-C checks what you are doing right now.

The first browser check asks for Automation permission so it can read the tab URL; if you decline,
it falls back to window titles and never closes anything it can't identify.

## Layout

- `Shared/` pairing protocol (Bonjour `_googly._tcp`, newline JSON) and colors, used by both apps
- `Mac/` menu bar app (Swift package target `GooglyMac`)
- `iOS/` iPhone app (SwiftUI)
- `Mac/Sources/GooglyMac/Brain.swift` — the DeepSeek client
- `Mac/Sources/GooglyMac/Sentinel.swift` — the watch loop, policy and enforcement
- `Mac/Sources/GooglyMac/SentinelHUD.swift` — the warning card
- `Mac/Sources/GooglyMac/Voice.swift` — free local speech
- `Mac/Sources/GooglyMac/SentinelGuardTests.swift` — the guard-rail self-test

## License

Public domain under [the Unlicense](LICENSE). Do whatever you want with it.




# Project Handoff: Bluey Focus Sentinel

This section used to contain a full agent handoff. It has been **moved to [`HANDOFF.md`](HANDOFF.md)**
and rewritten, because the version that lived here had gone stale in ways that would have caused
real damage:

- It listed four "Pending Tasks" (the `isTopicRelated` keyword matcher, `AIConfig` local routing,
  test expansion, rebuild) that were all completed long ago.
- It instructed the reader to route the Sentinel to a **local Ollama `llama3.2:1b`** model. That
  model was measured judging YouTube, Reddit and Steam all *on-task* and has been deleted. Following
  this section would have reintroduced the exact bug that made the feature silently useless.
- It described `AIConfig` as "Local Ollama vs Cloud routing", which is no longer true.

**Use [`HANDOFF.md`](HANDOFF.md).** It is current, verified against the code, and records the dead
ends (with measurements) so they are not repeated.
