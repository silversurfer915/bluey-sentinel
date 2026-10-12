# Bluey

Bluey is a native Mac assistant with an optional iPhone companion. Open **Bluey** from the menu bar for one place to talk, type a task, manage focus, review study memory, and configure providers. The character and animated cursor remain part of the experience.

## Assistant

Give Bluey a request such as “explain this”, “open my notes”, or a multi-step browser task. It reads visible text and accessible controls, sends screenshots when the selected provider supports vision, takes one screen action at a time, reads the result, and verifies completion. Tasks have step/time limits, repetition detection, and a Stop control (also Control + Option + S). Consequential actions pause for a real user confirmation, bound to the observed app/window/control. Password fields and destructive session shortcuts are refused.

Typed requests, Mac speech commands, and phone requests share the same task state. A second task cannot overlap an active one. Screen contents are treated as data rather than instructions.

## Focus Sentinel

Say or type “focus on wave optics”, “lock this window”, “pause focus for ten minutes”, “resume focus”, “check my focus”, “stop watching”, or “I'm back”. The same controls are available in the Focus page.

While a focus session is active, Bluey checks app/window/tab changes and periodically refreshes context even if the app stays open. Uncertain or failed judgments never count as verified focus. Sustained drift needs another judgment before a warning. Returning to work cancels the warning. Automatic intervention is off for new setups: enabling it permits closing the exact observed browser tab or hiding the observed native app, with another identity check immediately before acting. It never quits an app or closes unrelated tabs.

Study time is credited from elapsed time with a reliable on-task verdict. The test suite uses isolated study files.

## Providers and credentials

Settings offers Gemini 3.1 Flash Lite, Token Harbor (DeepSeek V4.1 Flash), DeepSeek, and a custom OpenAI-compatible endpoint/model. Automatic routing prefers Gemini, then Token Harbor, then DeepSeek when their keys are available. A selected provider stays selected unless its key is unavailable and fallback is enabled. Runtime service failures are reported instead of silently switching services.

Gemini receives images. Text-only providers receive OCR and accessible controls. Custom providers have an explicit vision toggle. Keys are stored in macOS Keychain; legacy keys migrate only after a successful secure write. Never commit credentials. Meeting-note formatting and research use the same provider selection. Public research fetches actual pages and returns their links.

## Microphone

Choose the input directly below the Assistant prompt or from **Microphone** in the menu bar. Switching during listening changes Bluey's capture device immediately without submitting or discarding the current command, and without changing the Mac's system input. The preferred mic is remembered. If disconnected, Bluey uses the default input and shows that fallback.

Option + Space starts/finishes a Mac voice command. Microphone and Speech Recognition permissions are required; Screen Recording provides screen context, and Accessibility enables computer actions. Speech stays on-device when Apple's recognizer supports it. Phone audio continues to use the phone's own microphone.

## Notch and Vorssaint

The simplified Bluey surface prioritizes warnings, active tasks, and listening over passive content. Idle animation and music controls are optional. Coexistence mode puts Bluey below the native notch and suppresses competing passive music controls. Vorssaint's installed app and core features are untouched. No supported general-purpose external notch plugin interface was found in the source inspected, so this build uses an independent coexistence surface.

## Build and verify

```sh
./scripts/build-mac.sh
open build/Bluey.app
swift test
GOOGLY_DEMO_SENTINEL=1 build/Bluey.app/Contents/MacOS/GooglyMac
```

macOS 14 or later is required. Opt-in live checks use existing configured keys and do not print credentials:

```sh
BLUEY_INTEGRATION_CHECKS=1 build/Bluey.app/Contents/MacOS/GooglyMac
BLUEY_INTEGRATION_CHECKS=1 BLUEY_MIC_CHECKS=1 build/Bluey.app/Contents/MacOS/GooglyMac
```

The first command checks provider tool round trips, a generated vision fixture, screen capture, and public retrieval. The second captures short local mic buffers, without saving or uploading audio.

## iPhone companion

Open `GooglyEyes.xcodeproj` in Xcode, select your signing team, and run on the phone. The phone finds the Mac over Bonjour on the same Wi-Fi. Double-tap to wake/sleep, hold to ask, and release to submit. Meeting recordings are sent in chunks and stored under `~/Documents/Bluey Notes/` with transcript/session metadata. Open Meeting Notes from Bluey to reach saved notes.

See `docs/PROGRESS.md` for verification and remaining hardware checks.
