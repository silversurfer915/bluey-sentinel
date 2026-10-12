import AppKit
import GooglyShared

/// The Sentinel: it keeps one eye on what's in front of you and, when you set a goal and drift
/// away from it, warns you and then closes the thing that took you there.
///
/// Three deliberate design choices, because a guardian you resent is a guardian you turn off:
///
/// 1. **It reads cheap facts first.** The front app, window title, exact browser URL and idle time
///    are free. A screenshot — and therefore a vision call — is only taken when those can't settle
///    the question.
/// 2. **It never acts without a visible countdown.** The warning card is the contract: you can
///    cancel by pressing Escape, clicking "stay", or just going back to work. The check loop clears
///    the pending action the moment it sees you on task again.
/// 3. **Only the model's `block` field is ever acted on**, and it is treated as untrusted input:
///    domains must match `[a-z0-9.-]`, app names must exactly equal a *currently running* app.
///    Screen text can therefore never talk the Sentinel into closing something.
@MainActor
final class Sentinel {
    private weak var overlay: CursorOverlay?
    private let hud = SentinelHUD()

    private var heartbeat: Timer?
    private var running = false
    /// Guards against two evaluations overlapping (heartbeat and app-switch can both fire).
    private var isEvaluating = false

    /// Private state for the drift judgement.
    private var driftStartedAt: Date?
    private var strikes = 0
    private var lastCheckAt: Date = .distantPast
    private var cooldownUntil: Date = .distantPast
    private var lastVerdict: SentinelVerdict?
    private var lastProbe: FocusProbe?
    private var appSwitchObserver: NSObjectProtocol?
    private var captionClearWorkItem: DispatchWorkItem?

    /// Target lock: locks onto a single window or browser tab.
    /// While the user stays here: ZERO AI queries, ZERO credit waste.
    private(set) var lockedTarget: LockedTarget?
    private var lastObservedProbe: FocusProbe?
    private var lastEvaluatedShiftApp: String?
    private var lastEvaluatedShiftDomain: String?
    private var lastEvaluatedShiftTitle: String?
    private var lastShiftEvaluationAt: Date = .distantPast

    /// Fires whenever the menu should redraw.
    var onChange: (() -> Void)?

    /// Today's tally, shown in the menu.
    private(set) var driftCountToday = 0
    private(set) var enforcedCountToday = 0

    /// Runtime study tracking for Hermes agent
    private var focusSessionStartedAt: Date?
    private var activeFocusSeconds: Double = 0
    private var lastProgressAt = Date()
    private var warningProbe: FocusProbe?
    private var generation = 0

    // MARK: - Lifecycle

    func configure(overlay: CursorOverlay) {
        self.overlay = overlay
    }

    func start(overlay: CursorOverlay? = nil) {
        if let overlay { self.overlay = overlay }
        guard !running else { return }
        generation += 1
        lastObservedProbe = nil
        lastVerdict = nil
        lastProgressAt = Date()
        running = true
        lockedTarget = Settings.shared.sentinelLockedTarget
        hud.onDismiss = { [weak self] in self?.log("warning dismissed by user") }
        heartbeat?.invalidate()
        // Probe tab/window changes even when the user stays in the same application.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollIfEnabled() }
        }

        if let old = appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(old) }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleAppSwitch() }
        }

        log("sentinel started (target: \(lockedTarget?.displayName ?? "none"))")
        focusSessionStartedAt = Date()
        activeFocusSeconds = 0
        StudyLearner.shared.startFocusSession(goal: Settings.shared.focusGoal.isEmpty ? (lockedTarget?.displayName ?? "Focus Session") : Settings.shared.focusGoal)
        onChange?()
    }

    func stop() {
        generation += 1
        resetDrift()
        warningProbe = nil
        BlueyState.shared.warning = nil
        running = false
        heartbeat?.invalidate()
        heartbeat = nil
        if let obs = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appSwitchObserver = nil
        }
        stopPointing()
        dismissWarning()
        Voice.shared.stop()
        if activeFocusSeconds >= 5.0 {
            StudyLearner.shared.recordFocusProgress(
                app: lastObservedProbe?.app,
                domain: lastObservedProbe?.domain,
                durationMinutes: activeFocusSeconds / 60.0
            )
            activeFocusSeconds = 0
        }
        focusSessionStartedAt = nil
        StudyLearner.shared.completeFocusSession()
        log("sentinel stopped")
        onChange?()
    }

    func dismissWarning() {
        hud.dismiss(); resetDrift(); stopPointing(); warningProbe = nil
        BlueyState.shared.warning = nil
        NotchController.shared.refreshPresentation()
    }

    // MARK: - Target Locking (Zero Credit Waste)

    /// Locks onto the window or browser tab currently in front of the user.
    func lockCurrentTarget() async {
        let probe = await ScreenContext.probe()
        let target = LockedTarget(
            appName: probe.app,
            bundleID: probe.bundleID,
            windowTitle: probe.windowTitle,
            domain: probe.domain,
            url: probe.url,
            lockedAt: Date()
        )
        self.lockedTarget = target
        Settings.shared.sentinelLockedTarget = target
        Settings.shared.sentinelEnabled = true
        if !running {
            start()
        }
        resetDrift()
        lastEvaluatedShiftApp = nil
        lastEvaluatedShiftDomain = nil

        let title = target.displayName
        log("locked target: \(title)")
        StudyLearner.shared.startFocusSession(goal: title)
        Voice.shared.say("Locked onto \(title). I'll stay quiet while you're here.")
        showBubble("🎯 Locked onto \(title)\nZero AI calls while you're working here.", for: 5.0)
        onChange?()
    }

    /// Clears the locked target.
    func unlockTarget() {
        log("unlocked target: \(lockedTarget?.displayName ?? "")")
        self.lockedTarget = nil
        Settings.shared.sentinelLockedTarget = nil
        resetDrift()
        stopPointing()
        dismissWarning()
        if activeFocusSeconds >= 5.0 {
            StudyLearner.shared.recordFocusProgress(
                app: lastObservedProbe?.app,
                domain: lastObservedProbe?.domain,
                durationMinutes: activeFocusSeconds / 60.0
            )
            activeFocusSeconds = 0
        }
        StudyLearner.shared.completeFocusSession()
        showBubble("Target unlocked.", for: 3.0)
        onChange?()
    }

    /// Determines if a probe matches the locked target.
    func isMatchingLockedTarget(_ probe: FocusProbe, target: LockedTarget) -> Bool {
        guard let app = target.appName, app == probe.app, target.bundleID == probe.bundleID else { return false }
        if ScreenContext.isBrowser(app) {
            guard let url = target.url, let currentURL = probe.url else { return false }
            return url == currentURL
        }
        guard let title = target.windowTitle, !title.isEmpty else { return false }
        return title == probe.windowTitle
    }

    private func handleAppSwitch() async {
        guard running, Settings.shared.sentinelEnabled, !BlueyState.shared.busy else { return }

        // When changing applications, immediately dismiss any distraction pointing and speech bubble
        if overlay?.view.caption != nil || overlay?.view.speechTarget != nil {
            stopPointing()
        }
        dismissWarning()
        cooldownUntil = Date()

        // Evaluate the window/app change immediately!
        await checkWindowOrTabChange()
    }

    var isRunning: Bool { running }

    /// For the menu's "Check Now": one full judgement, reported to the user, no enforcement.
    /// Uses visible context and vision when the configured provider supports it.
    func checkNow() async -> SentinelVerdict {
        let probe = await ScreenContext.probe()
        lastProbe = probe
        let verdict = await judge(probe)
        lastVerdict = verdict
        report(verdict, probe: probe, prefix: "Checking")
        onChange?()
        return verdict
    }

    // MARK: - Window & Browser Tab Change Detection (Zero Vision, Pure JSON Metadata)

    /// The heartbeat's entry point: only poll when the user has actually asked for continuous
    /// polling, or when a drift period is active so sustained drift in the same window can trigger!
    private func pollIfEnabled() async {
        let interval = driftStartedAt != nil || warningProbe != nil ? 2.0 : min(6.0, max(2.0, Settings.shared.checkInterval))
        guard Date().timeIntervalSince(lastCheckAt) >= interval else { return }
        await checkWindowOrTabChange()
    }

    /// Checks if the frontmost window or browser tab has changed.
    /// Every window or browser tab change triggers the AI with cheap JSON metadata.
    /// While working inside the same window/tab, ZERO AI calls are made.
    func checkWindowOrTabChange() async {
        guard running, Settings.shared.sentinelEnabled else { return }
        if BlueyState.shared.busy {
            lastProgressAt = Date()
            if warningProbe != nil { dismissWarning() }
            return
        }
        let currentGeneration = generation
        // Both the heartbeat and the app-switch observer call this. Without this guard two
        // evaluations could run at once, racing on lastObservedProbe and double-counting drift —
        // which could turn one glance at a tab into two strikes and trigger a warning early.
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        lastCheckAt = Date()
        let current = await ScreenContext.probe()
        guard generation == currentGeneration, running, Settings.shared.sentinelEnabled else { return }
        if let warningProbe, !Self.sameTarget(warningProbe, current) { dismissWarning() }

        // Away from the keyboard, or in an exempt app:
        if current.idleSeconds >= Settings.shared.idleResetSeconds || isExempt(current) {
            resetDrift()
            if overlay?.view.caption != nil || overlay?.view.speechTarget != nil {
                stopPointing()
            }
            dismissWarning()
            lastObservedProbe = current
            return
        }

        // A system dialog (permission prompt, Spotlight, notification centre) is not the user's
        // work. Return WITHOUT touching lastObservedProbe, so the real window they were in is still
        // the reference when the dialog closes — otherwise the check after the dialog would look
        // like a fresh window change and be judged all over again.
        if Self.isSystemOverlay(current) {
            return
        }

        let elapsed = Self.focusElapsed(previous: lastProgressAt, now: Date(), limit: 8)
        lastProgressAt = Date()
        if driftStartedAt == nil, lastVerdict?.isReliableOnTask == true {
            activeFocusSeconds += elapsed
            if activeFocusSeconds >= 60 {
                StudyLearner.shared.recordFocusProgress(app: current.app, domain: current.domain, durationMinutes: activeFocusSeconds / 60)
                activeFocusSeconds = 0
            }
        }

        // Determine if window or browser tab actually changed
        let hasChanged = lastObservedProbe == nil ||
            current.app != lastObservedProbe?.app ||
            current.windowTitle != lastObservedProbe?.windowTitle ||
            current.url != lastObservedProbe?.url ||
            current.windowID != lastObservedProbe?.windowID

        guard hasChanged else {
            if let driftStart = driftStartedAt, Date().timeIntervalSince(driftStart) >= Settings.shared.sustainSeconds {
                // A second contextual judgment must confirm the original drift before warning.
                let confirmed = await judge(current)
                guard generation == currentGeneration, running, Settings.shared.sentinelEnabled else { return }
                lastVerdict = confirmed
                let latest = await ScreenContext.probe()
                guard Self.sameTarget(current, latest) else { lastObservedProbe = nil; resetDrift(); return }
                if !confirmed.onTask, confirmed.confidence >= Settings.shared.acceptConfidence {
                    strikes += 1
                    if strikes >= Settings.shared.strikes { await warnAndEnforce(confirmed, probe: current) }
                } else { resetDrift() }
            } else if driftStartedAt == nil, warningProbe == nil, Date().timeIntervalSince(lastShiftEvaluationAt) >= 60 {
                await evaluateWindowOrTabChange(previous: current, current: current, target: lockedTarget)
            }
            return
        }

        let previous = lastObservedProbe
        lastObservedProbe = current
        lastProbe = current

        // Case A: Target is locked
        if let target = lockedTarget {
            if isMatchingLockedTarget(current, target: target) {
                // Working inside the locked target: ZERO AI calls, ZERO credits!
                resetDrift()
                if overlay?.view.caption != nil || overlay?.view.speechTarget != nil {
                    stopPointing()
                }
                dismissWarning()
                return
            }

            // User shifted away from locked target to another window/tab:
            await evaluateWindowOrTabChange(previous: previous, current: current, target: target)
            return
        }

        // Case B: General focus goal is active
        if !Settings.shared.focusGoal.isEmpty {
            await evaluateWindowOrTabChange(previous: previous, current: current, target: nil)
        }
    }

    /// Evaluates a window or browser tab change using structured JSON metadata (NO VISION / NO SCREENSHOTS).
    private func evaluateWindowOrTabChange(previous: FocusProbe?, current: FocusProbe, target: LockedTarget?) async {
        if isExempt(current) {
            resetDrift()
            if overlay?.view.caption != nil || overlay?.view.speechTarget != nil {
                stopPointing()
            }
            dismissWarning()
            return
        }

        let app = current.app ?? ""
        let domain = current.domain ?? ""
        let title = current.windowTitle ?? ""
        let now = Date()

        // Debounce: don't re-evaluate identical window/tab within 15s if previously evaluated
        if app == lastEvaluatedShiftApp && domain == lastEvaluatedShiftDomain && title == lastEvaluatedShiftTitle && now.timeIntervalSince(lastShiftEvaluationAt) < 15 {
            return
        }

        lastEvaluatedShiftApp = app
        lastEvaluatedShiftDomain = domain
        lastEvaluatedShiftTitle = title
        lastShiftEvaluationAt = now

        let eventDesc = target != nil ? "shift from locked target [\(target!.displayName)]" : "window/tab change"
        log("\(eventDesc) to [\(current.summary.replacingOccurrences(of: "\n", with: " | "))] — evaluating via JSON metadata (no vision)")

        let goal = Settings.shared.focusGoal.isEmpty ?
            (target != nil ? "Focus on \(target!.displayName)" : "") : Settings.shared.focusGoal

        // Tier 1 Fast Match: Subject / Topic continuity pre-filter (0ms latency, zero API calls).
        // If the destination window/tab is directly studying or practicing questions on the same subject
        // (e.g. Wave Optics PDF -> Wave Optics practice questions in browser), approve immediately!
        if !Self.isKnownDistraction(current), Self.isTopicRelated(goal: goal, target: target, current: current) {
            lastVerdict = SentinelVerdict(onTask: true, confidence: 0.95, reason: "Related to your focus goal", nudge: "", block: nil, point: nil)
            log("Instant topic continuity approved: [\(current.summary.replacingOccurrences(of: "\n", with: " | "))] matches subject of [\(goal)] (0ms)")
            resetDrift()
            if overlay?.view.caption != nil || overlay?.view.speechTarget != nil {
                stopPointing()
            }
            dismissWarning()
            return
        }

        // Site reputation is a hint; lectures and research require contextual judgment.
        let currentGeneration = generation
        let verdict = await Brain.shared.judgeWindowOrTabChange(
            goal: goal,
            previous: previous,
            current: current,
            lockedTarget: target,
            useThinking: Settings.shared.deepseekThinking
        )
        guard generation == currentGeneration, running, Settings.shared.sentinelEnabled else { return }
        let latest = await ScreenContext.probe()
        guard Self.sameTarget(current, latest) else { lastObservedProbe = nil; resetDrift(); return }
        lastVerdict = verdict
        guard verdict.confidence >= Settings.shared.acceptConfidence else {
            resetDrift()
            BlueyState.shared.focusStatus = "Focus check uncertain or unavailable"
            return
        }

        if verdict.onTask {
            log("AI approved window/tab: \(verdict.reason)")
            resetDrift()
            if overlay?.view.caption != nil || overlay?.view.speechTarget != nil {
                stopPointing()
            }
            dismissWarning()
            return
        }

        // Judged as drift:
        log("AI judged as drift: \(verdict.reason) [confidence: \(verdict.confidence)]")
        guard verdict.confidence >= Settings.shared.acceptConfidence else { return }
        await confirmAndWarn(verdict, probe: current)
    }

    /// Drift must survive for a moment before it becomes a warning.
    ///
    /// A single sampled instant is not evidence: one glance at a notification, one click through a
    /// search result. The original design required the drift to persist for `sustainSeconds` across
    /// at least `strikes` samples — that protection had been dropped, leaving any single verdict
    /// (including a model's one-off wrong guess) able to fire a warning immediately. It is back.
    private func confirmAndWarn(_ verdict: SentinelVerdict, probe: FocusProbe) async {
        let now = Date()
        if driftStartedAt == nil {
            driftStartedAt = now
            strikes = 0
            log("drift period started: \(verdict.reason)")
        }
        strikes += 1

        let sustained = now.timeIntervalSince(driftStartedAt ?? now) >= Settings.shared.sustainSeconds
        guard sustained, strikes >= Settings.shared.strikes else {
            log("drift not yet sustained (\(strikes)/\(Settings.shared.strikes) strikes, "
                + "\(Int(now.timeIntervalSince(driftStartedAt ?? now)))s/\(Int(Settings.shared.sustainSeconds))s)")
            return
        }
        await warnAndEnforce(verdict, probe: probe)
    }

    private func resetDrift() {
        driftStartedAt = nil
        strikes = 0
    }

    // MARK: - Deterministic districts
    //
    // A 1.2B local model cannot be trusted with the obvious cases: measured against this build it
    // called YouTube, Reddit and Steam all *on-task*. Since the whole point of the Sentinel is to
    // catch exactly those, the clear-cut decisions are made here in plain code — instantly, free,
    // and identically every time — and the model is left to judge only the genuinely ambiguous
    // middle, where its opinion is worth something.
    //
    // Anything whose topic matches the goal has already returned before these run, so a lecture on
    // YouTube for the subject being studied is approved above and never reaches this list.

    /// Sites that are, on their own, a distraction unless the subject matches the goal.
    static let distractionDomains: Set<String> = [
        "youtube.com", "youtu.be", "m.youtube.com",
        "reddit.com", "old.reddit.com", "instagram.com", "tiktok.com",
        "facebook.com", "x.com", "twitter.com", "tumblr.com", "pinterest.com",
        "netflix.com", "twitch.tv", "disneyplus.com", "primevideo.com", "hulu.com",
        "store.steampowered.com", "steampowered.com", "epicgames.com", "roblox.com",
        "9gag.com", "imgur.com", "buzzfeed.com", "dailymotion.com", "vimeo.com"
    ]

    /// Apps that are, on their own, a distraction.
    static let distractionApps: Set<String> = [
        "steam", "epic games launcher", "roblox", "minecraft", "discord",
        "netflix", "prime video", "tv", "spotify", "music"
    ]

    /// True when the front window is a site or app that is a distraction in its own right.
    static func isKnownDistraction(_ probe: FocusProbe) -> Bool {
        if let domain = probe.domain?.lowercased() {
            // Match the domain itself and any subdomain of it, so "www.youtube.com" and
            // "music.youtube.com" both count.
            if distractionDomains.contains(domain) { return true }
            if distractionDomains.contains(where: { domain.hasSuffix("." + $0) }) { return true }
        }
        if let app = probe.app?.lowercased(), distractionApps.contains(app) { return true }
        return false
    }

    /// True when the front window is a system overlay rather than the user's own work.
    ///
    /// macOS permission prompts (`universalAccessAuthWarn`), Spotlight, and the notification centre
    /// all become the frontmost application while they are up. Judging those is wrong twice over: it
    /// spends a model call on a dialog, and it can produce a warning about something the user did
    /// not open. They are ignored, exactly like an exempt app, so the last real window keeps its
    /// state until the user is back in it.
    static let systemOverlayApps: Set<String> = [
        "universalaccessauthwarn",   // TCC permission prompts (Automation, Screen Recording, …)
        "spotlight", "coreservicesuiagent", "usernotificationcenter",
        "notificationcenter", "controlcenter", "screenshot", "screencaptureui",
        "securityagent", "loginwindow", "systemuiserver"
    ]

    static func isSystemOverlay(_ probe: FocusProbe) -> Bool {
        guard let app = probe.app?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return systemOverlayApps.contains(app)
    }

    func exposedIsSystemOverlay(_ probe: FocusProbe) -> Bool { Self.isSystemOverlay(probe) }

    func exposedIsKnownDistraction(_ probe: FocusProbe) -> Bool { Self.isKnownDistraction(probe) }

    /// Invariants the self-test asserts. These are constants rather than settings on purpose: they
    /// describe a property of the design ("one sample is never enough", "a warning can be cancelled")
    /// and must not be tunable into being untrue by a live settings tweak.
    static let minimumStrikesBeforeWarning = 2
    static let requiresSustainedDrift = true
    static let warningIsCancellable = true

    private func isExempt(_ probe: FocusProbe) -> Bool {
        if probe.bundleID == Bundle.main.bundleIdentifier { return true }
        let exempt = Settings.shared.exemptApps
        guard !exempt.isEmpty else { return false }
        if let app = probe.app, exempt.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) { return true }
        if let domain = probe.domain, exempt.contains(where: { $0.caseInsensitiveCompare(domain) == .orderedSame }) { return true }
        return false
    }

    // MARK: - Judging (Pure JSON Metadata — No Vision / No Screenshots)

    private func judge(_ probe: FocusProbe) async -> SentinelVerdict {
        let goal = Settings.shared.focusGoal
        return await Brain.shared.judgeWindowOrTabChange(
            goal: goal,
            previous: lastObservedProbe,
            current: probe,
            lockedTarget: lockedTarget,
            useThinking: Settings.shared.deepseekThinking
        )
    }

    // MARK: - Warn, then act

    private func warnAndEnforce(_ verdict: SentinelVerdict, probe: FocusProbe) async {
        guard Date() >= cooldownUntil else { return }
        resetDrift()
        warningProbe = probe
        BlueyState.shared.warning = verdict.reason
        NotchController.shared.refreshPresentation()
        let plan = planEnforcement(verdict, probe: probe)

        // Warn first, always, and visibly. The countdown is the user's chance to disagree.
        driftCountToday += 1
        let culprit = verdict.block ?? probe.domain ?? probe.app ?? "Distraction"
        let sustainedFocusMins = focusSessionStartedAt.map { (driftStartedAt ?? Date()).timeIntervalSince($0) / 60.0 } ?? 0.0
        StudyLearner.shared.recordDrift(culprit: culprit, sessionDurationMins: sustainedFocusMins)
        focusSessionStartedAt = Date()

        Voice.shared.chirp()
        Voice.shared.say(verdict.nudge.isEmpty ? "You've drifted off. Want to come back?" : verdict.nudge)

        // Fly to the distraction and point at it, so the warning is about a thing on screen rather
        // than an abstract scolding. The bubble then sits right above whatever he's accusing.
        flyToDistraction(verdict, probe: probe)

        let seconds = Settings.shared.warnSeconds
        log("warning: \(verdict.reason) → \(plan.description)")

        // If the user goes back to work during the countdown, this cancels the action.
        cooldownUntil = Date().addingTimeInterval(seconds + Settings.shared.cooldownSeconds)

        hud.warn(
            title: "Bluey thinks you've drifted",
            detail: verdict.reason,
            action: plan.description,
            seconds: seconds,
            onAccept: { [weak self] in
                Task { @MainActor in await self?.apply(plan, verdict: verdict) }
            },
            onDismiss: { [weak self] in
                self?.dismissWarning()
                self?.log("user cancelled the warning")
            }
        )
    }

    /// Send the character to whatever pulled the user away and have him point at it.
    ///
    /// The position comes from the model as a 0–1000 grid, which is only ever treated as a hint:
    /// it is clamped to the screen, and if there is no usable position he points at the front
    /// window instead. The bubble is anchored to the same rectangle either way, so the words land
    /// next to the thing being talked about.
    private func flyToDistraction(_ verdict: SentinelVerdict, probe: FocusProbe) {
        guard Settings.shared.sentinelPoints, let overlay else { return }
        guard let screen = NSScreen.screens.first else { return }
        // The overlay is laid out in its own top-left origin space, which is what we want here.
        let size = screen.frame.size

        let rect = targetRect(for: verdict, probe: probe, in: size)
        overlay.view.speechTarget = rect
        // Land just below the target so the big cursor points up at it rather than covering it.
        overlay.mode = .pinned(CGPoint(x: rect.midX, y: min(rect.maxY + 6, size.height - 10)))
        showBubble("This is what pulled you away.", for: Settings.shared.warnSeconds)
    }

    /// The rectangle Bluey should point at: what the model circled, else the front window.
    private func targetRect(for verdict: SentinelVerdict, probe: FocusProbe, in size: CGSize) -> CGRect {
        if verdict.point != nil {
            let centre = verdict.overlayPoint(in: size)
            // A small box around the model's guess, so the bubble has something to sit above.
            return CGRect(x: centre.x - 70, y: centre.y - 20, width: 140, height: 40)
        }
        // Fall back to the front window, which is the thing he is actually looking at.
        if let frame = ScreenContext.frontWindowFrame(), frame.width > 20, frame.height > 20 {
            return frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.08)
        }
        // Last resort: mid-screen, so he still says something rather than nothing.
        return CGRect(x: size.width * 0.35, y: size.height * 0.35,
                      width: size.width * 0.3, height: size.height * 0.2)
    }

    /// Put him back where he belongs once the moment has passed.
    private func stopPointing() {
        captionClearWorkItem?.cancel()
        captionClearWorkItem = nil
        overlay?.view.caption = nil
        overlay?.view.speechTarget = nil
        overlay?.goHome()
    }

    /// A plan computed from one verdict, exposed so the self-test can drive it without a live model.
    struct Plan: Equatable {
        enum Kind: Equatable { case closeTab(domain: String?), hideApp(String), none }
        var kind: Kind
        var description: String
        var observed: FocusProbe? = nil
    }

    /// There is no API surface here beyond what makes the Sentinel safe. These are the guard rails,
    /// and they are deliberately reachable from a test so their behaviour can be proven rather than
    /// assumed. `GOOGLY_DEMO_SENTINEL=1` runs `SentinelGuardTests` at launch and prints the results.
    func exposedPlan(for verdict: SentinelVerdict, probe: FocusProbe) -> Plan {
        planEnforcement(verdict, probe: probe)
    }

    func exposedRunningAppMatch(_ name: String) -> String? { matchedRunningApp(name) }
    func exposedSanitizeDomain(_ text: String) -> String? { sanitizeDomain(text) }

    /// What enforcement would actually do. Computed before the warning so we can name it on the card.
    private func planEnforcement(_ verdict: SentinelVerdict, probe: FocusProbe) -> Plan {
        guard Settings.shared.sentinelAct else {
            return Plan(kind: .none, description: "Warn only — nothing will be closed")
        }

        let block = (verdict.block ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if let app = matchedRunningApp(block), app == probe.app, !ScreenContext.isBrowser(app), app != "Finder" {
            return Plan(kind: .hideApp(app), description: "Hide \(app) in", observed: probe)
        }
        if let browser = probe.app, ScreenContext.isBrowser(browser), probe.url != nil {
            if !block.isEmpty, sanitizeDomain(block) != probe.domain { return Plan(kind: .none, description: "Warn only — target does not match") }
            return Plan(kind: .closeTab(domain: probe.domain), description: "Close this tab in \(browser) in", observed: probe)
        }

        // 4. Nothing safe to close automatically. Say so rather than guessing at the user's work.
        return Plan(kind: .none, description: "Warn only — nothing safe to close")
    }

    nonisolated static func sameTarget(_ first: FocusProbe, _ second: FocusProbe) -> Bool {
        first.app == second.app && first.bundleID == second.bundleID && first.windowTitle == second.windowTitle && first.url == second.url && first.windowID == second.windowID
    }
    nonisolated static func focusElapsed(previous: Date, now: Date, limit: TimeInterval) -> TimeInterval {
        max(0, min(limit, now.timeIntervalSince(previous)))
    }
    private func apply(_ plan: Plan, verdict: SentinelVerdict) async {
        defer { dismissWarning() }
        guard running, !ExecutionGate.shared.isStopped, Settings.shared.autonomyMode != .off, Settings.shared.sentinelEnabled, Settings.shared.sentinelAct,
              let original = plan.observed else { return }
        let current = await ScreenContext.probe()
        guard running, !ExecutionGate.shared.isStopped, Settings.shared.autonomyMode != .off, Settings.shared.sentinelEnabled, Settings.shared.sentinelAct,
              current.idleSeconds < Settings.shared.idleResetSeconds,
              Self.sameTarget(original, current), !BlueyState.shared.busy else {
            log("intervention cancelled: observed target changed")
            return
        }
        switch plan.kind {
        case .none: break
        case .hideApp(let app):
            NSWorkspace.shared.runningApplications.first { $0.localizedName == app && $0.activationPolicy == .regular }?.hide()
            log("hid distracting app (reversible)")
        case .closeTab:
            if let browser = original.app, let url = original.url {
                let result = ScreenContext.closeObservedTab(in: browser, expectedURL: url)
                log(result)
                if result.hasPrefix("closed") { enforcedCountToday += 1 }
            }
        }
        onChange?()
    }

    private func matchedRunningApp(_ name: String) -> String? {
        guard name.count >= 2, name.count <= 40 else { return nil }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Domains go into AppleScript, so they must be a genuine hostname and nothing else.
    /// Rejecting on shape (not just on bad characters) is what stops "..", "a..b" or "evil..com"
    /// from being accepted as if they were real sites.
    private func sanitizeDomain(_ text: String) -> String? {
        var value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        value = value.split(separator: "/").first.map(String.init) ?? value
        for prefix in ["www."] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }

        guard !value.isEmpty, value.count <= 80 else { return nil }

        // Every label must be alphanumerics with inner hyphens; the last must be a real TLD.
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.allSatisfy({ $0.isASCII && (allowed.contains(Unicode.Scalar(String($0))!) )}),
                  label.first != "-", label.last != "-" else { return nil }
        }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return value
    }

    // MARK: - Semantic Topic Continuity (0ms Pre-Filter)

    /// Fast local topic/keyword matcher (0ms latency, zero API calls).
    /// Detects if the destination window or web page is directly studying or practicing
    /// the same subject matter as the locked target or session goal.
    static func isTopicRelated(goal: String, target: LockedTarget?, current: FocusProbe) -> Bool {
        var referenceTexts: [String] = []
        if !goal.isEmpty { referenceTexts.append(goal) }
        if let target {
            if let title = target.windowTitle, !title.isEmpty { referenceTexts.append(title) }
            if let url = target.url, !url.isEmpty { referenceTexts.append(url) }
        }

        var destinationTexts: [String] = []
        if let title = current.windowTitle, !title.isEmpty { destinationTexts.append(title) }
        if let url = current.url, !url.isEmpty { destinationTexts.append(url) }
        if let domain = current.domain, !domain.isEmpty { destinationTexts.append(domain) }

        guard !referenceTexts.isEmpty && !destinationTexts.isEmpty else { return false }

        let refKeywords = extractSignificantKeywords(from: referenceTexts.joined(separator: " "))
        let destKeywords = extractSignificantKeywords(from: destinationTexts.joined(separator: " "))

        guard !refKeywords.isEmpty && !destKeywords.isEmpty else { return false }

        let intersection = refKeywords.intersection(destKeywords)
        guard !intersection.isEmpty else { return false }

        // Strong subject keyword matches (at least one term >= 4 chars, or 2+ matching terms)
        let significantMatches = intersection.filter { $0.count >= 4 }
        return !significantMatches.isEmpty || intersection.count >= 2
    }

    /// Extract meaningful keywords by filtering out common English stopwords, file extensions, and browser junk.
    static func extractSignificantKeywords(from text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "from", "that", "this", "what", "which",
            "are", "was", "were", "been", "have", "has", "had", "does", "done",
            "study", "studying", "learn", "learning", "read", "reading", "write", "writing",
            "finish", "complete", "work", "working", "problem", "problems", "question", "questions",
            "google", "chrome", "safari", "firefox", "preview", "window", "tab", "page",
            "https", "http", "www", "html", "htm", "com", "org", "net", "edu", "pdf",
            "project", "notes", "note", "file", "files", "document", "documents", "task", "tasks",
            "session", "focus", "online", "search", "free", "best", "view", "open", "new",
            "home", "site", "browser", "apple", "mac", "active", "target"
        ]

        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }

        return Set(cleaned)
    }

    // MARK: - Talking to the user

    private func showBubble(_ text: String?, for seconds: Double = 6.0) {
        captionClearWorkItem?.cancel()
        overlay?.view.caption = text
        guard text != nil, seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.overlay?.view.caption = nil
        }
        captionClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func report(_ verdict: SentinelVerdict, probe: FocusProbe, prefix: String) {
        let status = verdict.onTask ? "on task" : "drifted"
        let percent = Int((verdict.confidence * 100).rounded())
        let line = "\(prefix): \(status) (\(percent)%)\n\(verdict.reason)"
        Voice.shared.say(verdict.onTask ? "Looks like you're on task." : verdict.nudge)
        showBubble(line, for: 5.0)
    }

    // MARK: - Log

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sentinel.log")
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }

    /// One line for the menu bar, so the state is legible at a glance.
    var menuSummary: String {
        guard Settings.shared.sentinelEnabled else { return "Focus Sentinel: off" }
        if let target = lockedTarget {
            return "Focus Sentinel: 🎯 Locked on \(target.displayName) (0 AI calls)"
        }
        if Settings.shared.focusGoal.isEmpty { return "Focus Sentinel: lock a target or set a goal to start" }
        guard let verdict = lastVerdict else { return "Focus Sentinel: watching" }
        let state = verdict.onTask ? "on task" : "drifted"
        return "Focus Sentinel: \(state) — \(driftCountToday) drift, \(enforcedCountToday) closed today"
    }
}