# Bluey integrated assistant — implementation plan

Status: proposed for user approval. No product code changed.

## Outcome

Bluey becomes one voice-controlled, screen-aware assistant. Focus Sentinel, computer actions, research, study memory, meeting notes, phone input, and the notch share commands and state. Gemini 3.1 Flash Lite is the primary default; Token Harbor is the other built-in default option. Additional providers are configurable.

Example: “Help me study wave optics and keep me focused” starts a focus session, shows its status, supports questions about the current page, and monitors drift. “Lock this window,” “pause focus for ten minutes,” “resume,” and “stop” operate the same session from voice, the Mac interface, or the phone.

## 1. Establish a recoverable baseline and reproduce failures

- Preserve the current source and app bundle; inspect version-control status and create a recoverable checkpoint before edits.
- Run existing guardrail checks and record failures without treating their previous pass count as evidence of real operation.
- Trace voice input → command → provider → observation → action → UI result. Add structured diagnostics without keys, audio, or full screenshots in logs.
- Reproduce missed tab changes, same-window drift, failed captures, concurrent requests, key pasting, and stopping an active task.

Evidence already found: tool-result images are discarded in the assistant loop; the loop ends after six rounds without an unfinished-task result; voice tools do not expose Sentinel controls; normal Sentinel polling defaults off; provider routing differs between features; notch callbacks compete for presentation state.

## 2. Unify provider configuration

- Introduce one provider registry/client layer used by the assistant, Sentinel, reflection, and research where their requirements permit. Keep transcription and speech synthesis as separate capabilities.
- Ship Gemini 3.1 Flash Lite as the primary default and Token Harbor as a selectable built-in alternative. Verify supported model identifiers and request formats before implementation.
- Support additional OpenAI-compatible providers through endpoint, model, API key, and declared capabilities: vision, tools, and structured output. Other API formats require an adapter; arbitrary APIs cannot be assumed compatible.
- Use capability-aware routing: a text-only provider receives OCR, accessibility controls, window metadata, and URLs; a vision provider additionally receives screenshots. Show the active provider and any limitation.
- Make fallback explicit and configurable. Never retry a computer action merely because a provider request failed.
- Repair key-entry paste and keyboard handling, migrate credentials into macOS Keychain, and provide a connection test that reports configuration errors clearly.
- Remove local Sentinel model routing and obsolete naming. Retain useful on-device speech recognition and optional local speech synthesis.

## 3. Create shared commands and application state

- Add an application coordinator and command registry. Voice, phone requests, menu actions, and notch controls call the same operations.
- Expose focus start/update, lock current target, pause/resume/stop, check now, warn-only/enforcement mode, study status, research, notes, and task cancellation.
- Execute unambiguous focus and stop commands directly; use model interpretation for varied phrasing and compound requests. Clarify only material ambiguity.
- Define stable states for microphone listening, assistant tasks, focus sessions, warning countdowns, and presentation. Assistant sleep must not implicitly stop focus monitoring.
- Prevent overlapping assistant action loops. Give every task an ID, cancellation token, and explicit completion, failure, cancellation, or partial-result status.
- Use one profile/session store across features. Correct elapsed-time accounting and distinguish user facts from inferred habits.

## 4. Implement a proper task execution loop

- Retain the existing useful tools behind structured execution results rather than replace them for appearance.
- Maintain the requested goal, lightweight plan, completed steps, current observations, and remaining work throughout a task.
- Run observe → choose next step → act → observe → verify, repeating until complete, blocked, cancelled, or limited by a visible time/step budget.
- Pass tool-result screenshots back to vision models. Refresh OCR and accessibility targets after changes; invalidate stale target IDs.
- Capture relevant screen context when the assistant is invoked or needs it, rather than continuously uploading the desktop.
- Serialize UI actions and refresh after each action that changes the screen. Detect foreground changes, failed actions, repeated loops, and missing permissions; recover when possible and otherwise explain the blocker.
- Preserve provider-specific tool-call metadata and valid message history. Keep compact durable task summaries rather than storing unlimited images.
- Enforce cancellation throughout requests and action execution; a stop command must cancel the task instead of refusing actions for only six seconds.
- Verify completion from observable results and report unfinished work honestly. Short notch status updates link to a readable expanded result.
- Preserve protection for credentials, screen-text instruction injection, and actions requiring explicit user confirmation. Enforce these in execution state, not only in the model prompt.

## 5. Repair Focus Sentinel

- Monitor app switches and regularly probe tab/window changes with lightweight metadata. Use real elapsed time for drift and study duration.
- Treat entertainment domains as signals, not unconditional proof of distraction. Relevant lectures and research should remain allowed.
- Inspect OCR/accessibility context for ambiguous pages; use a bounded screenshot with a vision provider when needed. Keep checks economical through caching and sensible intervals.
- Make the current goal and target authoritative. Learned productive tools must not exempt unrelated work from a study goal.
- Represent on-task, off-task, uncertain, and unavailable separately. API/capture errors must not silently count as on-task or justify enforcement.
- Require sustained evidence before warnings, cancel on return/pause/idle, and reevaluate if the warning target changes.
- Store the exact app/browser/tab identity in the enforcement plan and revalidate it before acting. Remove fallback to whichever browser happens to be frontmost later.
- Default to warning and reversible intervention. Closing a tab must be explicitly enabled; avoid automatically quitting an entire application with unrelated windows.
- Route warning acknowledgements and “I’m back” through the shared voice/command system.

## 6. Replace fragmented notch behavior

- Build one presentation controller with explicit priority: actionable warning/confirmation, active assistant task, listening, focus status, then passive content.
- Show a quiet compact Bluey with focus status; expand for transcript, task progress, warning, confirmation, or answer. Put long text in a readable panel rather than clipped bubbles.
- Use restrained animation, predictable hover/click behavior, dynamic text layout, keyboard access, reduced-motion support, and correct scaling on notched and notchless displays.
- Handle display changes, full-screen apps, sleep, lock/unlock, and interrupted state transitions. Passive music updates must not replace an active task or warning.
- Keep secondary settings in one coherent settings window. Buttons remain useful shortcuts, while voice becomes a complete control path.

### Vorssaint integration decision

The installed Vorssaint is version 3.4.1. A supported external notch-plugin interface has not yet been verified.

First inspect its official source/documentation for a supported plugin, widget, IPC, or extension interface. If available, implement a separate optional Bluey adapter that publishes status and receives user commands, with disconnect/reconnect handling. Vorssaint remains responsible for its own native UI and features.

If embedding requires changing or injecting into Vorssaint, do not do it. Implement the improved standalone Bluey surface with placement/coexistence options and without duplicate music controls by default. Describe it honestly as coexistence, not a native Vorssaint plugin. Preserve the installed Vorssaint app and settings.

## 7. Verify the integrated experience

Automated checks:
- Provider selection, capability routing, invalid configuration, fallback, and malformed responses.
- Multi-step task simulation, image propagation, stale targets, cancellation, overlapping requests, retry behavior, and incomplete-task reporting.
- Voice intent routing and shared state across voice/menu/phone.
- Sentinel relevant lecture versus unrelated video, same-app tab changes, sustained drift, idle/pause, provider failure, and changed enforcement targets.
- Notch state priority and restoration after interruptions.

Real app checks:
- Start, pause, resume, update, lock, and stop focus by voice.
- Ask about a visible formula and an element under the pointer.
- Complete a reversible task across multiple UI steps, inspect results, and cancel midway.
- Verify a permitted study transition, actual distraction warning, return-to-work cancellation, and safe intervention against a disposable test tab.
- Confirm key pasting, permission feedback, provider connections, relaunch persistence, screen changes, and coexistence with Vorssaint.
- Test both Gemini and Token Harbor if valid configured credentials are available; report unavailable live tests explicitly.
- Test the phone path if a paired phone is available; otherwise mark it unverified.

## Delivery order and completion criteria

Implement in reviewable checkpoints: baseline → provider layer → shared commands/state → assistant task loop → Sentinel → notch/optional adapter → live verification and release build.

Deliver the source changes, updated documentation, recoverable checkpoints, a built Bluey.app, and a verification report distinguishing tested behavior from limitations. Completion means the end-to-end scenarios above work, not merely that the build or old guardrail suite passes.

Approval of this document authorizes implementation of this scope and its conditional standalone-notch fallback. It does not authorize modifications to Vorssaint’s core or installed app.
