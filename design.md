# Bluey UI Redesign — Implementation Design Contract

**Status:** Approved design direction; implementation brief for DeepSeek  
**Updated:** 2026-10-13  
**Primary target:** Native macOS menu-bar app  
**Companion target:** Native iPhone and iPad controller  
**Direction selected by owner:** Calm warm study studio

This is a concrete build specification, not a request to “make it premium.” Follow the measurements, information order, states, copy, and acceptance checks below. If the existing implementation conflicts with this document, preserve its behavior and data contracts while changing presentation. The explicit menu-bar-only rule in this document supersedes the earlier Dock-companion choice recorded in `HANDOFF.md`.

## 1. Product experience

Bluey should feel like a capable, gentle study companion that is immediately reachable from the Mac menu bar. The interface is for doing work: ask Bluey something, start or control focus, review what it remembers, and tune providers or access. Character comes from Bluey's small recognizable identity, warm surfaces, clear language, and a quiet focus-progress signature—not from decorative clutter.

### Success criteria

1. The Mac app is available from the menu bar and has **no Dock icon**, Dock menu, or Dock-based session indicator.
2. In one glance, the user can distinguish Ready, Listening, Working, Focus active, Focus paused, Attention needed, and Emergency Stop latched.
3. The Assistant is the primary full-workspace destination; Focus, Memory, Token Caching, and Settings remain one selection away.
4. Primary controls work with mouse, keyboard, VoiceOver, and the paired phone where applicable.
5. The phone app remains a controller with live session state and controls; it does not become a reduced read-only dashboard.
6. Screen-aware context, computer actions, and access policy remain explicit. A visual redesign must not broaden permissions or bypass confirmation.
7. Light and dark appearances are both intentional, text remains readable, and motion respects Reduce Motion.

### Non-goals and hard boundaries

- Do not add a Bluey notch, floating session pill, or persistent overlay to represent focus. The menu-bar item and its popover are the Mac's persistent status surface.
- Do not show a Bluey Dock icon or Dock progress ring. Do not keep `.regular` activation policy or `LSUIElement=false` merely to preserve the old Dock design.
- Keep the existing cursor character/pointer companion as an optional, separately controlled feature if it is needed for pointing. It is not the focus-status indicator and must not start a second persistent HUD.
- Do not change agent logic, provider routing, memory extraction rules, focus/Sentinel rules, phone transport, session identities, permissions, Sanctra authentication/sync, or data storage as part of this UI work.
- Sanctra is parked. Do not redesign its connection flow or modify its auth/sync behavior. Shared shell typography and colors may apply without changing that feature's contents or behavior.
- Preserve bundle identifiers, App Group identifiers, URL schemes, hotkeys, Keychain keys, and phone pairing behavior.
- Do not add packages, remote fonts, emoji icons, unsupported Dock APIs, or new permission prompts.

## 2. Visual direction: Calm Warm Study Studio

### Visual source

Use the feeling of a well-kept study folio: warm paper as the quiet ground, graphite ink for reading, small blue-violet annotations for action and focus, and precise ruled separators only where grouping needs help. Translate that world into native controls; do not draw notebook paper, binder rings, tape, stationery, or a fake desk into the app.

The app remains immediately recognizable as Bluey. Retain its Bluey character mark and existing blueberry/indigo identity. Reduce the current high-saturation blue from a general-purpose fill to a deliberate action and focus accent.

### Signature interaction: the Focus Thread

One slim indigo progress stroke follows the current focus session across three places: the menu-bar status label, the active-session card in the popover, and the Focus page hero. The stroke advances from real elapsed/planned values; when no plan exists, show elapsed time without a false completion percentage. On the phone, use the same semantic progress and session state with native iOS treatment. The line never animates continuously while idle and never substitutes for a numeric timer or status label.

The Focus Thread is the only recurring decorative motif. Do not add unrelated glows, pulsing borders, floating bubbles, or ornamental gradients.

## 3. Design tokens

Use a three-layer token system: primitive values → semantic roles → component roles. Define tokens in `BlueyTheme.swift` or small focused token files and consume them everywhere. Do not leave screen-local hex/`Color(red:)` values after migration. Use system semantic colors for native text and controls where they are a better fit than a hard-coded color.

### Color primitives

These values establish the chosen warm direction. Dark appearance values are separate, not created by lowering opacity over the light theme.

| Primitive | Light | Dark | Use |
|---|---:|---:|---|
| Warm paper | `#F5F3EE` | `#17191D` | Workspace canvas behind grouped surfaces |
| Clean surface | `#FFFFFF` | `#22252A` | Main cards, popover and settings groups |
| Raised surface | `#FBFAF7` | `#292D33` | Selected rows, inset panels, composer |
| Ink | `#24262B` | `#F2F1EC` | Main text |
| Ink secondary | `#656A73` | `#B2B5BC` | Supporting labels and metadata |
| Ink quiet | `#696E76` | `#8E949D` | Tertiary metadata; still meets normal-text contrast on the canvas |
| Bluey indigo | `#5366CF` | `#A9B6FF` | Primary action, selected navigation, Focus Thread |
| Indigo tint | `#E9ECFA` | `#30364E` | Selected navigation and quiet focus backgrounds |
| Divider | `#E5E2DA` | `#3A3E45` | Section separation and table rules |
| Success | `#287653` | `#75C99A` | Connected, completed, or healthy state |
| Attention | `#95600F` | `#E7B963` | Warning, permission needed, paused-with-attention |
| Destructive | `#B23F45` | `#F08D91` | Emergency Stop and irreversible actions |

### Semantic and component roles

- `canvas`: Warm paper.
- `surface`: Clean surface.
- `surfaceRaised`: Raised surface.
- `textPrimary`, `textSecondary`, `textTertiary`: Ink roles above.
- `accent`, `accentSubtle`, `selection`: Bluey indigo, indigo tint, indigo tint.
- `success`, `attention`, `destructive`: semantic status colors above; pair each with text or an icon.
- `separator`: Divider.
- `buttonPrimary`: Indigo fill, white text in light mode, dark ink text in dark mode when contrast requires it; 10 pt radius, 36 pt default height on Mac, 48 pt on iOS.
- `buttonSecondary`: Clear or surface fill, ink text, 1 pt divider border; same target height as primary.
- `buttonDestructive`: Destructive text and icon on a clear/surface background until an explicit destructive confirmation is needed. Use a filled red control only for the immediate Emergency Stop affordance.
- `focusThread`: 2 pt stroke with a rounded end; selected indigo when active, neutral track behind, attention color when paused for a user-visible warning. Always show the time and state in text.
- `statusBadge`: Tinted background, semantic icon, readable label; do not encode state through color alone.

### Shape, spacing, and depth

| Token | Value | Apply to |
|---|---:|---|
| `space1` | 4 pt | Icon/text micro-gap |
| `space2` | 8 pt | Compact control groups |
| `space3` | 12 pt | Row internals |
| `space4` | 16 pt | Card padding and standard gaps |
| `space5` | 24 pt | Section spacing |
| `space6` | 32 pt | Major page blocks |
| `space7` | 40 pt | Empty-state breathing room |
| `radiusControl` | 8 pt | Inputs and compact controls |
| `radiusCard` | 14 pt | Cards and grouping surfaces |
| `radiusHero` | 18 pt | Focus hero only |
| `radiusPill` | Capsule | Small status badges only, not every control |
| Border | 1 pt | Card edge only when tonal separation is insufficient |

Use flat tonal layering first. A card may have one very soft native shadow (black at 4% opacity, blur 12 pt, vertical offset 3 pt) only when it needs to lift above the canvas. Avoid frosted-glass cards, broad drop shadows, glowing outlines, and stacked nested cards.

### Typography

- Use the system San Francisco family. Use the rounded system design only for the Bluey wordmark, one welcome headline, and small character moments; use standard system text for navigation, settings, tables, and long copy.
- Use native text styles where possible. For the Mac workspace, the page title is 23 pt semibold; section titles 15 pt semibold; body 13–14 pt; supporting copy 12–13 pt; metadata 11–12 pt; never use metadata-sized text for a required action or permission explanation.
- Use monospaced system digits for the focus timer and elapsed-duration columns. Keep time numerals tabular so they do not jump as they update.
- On iPhone/iPad, use native Dynamic Type text styles. The main timer may be a scaled monospaced design, but it must still scale and must not clip.
- Do not use hard-coded small rounded fonts across all labels. Avoid uppercase labels except short technical statuses such as `PAUSED` when accompanied by an accessible spoken label.

## 4. macOS application presence and navigation

### Menu-bar-only application

The menu-bar item is Bluey's persistent home. The workspace is a normal resizable window opened from that item; closing or hiding it leaves Bluey available in the menu bar. Quit is explicit and available from the popover. Keep the existing global shortcut behavior unless separately approved.

Implementation requirements:

1. Set the packaged app to an accessory/menu-bar application (`LSUIElement = true`) and use `NSApplication.ActivationPolicy.accessory` at launch. Do not leave a regular-activation fallback that creates a Dock icon.
2. Keep one `NSStatusItem` and use it as the single global status entry. Do not start `DockCompanion`; retire its progress-ring presentation and remove Dock menu actions from the new user-facing design.
3. Closing the workspace must not terminate the server, Sentinel, voice input, or paired-phone session. It only closes the workspace window.
4. Verify the built app has no Dock tile, no app-switcher tile, no Dock menu, and remains reachable from the menu bar after opening and closing the workspace. Verify Quit works from the popover.
5. Do not remove the app's bundle icon asset from its package metadata if the build system requires it. The requirement is that the running accessory app does not display in the Dock.

### Status item

- Idle: Bluey mark only; tooltip/accessibility label “Bluey — Ready”.
- Listening: same Bluey mark with a small microphone/wave state badge that does not replace the mark; tooltip “Bluey — Listening”. No continuous large waveform animation.
- Working: Bluey mark plus a subtle indeterminate progress indicator in the popover. The status item uses a small dot or equivalent state treatment and label “Bluey — Working”.
- Focus active: Bluey mark and a compact elapsed/planned label such as `18/30` when menu-bar space permits. If space is constrained, keep the mark and put the full time in tooltip and popover. Do not show a fake ring in the Dock.
- Focus paused: mark plus pause-state semantics; popover says “Paused”.
- Attention needed: attention symbol/badge plus clear tooltip and visible alert content in the popover. Do not rely on color alone.
- Emergency Stop: destructive stop-state mark plus explicit “Stopped” text in popover. The stop state must remain latched until the explicit Resume action.

Use an 18 pt-or-smaller template-compatible status image with crisp monochrome contrast; use the existing Bluey asset only if it renders cleanly at menu-bar scale. Keep the mark visually stable across states. Provide a full VoiceOver label that includes the current state. Do not blink, pulse, or animate the menu bar continuously.

### Menu-bar popover wireframe

Target size: 360 pt wide by approximately 500 pt tall, content-driven with a sensible maximum height and scrolling on short displays. It should feel like a compact control surface, not a miniature settings dashboard.

```text
┌──────────────────────────────────────────────┐
│ [Bluey mark]  Bluey                  Ready   │
│               Gemini · local microphone      │
├──────────────────────────────────────────────┤
│ ACTIVE FOCUS                                 │
│ Physics · Wave Optics                 18:42  │
│ [━━━━━━━━━━━━━━──────────────]   of 30:00   │
│ [Pause] [Open Focus]                         │
├──────────────────────────────────────────────┤
│ [Ask Bluey…                         ⌥ Space] │
│ [Start focus]       [Choose microphone ▾]    │
├──────────────────────────────────────────────┤
│ [Emergency Stop]     [Open Bluey workspace]  │
│ Settings                                  Quit│
└──────────────────────────────────────────────┘
```

When no focus session exists, omit the ACTIVE FOCUS block; do not leave a blank card. Replace it with one quiet line: “No focus session active” and a `Start focus` action. During a stopped state, replace the Stop action with a prominent `Resume Bluey` action and explain that computer actions and voice are stopped. The focus timer continues only if the existing session model says it is active; never infer state from a UI timer.

Popover behavior:

- Clicking the status item opens the popover. Clicking outside closes it. Escape closes it without changing a session.
- `Ask Bluey` opens the workspace with the Assistant selected and focuses the composer. `Open Focus` opens the Focus page. Settings opens the relevant settings category.
- The microphone picker lists available devices, current device, system default, and a concise unavailable/error state. Selecting one changes Bluey's input route immediately without changing the macOS system input.
- Emergency Stop is visible without scrolling. It stops current computer actions and voice work per existing policy; it does not silently stop or delete a focus record. Resume is explicit.
- Provide clear pressed, disabled, busy, and error states. Disable only the action currently executing; do not freeze unrelated navigation.

### Full workspace shell

Default window: **1080 × 740 pt**, minimum **860 × 600 pt**. Keep the existing ability to resize. Use a native `NavigationSplitView`-style sidebar/detail hierarchy or equivalent accessible native structure rather than a fixed custom HStack that cannot adapt. Keep page selection above any width-dependent layout branch so resizing does not reset the page or conversation.

At widths of 980 pt or greater:

```text
┌─────────────────────┬────────────────────────────────────────────┐
│ Bluey identity      │ Page title             [status] [Stop/Resume]│
│ Ready · provider    ├────────────────────────────────────────────┤
│                     │                                            │
│ Assistant           │ Main page content                          │
│ Focus               │ max readable content width ~900 pt         │
│ Memory & Skills     │                                            │
│ Token Caching       │                                            │
│ Settings            │                                            │
│                     │                                            │
│ Focus Thread card   │                                            │
│ ⌥ Space · talk      │                                            │
└─────────────────────┴────────────────────────────────────────────┘
      208–224 pt                    flexible detail column
```

At narrower sizes, allow the sidebar to collapse with a labeled toolbar navigation control; show one page at a time. Keep the Emergency Stop/Resume affordance in the detail toolbar at all sizes. Do not shrink controls below readable sizes to preserve a side-by-side layout. The sidebar's compact active-focus summary may show subject, timer, and status, but no second set of destructive session controls.

Sidebar details:

- Brand row: Bluey mark at 30 pt; “Bluey” at 17 pt; state at 12 pt. Do not use a tiny status dot as the only state.
- Primary destinations, in this order: Assistant, Focus, Memory & Skills, Token Caching, Settings.
- Selected row: 34–36 pt high, 8 pt radius, indigo-tinted background, icon and label in accessible selected state. Use native SF Symbols with a consistent 16 pt optical size.
- Bottom focus summary appears only when a session is active or paused. It shows subject, elapsed/planned time, and `Active`/`Paused`; clicking opens Focus.
- Show the current provider and ⌥Space hint in the footer, but do not cram API details or debug telemetry into the sidebar.

Global header:

- Left: title (23 pt semibold) and one-line subtitle (13 pt secondary) with a maximum of two lines at accessibility sizes.
- Right: compact state label and a persistent Emergency Stop/Resume control. While an agent task is running, show a progress status and a `Stop task` secondary destructive action. Separate “stop current task” from “Emergency Stop Bluey” in label and confirmation copy.
- Header height is content-driven, with 24 pt horizontal inset and 20–24 pt vertical inset. No oversized decorative banner.

## 5. Mac screen specifications

### 5.1 Assistant

Purpose: ask a question or request a task and understand what Bluey is doing. The first view should make the input obvious and explain when screen access or approval is involved.

```text
Assistant                                             [Ready] [Emergency Stop]
Ask a question or give Bluey a task

┌───────────────────────────────────────────────────────────────────────┐
│ Focus Sentinel · Not watching                         [Open Focus]   │
└───────────────────────────────────────────────────────────────────────┘

                 What are we working on?
    “Ask, research, plan a focus session, or help with the screen.”
       [Explain this screen] [Plan a study session] [Research…]

                    conversation / result stream

┌───────────────────────────────────────────────────────────────────────┐
│ Ask Bluey…                                                             │
│ [+ context when requested] [voice] [Send]                            │
└───────────────────────────────────────────────────────────────────────┘
```

Rules:

- Use a real conversation transcript, aligned as native content rows, not a collection of large chat bubbles. User messages align trailing; Bluey responses align leading. Keep line length around 68–82 characters in the detail column.
- Keep the composer anchored to the bottom of the Assistant content only. It has a vertical-growing field, 2–5 visible lines, 12 pt internal padding, and a clear `Send` button. Return submits; Shift-Return inserts a line break. Keep the existing keyboard behavior if it differs and is relied on elsewhere.
- Put voice entry beside the composer with text label available to accessibility. Listening state shows a compact waveform, live transcript, and `Stop listening`; Reduce Motion displays a static listening icon.
- Show “Screen context off” or “Using current screen” as an explicit, compact context chip only when relevant. Do not capture or attach screen content without the existing user-invoked behavior.
- Suggestions are at most three contextual buttons, shown only when the conversation is empty. Use accurate action verbs and no emoji: `Explain this screen`, `Plan a study session`, `Research a question`.
- Tool activity is a collapsible “Working” timeline with current step, completed steps, and error state. It does not print raw tool payloads or private screen text. The user can stop the current task without invoking global Emergency Stop.
- Approval card appears inline at the exact point where an action needs approval. State the action, target app/control, and consequence in plain language; controls are `Allow this action` and `Cancel task`. Do not use a vague `Allow` button.
- Sentinel warnings appear as a stable, dismissible inline banner with clear reason and action. Do not put a large HUD over other apps. A banner never steals keyboard focus.
- Error responses preserve the user's prompt and provide retry or correction where safe. Loading is a small progress state and visible status label, not an empty screen.

### 5.2 Focus

Purpose: configure or control a study session and understand exactly what Sentinel is observing or allowed to do.

```text
Focus                                                [Active] [Emergency Stop]
Your session and Sentinel controls

┌───────────────────────────────────────────────────────────────────────┐
│ PHYSICS · WAVE OPTICS                         ACTIVE                  │
│                                                                       │
│       18:42             [Focus Thread: 62% of 30 min]                 │
│       elapsed           Planned 30 min · Started 2:14 PM              │
│                                                                       │
│   [Pause]       [Finish session]       [Abandon session…]             │
└───────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────┐ ┌──────────────────────────────────┐
│ SENTINEL                         │ │ CURRENT TARGET                   │
│ Watching · checks every …        │ │ Safari · example.com              │
│ [Pause monitoring] [Check now]   │ │ [Lock front window] [Unlock]      │
│ Intervention: Off / Ask / …     │ │ Exempt apps and domains…          │
└────────────────────────────────┘ └──────────────────────────────────┘

Recent checks  [Show details ▾]
```

Start/configure state:

- Show an uncluttered form: Subject (if available), Topic (optional), Goal (required for Sentinel), planned duration, and Start Focus. Use visible field labels and inline validation.
- Planned duration presets: 25, 30, 45, 60 minutes plus custom. Do not hide arbitrary duration entry behind a picker.
- Explain Sentinel in one sentence: “Bluey checks the active app or browser target against your goal while focus is active.” Link to details for exact monitor/intervention behavior.
- Show monitoring and intervention as distinct controls. Pausing monitoring must not imply that the session timer paused. Permission requirements are shown next to the relevant control, with a direct System Settings button.

Active state:

- Make subject/topic, elapsed time, planned time, start time, active/paused status, and remote sync state readable without scrolling.
- Primary action changes by state: `Pause` while active; `Resume` while paused. `Finish session` completes and records actual duration. `Abandon session…` asks for confirmation and records abandoned state; never celebrate it as completed.
- Use a timer that updates from timestamps/model state; text uses monospaced digits. The Focus Thread has a numeric equivalent.
- If Sanctra sync is connected, show `Synced` or an honest pending/error status, but do not change the parked integration flow.
- Lock/unlock target and intervention settings are below the session hero. Avoid placing them above the timer or mixing them with End Session controls.

Recent checks:

- Default collapsed. Expanded view is a readable list with time, observed app/site label when safe, outcome, and explanation. Use a native table/list with column headers at wide sizes and stacked rows at compact sizes.
- Empty state: “No checks yet. Sentinel activity will appear here while monitoring is on.”
- Clearing history is a secondary menu action with a confirmation dialog. Do not show an empty, bordered table with placeholder rows.

States to design and verify: no active session; planned; active; paused; completed; abandoned; no goal; missing Accessibility permission; missing Screen Recording permission; monitoring off; intervention off; intervention asking; drift warning; uncertain screen judgment; phone disconnected; sync pending; Emergency Stop latched.

### 5.3 Memory & Skills

Use a two-item segmented control within the page: `Memories` and `Learned skills`. These are distinct stores and concepts; never present a workflow procedure as a fact about the user.

Memories view:

- Header: “Memory” and a sentence explaining “Review and edit facts Bluey may use to personalize future replies.”
- Controls: search field, category filter, `Add memory`, and a labeled pin filter. Keep `Forget everything` in a secondary overflow/destructive area.
- Row/card order: fact text; category badge; source and confidence; pinned state; last-used time and reason when available; Edit and Delete actions. Do not show confidence as a precise percentage unless the product model stores and explains one.
- Manual add/edit uses a native sheet with Category, Fact, optional “Use this when” context, Save, and Cancel. Inline errors identify the invalid field.
- Empty state: use a native unavailable-content pattern with the Bluey mark, “Nothing remembered yet,” brief privacy explanation, and `Add a memory`.
- Forget Everything uses a native confirmation dialog that clearly says this deletes local memories and recall metadata. It must not delete provider usage or learned skills.

Learned skills view:

- Explain that Bluey can suggest reusable procedures from repeated verified success, and nothing becomes active without owner approval.
- Segments or filters: `Needs review`, `Published`, `Paused`.
- A proposal card shows sanitized title, short description, preconditions, ordered steps, number of verified successes, and date span. Do not render raw prompts, screen captures, paths, URLs, or tool arguments.
- Actions for proposals: `Review`, `Reject`. Review opens Edit, `Publish`, and Cancel. Publish is an explicit user action and shows a confirmation summary. Rejection removes it from planner context.
- Published cards expose `Pause`, `Edit as new revision`, and `Delete`. A new revision never replaces the currently published revision without a separate approval.
- Empty state distinguishes “No suggestions yet” from “No published skills.” State that suggestions appear only after repeated verified workflows.
- All skill runs continue to use current permission checks, screen observation, action approvals, verification, and Emergency Stop. The UI must never imply that publishing grants blanket computer access.

### 5.4 Token Caching

Purpose: explain actual provider-reported token reuse, latency, and unknown telemetry without invented savings.

```text
Token Caching                         [Provider ▾] [Date range ▾]
Only provider-reported cache usage is counted as confirmed.

┌──────────────────┐ ┌──────────────────┐ ┌────────────────────┐
│ Confirmed reuse  │ │ Confirmed rate   │ │ Median latency     │
│ 12,840 tokens    │ │ 31% of known     │ │ 1.8 s              │
└──────────────────┘ └──────────────────┘ └────────────────────┘

Provider history / daily trend (only when enough records exist)

Recent requests
Time     Provider / model       Cache evidence     Input   Reused   Latency
```

- Metric cards use the same baseline and title placement. Label a metric `Unknown` or `Not reported` when the provider omitted it. Do not turn missing values into zero misses.
- No dollar-savings metric unless an exact, current provider rate is configured and explained. Do not show the old blended hard-coded price.
- The rate denominator includes only requests with confirmed telemetry. Show the count of included requests beside the rate.
- A chart is secondary to a readable table. It has labeled axes, a text summary, accessible data descriptions, and no red/green-only distinctions.
- Recent request rows show time, provider/model, route/tier, cache evidence (`Confirmed`, `Not reported`, `Malformed`), input tokens, reused tokens, and latency. Long model names truncate with a tooltip, not a compressed unreadable column.
- `Reset statistics` is an overflow/destructive action with confirmation. It resets telemetry only, never memory or keys.
- Empty state: explain that provider usage appears after requests and that cache data depends on provider reporting. Do not show zero-valued faux analytics.

### 5.5 Settings

Replace the single long mixed settings scroll with a native settings navigation hierarchy. Keep every existing setting and action available; reorganize without changing defaults or meaning.

```text
Settings
├─ Providers
├─ Voice & Microphone
├─ Access & Safety
├─ Focus Sentinel
├─ Appearance & Companion
└─ Connections
```

Use a compact category list within Settings on wide windows and a one-column settings stack on narrow windows. Settings groups are full-width, separated by headers and concise helper text. Prefer native form controls and consistent row heights; do not put every toggle inside an independent floating card.

Providers:

- Show routing mode first, followed by Fast and Flagship provider groups and fallback behavior. Keep current provider/model names visible.
- API key rows use secure fields, an explicit saved-in-Keychain state, Save/Replace action, Test connection, test-in-progress, success, and inline failure states. Never expose secret values after save or put them in logs/screenshots.
- Custom endpoint fields appear only when Custom is selected. Validate URL/model format inline. Vision support is explicit and only enabled if the selected provider supports it.

Voice & Microphone:

- Put the live input picker first: device name, system default, availability, and current-selection checkmark. A selection takes effect immediately and never changes the system-wide input.
- Voice enabled, reply voice, voice choice, and preview follow. Separate input-device controls from output-voice controls.
- Listening and permission errors appear beside the relevant row with a direct action to open System Settings.

Access & Safety:

- Put the latched `Emergency Stop` status and `Resume Bluey` action at the top when stopped.
- Explain the current computer-control access mode in plain language. Show Off, Ask Every Time, and the existing broader mode without changing semantics.
- Explain macOS Accessibility and Screen Recording permissions separately. Show granted/missing/denied states, and open the exact relevant System Settings pane.
- No permission is silently granted by a design choice, onboarding shortcut, remembered workflow, or theme toggle.

Focus Sentinel:

- Organize Goal, Monitoring, Target lock, Intervention, Exempt apps/sites, and Warning timing in that order.
- Each control gets one plain-language helper sentence and a state. Separate monitoring from automatic intervention.
- Preserve exact existing settings and defaults. This section is not the session start/stop page; link to Focus.

Appearance & Companion:

- Include theme choice (`System`, `Light`, `Dark`) only if supported by the current app infrastructure; otherwise document as a future UI-only item and do not add a nonfunctional control.
- Keep existing cursor companion controls if the feature remains supported; label them as optional on-screen pointer behavior. Do not offer a Dock-companion toggle or a Bluey notch toggle.
- Reduced Motion follows the system setting; do not introduce a new override unless the current settings model already supports one.

Connections:

- Keep the existing Sanctra settings behavior unchanged while the integration is parked. No token testing, account-linking, endpoint, sync, or copy changes in this UI pass.

## 6. iPhone and iPad design

Keep the phone app a real controller. Use native iOS navigation and controls; share semantic colors, typography character, Bluey mark, status language, and the Focus Thread idea, not desktop layout dimensions. Preserve the current pairing protocol, commands, haptics, quiet hours, presets, history, widgets, and Live Activities.

### Phone primary navigation

Use native tabs in this order: `Focus`, `Quick Actions`, `History`, `Settings`. Pairing/error status remains visible in the affected destination and in the global connection badge. Keep the currently selected destination stable through window-size and size-class changes.

### Focus tab

- Header: Bluey identity and Mac connection state, with a text label (`Connected`, `Reconnecting`, `Offline`).
- Main session card: subject/topic, Active/Paused status, large monospaced elapsed time and planned duration, Focus Thread, and last-sync age when useful.
- Primary controls: one prominent Start/Resume/Pause action appropriate to state. Secondary `Finish` is clear; `Abandon session` is separated and asks for confirmation. Never place Finish and Abandon adjacent with identical visual weight.
- Start flow: subject/topic, duration presets and custom duration, then Start. Keep one-handed reach for the main action.
- Emergency Stop remains visible whenever the Mac reports it latched; explain it stops agent/voice actions, not the study record. Resume is explicit.
- Pending action approval is a prominent card with action and target details plus `Approve`/`Decline`; never make an approval swipe-only.
- Session start/pause/complete motion is brief, stateful, and calm. Respect quiet hours and Reduce Motion; haptics remain independently controllable.

### Quick Actions tab

- Group commands by `Focus`, `Bluey`, and `Computer`. Use a two-column adaptive grid on iPhone only when labels remain legible; use a list/side-by-side arrangement on iPad.
- Each action row has a concise title, one-line explanation, icon, and visible busy/disabled state. No action is available when the paired Mac is offline unless the existing command is queue-safe.
- Keep saved presets distinct from direct commands. Each preset shows title, duration, and subject where configured.

### History tab

- Group sessions by day; row contains subject/topic, date/time, duration, completion/abandonment state, and source when known.
- Detail uses a native pushed destination or sheet with notes and session metadata. Empty and disconnected states have separate copy and an explicit retry/refresh action.
- Local voice transcripts remain in a separate section and are never mixed into study-session history.

### Settings tab

- Sections: Mac connection and pairing, quick actions/presets, haptics and quiet hours, widget/live activity state, app appearance if implemented, and app info.
- Pairing flow displays the same code on both devices and instructs the user to compare it. Do not improve visual simplicity by removing the compare-code security step.
- Widget/Live Activity controls and stale-state labels continue to state that they show last-confirmed Mac state. Keep all deep links session- and revision-bound.

### iPad and resizing

- At regular width, use a native sidebar/detail layout or a wider split that keeps Focus state and controls together. At compact width, present the same content in a single-column navigation stack.
- Use `horizontalSizeClass`/`verticalSizeClass` and available space, not device model or orientation, to select compact vs. expanded layouts.
- All critical actions remain available in both sizes. Do not hide Emergency Stop, Resume, pairing, or approval controls in an overflow menu because the device/window is small.
- Support Dynamic Type without clipping timers, buttons, or pairing codes. Maintain at least 44 × 44 pt hit regions and 8 pt minimum space between unrelated targets.

## 7. Shared components and states

| Component | Specification |
|---|---|
| `BlueyMark` | Existing character mark; retain source asset and proportions. Use one consistent size family: 16–18 pt menu bar, 30–34 pt workspace/sidebar, 40–48 pt empty state. Hide decorative duplicates from VoiceOver. |
| `PageHeader` | Title, short subtitle, optional state chip; consistent alignment and spacing. Avoid repeated nested cards. |
| `StatusBadge` | Icon + readable word; semantic color background; supports Ready, Listening, Working, Active, Paused, Offline, Needs permission, Stopped. |
| `FocusHero` | Subject/topic, state, elapsed/planned time, Focus Thread, start/pause/resume/finish/abandon controls by state. Contains one main surface, not multiple nested cards. |
| `InlineNotice` | Neutral/success/attention/error variants; icon, title, explanation, optional action, dismiss if noncritical. Never color-only. |
| `ActionButton` | Native `Button`, text label, SF Symbol optional; 36 pt Mac visual height with forgiving hit area, 48 pt iOS. Disabled state includes reason if not self-evident. |
| `FormRow` | Visible label, native control, helper/error below; controls align to a shared trailing edge in settings. |
| `DataRow` | Primary value, secondary context, status; aligns on a stable grid and adapts to stacked presentation at narrow widths. |
| `EmptyState` | Native unavailable-content view where appropriate; specific message and one useful next action. No decorative filler charts or fake records. |
| `ConfirmDestructiveAction` | Native confirmation dialog/sheet, attached to its source control; name the actual effect. Escape/Cancel never performs the action. |

Every interactive control must define: default, hover (Mac), pressed, keyboard-focused, disabled, busy, error, and selected states where relevant. Keep layout bounds stable during pressed/focus states. Do not depend on hover for essential help or controls.

## 8. Motion and sound

- Standard navigation/selection: 160–220 ms ease-out, subtle opacity/tint change, no bounce.
- Popover appearance: native AppKit/SwiftUI presentation; do not create a custom notch or springing floating panel.
- Focus start: one 220–300 ms Focus Thread draw-in and a restrained haptic on phone; no confetti, screen flash, or audio unless already enabled by the user.
- Pause: stop progress movement immediately; transition badge and button label with a short crossfade. Never keep a looping animation while paused.
- Finish: short completion state, record confirmation, and brief haptic. Abandon does not use the success animation.
- Working: small progress indicator and text. Avoid random or continuously pulsing waveform bars.
- `accessibilityReduceMotion` replaces movement with a quick state change or opacity transition. The interface remains understandable with all animation disabled.

## 9. Accessibility and resilience

- Contrast: target at least 4.5:1 for normal text and 3:1 for large text and meaningful control boundaries, in both light and dark appearances.
- Every icon-only menu-bar, toolbar, or row button has a descriptive accessibility label, hint if needed, and selected/disabled/expanded state. Visual labels remain present on primary actions.
- Reading order follows the visual order. Dynamic status updates announce concise phrases without moving VoiceOver focus or repeatedly interrupting the user.
- Keyboard: sidebar selection, focused composer, send, stop task, focus controls, settings navigation, and dialog dismissal must all work without a pointer. Preserve existing system shortcuts and menu equivalents.
- Use `Button`, native `Picker`, `Toggle`, `TextField`, `NavigationSplitView`/`NavigationStack`, native alerts/sheets, and semantic styles. Do not implement controls as tappable `HStack`/`onTapGesture` containers.
- Support long provider/model names, translated copy, increased text size, narrow windows, and no-data/error/loading states. Do not truncate the only explanation of permissions or destructive behavior.
- Color is never the only state signal. Charts and the Focus Thread include text/numeric values and VoiceOver summaries.

## 10. Implementation map and order

Implement this as a presentation pass. First read `HANDOFF.md`, `docs/PROGRESS.md`, this file, and the current diff. The current Dock design in the handoff is superseded only for app presence/focus presentation. Do not clean, reset, or overwrite existing changes. Keep feature changes out of the UI commit unless required to make the visual controls truthful.

1. **Baseline and token audit:** run current tests/build; inventory all Mac/iOS surfaces and existing behavior. Capture baseline screenshots. Check `git status` and preserve in-progress memory/cache work.
2. **Menu-bar presence:** hide the Dock tile and app-switcher entry; keep NSStatusItem as the entry. Replace Dock progress state with compact menu-bar state and the popover. Keep Quit and Emergency Stop reachable.
3. **Workspace shell:** introduce semantic tokens and rebuild sidebar/header/resizing behavior. Confirm navigation and state persist while resizing.
4. **Assistant and Focus:** implement the exact hierarchy and states above. Preserve tool approvals, Sentinel states, focus session identity, and session persistence.
5. **Memory, Skills, and Token Caching:** apply the shared components to real data; design empty/populated/loading/error/unknown states; keep the two stores and reset/delete scopes distinct.
6. **Settings:** regroup without changing setting keys/defaults. Keep provider keys secure and microphone route instant. Leave Sanctra behavior untouched.
7. **Phone and tablet:** apply the shared identity to each native screen; preserve all controller actions, pairing, history, haptics, widgets, and Live Activity behavior.
8. **Visual verification:** build, run tests, open actual app screens, capture the matrix below, inspect images, fix visible defects in one bounded pass, then recapture. Report unavailable hardware/device cases honestly.

Use focused SwiftUI view files/components instead of extending the already large `BlueyWorkspace.swift` with more screen code. Keep business logic out of `body`, `onAppear`, and button closures. Avoid third-party UI frameworks and preserve the current deployment targets.

### Existing source areas

- Mac app launch/presence/status menu: `Mac/Sources/GooglyMac/main.swift`, `AppDelegate.swift`, `Mac/Info.plist`.
- Main workspace, focus, memory, cache, settings: `Mac/Sources/GooglyMac/BlueyWorkspace.swift`.
- Current tokens/shared UI: `Mac/Sources/GooglyMac/BlueyTheme.swift`, `Shared/Palette.swift`.
- Dock focus indicator to retire from the experience: `Mac/Sources/GooglyMac/DockCompanion.swift` and its call sites. Do not leave it starting at launch.
- Phone controller: `iOS/Sources/BlueyAppView.swift` and its focused subviews/stores.
- Product truth and existing verified behavior: `PRODUCT.md`, `HANDOFF.md`, `docs/PROGRESS.md`.

## 11. Screenshot and verification matrix

Capture real application UI with synthetic, clearly non-private fixture data. Never use live API keys, real memory contents, private study notes, real screen text, or personal session records in screenshots.

### Mac captures

1. Menu-bar popover, idle, light appearance.
2. Menu-bar popover, active planned focus, showing timer and controls.
3. Menu-bar popover, Emergency Stop latched.
4. Assistant, empty state with composer and suggestions.
5. Assistant, response with tool progress and one inline approval state.
6. Focus, active session and Sentinel status.
7. Focus, missing permission or uncertain/attention state.
8. Memory, populated safe synthetic entries and pins.
9. Learned Skills, proposal awaiting review plus a published skill.
10. Token Caching, confirmed and unreported telemetry rows.
11. Settings, Providers and Voice & Microphone, with keys masked.
12. Workspace in dark appearance and a narrow window with collapsed navigation.

### iOS/iPad captures

1. iPhone Focus active and paused.
2. iPhone offline/reconnecting and Emergency Stop states.
3. Quick Actions and approval review.
4. Session history and detail.
5. iPad wide split view and compact-width layout.

### Acceptance checks

- `swift test`, `swift build`, and the repository's Mac release build pass.
- iOS simulator build passes; actual simulator screenshots are inspected where the environment allows. Physical-device claims are not inferred from simulator builds.
- The packaged Mac app has `LSUIElement=true`, runtime activation policy `.accessory`, no Dock tile, and no Dock menu or Dock focus progress ring. It is still reachable from the menu bar after workspace close/reopen.
- Opening the workspace, closing it, quitting, restarting, voice, phone connectivity, and focus state persistence still behave correctly.
- No DockCompanion starts and no Dock-specific focus actions remain exposed. A required app bundle icon asset may remain in the bundle for metadata/build needs, but it must not produce a running Dock tile.
- Focus UI mirrors the canonical session and revision; timer values derive from timestamps; active/paused/completed/abandoned states are distinct.
- Stop Task and Emergency Stop remain distinct. Emergency Stop stays latched until explicit Resume and remains accessible in the popover/workspace/phone.
- The microphone can be switched instantly in menu-bar popover and Settings; changing it does not alter macOS's system input.
- Memory, workflow-skill, cache telemetry, and settings screens display only actual data and honest empty/unknown/error states.
- Sanctra data, auth, sync, and user flows are unchanged.
- Dynamic Type/text scaling, VoiceOver labels/order, keyboard focus, Reduce Motion, and light/dark contrast are checked.
- `git diff --check` is clean. Stage exact files; do not commit unrelated in-progress changes.

## 12. Explicitly rejected treatments

- No Dock icon/progress ring, no notch, no floating focus pill, and no persistent overlay session indicator.
- No neon gradients, glass cards on every section, rainbow status colors, blur-heavy backdrops, animated idle mascot, or oversized character illustration that pushes work below the fold.
- No emoji for navigation/actions, no unlabeled icon buttons, no fake chart data, no unexplained percentages, and no cost-savings claims derived from unknown telemetry.
- No huge chat bubbles, dense settings wall, tiny metadata, fixed-width table that clips, or scrolling page whose primary action disappears.
- No controls that look enabled but do nothing, no hiding safety settings in an obscure submenu, and no one-tap destructive action without clear confirmation.

