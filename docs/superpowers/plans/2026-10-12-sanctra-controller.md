# Bluey Sanctra Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Integrate the owner's study account and devices with a Dock companion and explicit autonomy controls.
**Architecture:** A canonical owner-scoped session API reconciles web and Mac state; the paired phone controls the Mac. Native execution keeps a latched input gate and durable session operations.
**Tech Stack:** Swift/AppKit/SwiftUI, CryptoKit, React/TypeScript, Cloudflare Worker, Firestore.
**Spec:** /Users/ponhareeshn/Documents/Codex/2026-10-12/pro/outputs/bluey-sanctra-design.md

## Global Constraints
- Dock companion selected; no Bluey notch; Vorssaint unchanged.
- All five phone additions approved on 12 October 2026.
- Personal tokens in Keychain/client and hashed/server; never expose them to models or logs.
- Preserve existing uncommitted Sanctra changes; do not deploy unrelated work.
- One canonical session ID and idempotency receipts; latest actual start wins.

## Review Focus
- Stop racing with a held input must release input and prevent subsequent events.
- A new phone task must not clear the stop latch.
- Pause must freeze duration and resume must preserve session identity.
- Offline retries must not create duplicate sessions or override newer sessions.
- Token revocation must stop queued authenticated writes.

### Task 1: Dock and autonomy
Files: create Mac/Sources/GooglyMac/ExecutionAccess.swift and DockCompanion.swift; modify AppDelegate.swift, main.swift, Settings.swift, BlueyWorkspace.swift, BlueyApproval.swift, RealtimeHost.swift, ComputerControl.swift, BlueyCoordinator.swift, NotchController.swift, Mac/Info.plist; test Tests/GooglyMacTests/ExecutionAccessTests.swift.
Interfaces: ExecutionGate.isStopped/stop()/resume(); AutonomyMode.requiresConfirmation(name:label:arguments:); DockCompanion.start()/refresh(); local focus clock pause/resume preserves elapsed.
- [ ] Add tests for full-access confirmation bypass, ask-every confirmation, latched stop/reset and pause duration.
- [ ] Run swift test --filter ExecutionAccessTests and observe missing-feature failure.
- [ ] Implement thread-safe execution gate; apply at input posting and agent entry; release held inputs during stop. Settings choose Off/Ask every/Confirm consequences/Full access. Default preserves current confirmation policy.
- [ ] Add native Dock progress display/menu; remove notch launch/settings/menu and prevent legacy start paths. Switch application to normal Dock presence.
- [ ] Run swift test; build release with scripts/build-mac.sh; inspect UI.
- [ ] Commit only these files and record evidence.

### Task 2: Sanctra token/read API
Files: StudyTimer/worker/personal-api.ts, worker/ai-gateway.ts, worker/wrangler.jsonc; src/components/Settings.tsx or actual settings component discovered at task start; tests/personal-api.test.ts.
Interfaces: owner-only /v1/personal/{account,context,subjects,topics,goals,notes,sessions,plans,tasks,calendar,sync}; token lifecycle via verified Firebase ID token; SHA256 token hash and random 32-byte secret.
- [ ] Identify exact owner UID from existing account configuration without printing credentials; map current settings component.
- [ ] Add authentication tests for wrong account, missing token, regeneration/revocation, malformed tokens, origin-independent native reads.
- [ ] Run tests to observe missing API behavior; implement authenticated handler before existing POST/origin/AI restrictions.
- [ ] Add reveal-once token UI and account-scoped syllabus sharing; test reads on fixtures and emulator; run npm test and npm run build.
- [ ] Commit scoped changes with pre-existing edits preserved.

### Task 3: Canonical shared sessions
Files: StudyTimer/worker/personal-sessions.ts, src/utils/activeSessionService.ts, src/App.tsx, src/utils/firebase.ts, src/types.ts, firestore.rules; focused session tests.
Interfaces: POST/PATCH sessions/plans, operationId/sessionId/expectedRevision; status planned/active/completed/abandoned plus isPaused; active pointer and history projection atomic.
- [ ] Add concurrency/idempotency/stale mutation/offline replay/history preservation tests; run red.
- [ ] Implement atomic canonical record, receipts, compatibility activeSession projection and planner projection; connect owner web timer to canonical mutations.
- [ ] Run all tests, rules emulator and build; commit only integration changes.

### Task 4: Mac connector
Files: Mac/Sources/GooglyMac/SanctraClient.swift, SanctraSync.swift, BlueyWorkspace.swift, Keychain.swift, BlueyCoordinator.swift, RealtimeHost.swift; Tests/GooglyMacTests/SanctraTests.swift.
Interfaces: typed API models, Keychain token, account-bound durable outbox; poll 3 seconds active/15 idle with revision/ETag; study context and plan tools.
- [ ] Test retry/relaunch dedup, token revocation, conflict warnings, context freshness and pause duration before implementation.
- [ ] Implement connection UI, compact study context, planning tools, canonical focus adoption and offline reconciliation.
- [ ] Run swift test/build and local two-client fixtures; commit.

### Task 5: Phone transport and controller
Files: Shared/GooglyLink.swift, Mac/Sources/GooglyMac/PhoneServer.swift, iOS/Sources/MacLink.swift, BlueyAppView.swift, GooglyApp.swift, project.yml, iOS/Assets.xcassets; shared transport/controller tests.
Interfaces: authenticated pairing and encrypted sequence-numbered packets; snapshot/commandId/expectedRevision acknowledgements; control start/pause/resume/finish/stop.
- [ ] Test unauthenticated/replay/stale commands and reconnect acknowledgements before implementation.
- [ ] Implement trusted pairing, controller, responsive iPad layout and reduced-motion transition animations.
- [ ] Generate cute opaque 1024px app icon and configure asset catalog; build Mac/iPhone/iPad and inspect renders.
- [ ] Commit.

### Task 6: Approved phone additions
Files: iOS controller/quick actions/agent review/wrap-up views, widget extension and project.yml, Mac shared handlers; endpoint wrap-up storage.
- [ ] Test commands, approval scoping and note/session identity before implementation.
- [ ] Implement quick actions, haptics, agent review and Sanctra session wrap-up.
- [ ] Implement widgets/Live Activities with explicitly supported connectivity; background remote control requires push/direct-cloud transport, not a promise of continuous iOS polling.
- [ ] Build/test extensions and device interactions; commit.

### Task 7: Production validation
- [ ] Validate private backup of owner's affected records and isolate deployment changes from dirty checkout.
- [ ] Deploy scoped API/rules, then clients; preserve previous releases and disable switch.
- [ ] Owner generates token in site and pastes into Bluey (never chat); validate actual web/Mac/phone lifecycle, conflicts, offline retry, streaks and emergency stop.
- [ ] Report device/background features not physically tested honestly.
