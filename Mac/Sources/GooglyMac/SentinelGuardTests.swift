import AppKit
import Foundation

/// Proves the two things that would be worst to get wrong:
///
/// 1. **A hostile screen cannot cause harm.** Anything the model returns in `block` is untrusted
///    input, and these cases check that injection attempts and nonsense resolve to "do nothing"
///    rather than to a quit or an AppleScript.
/// 2. **The brain's reply always parses into a usable verdict**, including when the model wraps its
///    JSON in prose or a code fence.
///
/// Run with `GOOGLY_DEMO_SENTINEL=1` — it prints results and quits, so the normal app never runs it.
@MainActor
enum SentinelGuardTests {
    private static var failures = 0
    private static var checks = 0

    static func run() {
        // The suite shares UserDefaults with the real app, so it must not depend on whatever the
        // user happens to have toggled in the menu. Enforcement is forced on for the planning
        // checks and the user's original choice is put back before quitting.
        let savedAct = Settings.shared.sentinelAct
        Settings.shared.sentinelAct = true

        let sentinel = Sentinel()
        let chrome = FocusProbe(app: "Google Chrome", bundleID: "com.google.Chrome",
                                windowTitle: "YouTube", url: "https://www.youtube.com/watch?v=abc",
                                idleSeconds: 1, at: Date())
        let xcode = FocusProbe(app: "Xcode", bundleID: "com.apple.dt.Xcode",
                               windowTitle: "Sentinel.swift", url: nil,
                               idleSeconds: 1, at: Date())
        let notes = FocusProbe(app: "Notes", bundleID: "com.apple.Notes",
                               windowTitle: "Untitled", url: nil,
                               idleSeconds: 1, at: Date())

        func verdict(_ block: String?) -> SentinelVerdict {
            SentinelVerdict(onTask: false, confidence: 0.95, reason: "distracted", nudge: "back to it",
                            block: block, point: nil)
        }

        // ── Domain sanitising ────────────────────────────────────────────────────────────────
        section("domain sanitising (this value reaches an AppleScript string)")
        expect(sentinel.exposedSanitizeDomain("youtube.com") == "youtube.com", "plain domain passes")
        expect(sentinel.exposedSanitizeDomain("https://www.YouTube.com/watch?v=x") == "youtube.com", "url reduced to host")
        expect(sentinel.exposedSanitizeDomain("  reddit.com  ") == "reddit.com", "whitespace trimmed")

        // Hostile or malformed input must be rejected outright.
        expect(sentinel.exposedSanitizeDomain("youtube.com\"\n tell application \"Finder\" to quit") == nil,
               "quote + newline injection rejected")
        expect(sentinel.exposedSanitizeDomain("evil\"; do shell script \"rm -rf ~\"") == nil,
               "shell-script injection rejected")
        expect(sentinel.exposedSanitizeDomain("notadomain") == nil, "dotless token rejected")
        expect(sentinel.exposedSanitizeDomain("") == nil, "empty rejected")
        expect(sentinel.exposedSanitizeDomain(String(repeating: "a", count: 200) + ".com") == nil, "overlong rejected")
        expect(sentinel.exposedSanitizeDomain("../../etc/passwd") == nil, "path traversal rejected")
        expect(sentinel.exposedSanitizeDomain("a b.com") == nil, "embedded space rejected")
        expect(sentinel.exposedSanitizeDomain("..") == nil, "bare dots rejected")
        expect(sentinel.exposedSanitizeDomain("evil..com") == nil, "empty label rejected")
        expect(sentinel.exposedSanitizeDomain("-evil.com") == nil, "leading hyphen rejected")
        expect(sentinel.exposedSanitizeDomain("evil.c") == nil, "single-letter TLD rejected")
        expect(sentinel.exposedSanitizeDomain("good-name.co.uk") == "good-name.co.uk", "hyphens and multi-label TLD pass")
        expect(sentinel.exposedSanitizeDomain("https://www.reddit.com/r/all") == "reddit.com", "www and path stripped")

        // ── App-name matching ────────────────────────────────────────────────────────────────
        section("app matching (only a running app can be quit)")
        expect(sentinel.exposedRunningAppMatch("Finder") == "Finder", "running app matches exactly")
        expect(sentinel.exposedRunningAppMatch("DEFINITELY-NOT-RUNNING-APP") == nil, "unrunning app rejected")
        expect(sentinel.exposedRunningAppMatch("Finder.app") == nil, "bundle suffix does not match")
        expect(sentinel.exposedRunningAppMatch("F") == nil, "single character rejected")
        expect(sentinel.exposedRunningAppMatch(String(repeating: "x", count: 80)) == nil, "overlong name rejected")

        // ── Planning ─────────────────────────────────────────────────────────────────────────
        section("enforcement planning")
        expect(sentinel.exposedPlan(for: verdict("youtube.com"), probe: chrome).kind == .closeTab(domain: "youtube.com"),
               "named site in a browser → close that tab")
        expect(sentinel.exposedPlan(for: verdict(nil), probe: chrome).kind == .closeTab(domain: nil),
               "browser with no culprit → close front tab")
        expect(sentinel.exposedPlan(for: verdict(nil), probe: xcode).kind == .none,
               "non-browser with no culprit → do nothing")
        expect(sentinel.exposedPlan(for: verdict("youtube.com"), probe: xcode).kind == .none,
               "named site while not in a browser → do nothing")
        expect(sentinel.exposedPlan(for: verdict("Finder"), probe: xcode).kind == .quitApp("Finder"),
               "named running app → quit it")
        expect(sentinel.exposedPlan(for: verdict("no-such-app-xyz"), probe: xcode).kind == .none,
               "named non-running app → do nothing")
        expect(sentinel.exposedPlan(for: verdict("evil\"; do shell script \"rm -rf ~\""), probe: notes).kind == .none,
               "injection attempt → do nothing")

        // The "warn only" setting must defeat enforcement entirely. It is already off here, because
        // the suite forces it on at the start; restoring it happens once, in the summary block.
        Settings.shared.sentinelAct = false
        expect(sentinel.exposedPlan(for: verdict("Finder"), probe: xcode).kind == .none,
               "warn-only mode never plans an action")
        // Back to forced-on for any later sections that plan actions.
        Settings.shared.sentinelAct = true

        // ── Verdict parsing ──────────────────────────────────────────────────────────────────
        section("verdict parsing (the model does not always return clean JSON)")
        let clean = "{\"on_task\": false, \"confidence\": 0.9, \"reason\": \"watching a video\", \"nudge\": \"back to it\", \"block\": \"youtube.com\"}"
        if let v = try? Brain.parse(clean) {
            expect(!v.onTask && v.block == "youtube.com" && v.confidence == 0.9, "clean json parses")
        } else {
            fail("clean json should parse")
        }

        let fenced = "Sure! Here you go:\n```json\n{\"on_task\": true, \"confidence\": 0.8, \"reason\": \"reading notes\", \"nudge\": \"\", \"block\": null}\n```"
        if let v = try? Brain.parse(fenced) {
            expect(v.onTask && v.confidence == 0.8 && v.block == nil, "fenced json parses")
        } else {
            fail("fenced json should parse")
        }

        expect((try? Brain.parse("not json at all")) == nil, "garbage rejected rather than guessed")
        expect((try? Brain.parse("{\"on_task\": \"yes\"}")) == nil, "wrong value type rejected")

        // A wrong-typed `point` must not poison the whole verdict. It used to throw, and the catch
        // turned a distraction into .uncertain — which is on_task: true, so real drift was silently
        // recorded as work. Observed live with llama3.2:1b, which returns a sentence here.
        let badPoint = "{\"on_task\": false, \"confidence\": 0.8, \"reason\": \"cats\", \"nudge\": \"back\", \"block\": null, \"point\": \"Redirect to the study page\"}"
        if let v = try? Brain.parse(badPoint) {
            expect(!v.onTask, "a string point no longer hides a real drift verdict")
            expect(v.point == nil, "an unreadable point is ignored, not fatal")
        } else {
            fail("a wrong-typed point must not fail the whole verdict")
        }
        // Small models also quote numbers, and use words for booleans.
        let quoted = "{\"on_task\": \"false\", \"confidence\": \"0.9\", \"reason\": \"r\", \"nudge\": \"n\", \"block\": \"reddit.com\"}"
        if let v = try? Brain.parse(quoted) {
            expect(!v.onTask && v.confidence == 0.9 && v.block == "reddit.com", "quoted values are read")
        } else {
            fail("quoted values should parse")
        }
        // `block: false` is a common small-model output and must never become a name we act on.
        let falseBlock = "{\"on_task\": false, \"confidence\": 0.9, \"reason\": \"r\", \"nudge\": \"n\", \"block\": false}"
        if let v = try? Brain.parse(falseBlock) {
            expect(v.block == nil, "block:false means nothing to block")
            expect(sentinel.exposedPlan(for: v, probe: chrome).kind == .closeTab(domain: nil),
                   "and falls back to the front tab rather than a bogus name")
        } else {
            fail("block:false should parse")
        }
        // Out-of-range confidence is clamped rather than trusted.
        let wild = "{\"on_task\": false, \"confidence\": 42, \"reason\": \"r\", \"nudge\": \"n\", \"block\": null}"
        if let v = try? Brain.parse(wild) {
            expect(v.confidence == 1, "confidence is clamped to 1")
        } else {
            fail("wild confidence should still parse")
        }

        // ── Known distractions (deterministic tier) ──────────────────────────────────────────
        // These are the exact cases the local model got wrong in live testing: llama3.2:1b judged
        // YouTube, Reddit and Steam all on-task, so the obvious calls are made in plain code.
        section("known distractions (settled without the model)")
        func probe(_ domain: String?, app: String = "Google Chrome") -> FocusProbe {
            FocusProbe(app: app, bundleID: nil, windowTitle: "x",
                       url: domain.map { "https://\($0)/" }, idleSeconds: 1, at: Date())
        }
        expect(sentinel.exposedIsKnownDistraction(probe("youtube.com")), "youtube.com is a distraction")
        expect(sentinel.exposedIsKnownDistraction(probe("www.youtube.com")), "www.youtube.com too")
        expect(sentinel.exposedIsKnownDistraction(probe("music.youtube.com")), "subdomains count")
        expect(sentinel.exposedIsKnownDistraction(probe("reddit.com")), "reddit.com is a distraction")
        expect(sentinel.exposedIsKnownDistraction(probe("store.steampowered.com")), "steam store too")
        expect(sentinel.exposedIsKnownDistraction(probe(nil, app: "Steam")), "the Steam app counts")
        expect(!sentinel.exposedIsKnownDistraction(probe("physicswallah.com")), "a study site is not")
        expect(!sentinel.exposedIsKnownDistraction(probe("arxiv.org")), "arxiv is not")
        expect(!sentinel.exposedIsKnownDistraction(probe("ncert.nic.in")), "an NCERT site is not")
        expect(!sentinel.exposedIsKnownDistraction(probe(nil, app: "Preview")), "Preview is not")
        expect(!sentinel.exposedIsKnownDistraction(probe("notyoutube.com")), "notyoutube.com is not youtube")

        // ── Sustained-drift requirement ──────────────────────────────────────────────────────
        // A single sample must never be enough. Without this, one wrong model guess — or one glance
        // at a notification — fired a warning with a countdown to closing something.
        //
        // These assert the *defaults the code ships with*, not the machine's live values: a live
        // tuning session (shortening sustainSeconds to test quickly) must not turn the suite red.
        section("drift must be sustained before it becomes a warning")
        expect(Settings.defaultSustainSeconds >= 30,
               "shipped sustain interval is a real duration (\(Int(Settings.defaultSustainSeconds))s)")
        expect(Sentinel.requiresSustainedDrift,
               "the code path itself enforces a sustained-drift gate")
        expect(Sentinel.minimumStrikesBeforeWarning >= 2,
               "and needs more than one sample (\(Sentinel.minimumStrikesBeforeWarning))")
        // A drift warning must also be cancellable: the countdown is the user's chance to disagree.
        expect(Sentinel.warningIsCancellable, "a warning can be dismissed before it acts")
        // The judge is Token Harbor, not a local model: a malformed reply must not silently become
        // "on task", which is how the whole feature previously failed without anyone noticing.
        expect((try? Brain.parse("{\"on_task\": false, \"point\": \"nonsense\"}"))?.onTask == false,
               "a broken point cannot flip a drift verdict into on-task")

        // ── System overlays ──────────────────────────────────────────────────────────────────
        // macOS permission prompts and Spotlight become the frontmost app while they are up. Judging
        // them spends a call on a dialog and can warn about a window the user never opened.
        section("system dialogs are not the user's work")
        func overlay(_ app: String) -> FocusProbe {
            FocusProbe(app: app, bundleID: nil, windowTitle: "Device Control and Data Access",
                       url: nil, idleSeconds: 0, at: Date())
        }
        expect(sentinel.exposedIsSystemOverlay(overlay("universalAccessAuthWarn")),
               "a TCC permission prompt is recognised")
        expect(sentinel.exposedIsSystemOverlay(overlay("Spotlight")), "Spotlight is recognised")
        expect(sentinel.exposedIsSystemOverlay(overlay("Notification Center")), "Notification Centre is recognised")
        expect(!sentinel.exposedIsSystemOverlay(overlay("Google Chrome")), "Chrome is not an overlay")
        expect(!sentinel.exposedIsSystemOverlay(overlay("Preview")), "Preview is not an overlay")

        // ── Pointing ─────────────────────────────────────────────────────────────────────────
        section("pointing (the cursor must never end up somewhere absurd)")
        let screen = CGSize(width: 1440, height: 900)
        expect(SentinelVerdict(onTask: false, confidence: 1, reason: "", nudge: "", block: nil,
                               point: GridPoint(x: 500, y: 500)).overlayPoint(in: screen) == CGPoint(x: 720, y: 450),
               "centre of the grid is the centre of the screen")
        // A malformed or hostile position is clamped, not trusted.
        expect(SentinelVerdict(onTask: false, confidence: 1, reason: "", nudge: "", block: nil,
                               point: GridPoint(x: -9999, y: -9999)).overlayPoint(in: screen) == .zero,
               "negative grid position clamps to the top-left")
        expect(SentinelVerdict(onTask: false, confidence: 1, reason: "", nudge: "", block: nil,
                               point: GridPoint(x: 1e9, y: 1e9)).overlayPoint(in: screen) == CGPoint(x: 1440, y: 900),
               "absurd grid position clamps to the bottom-right")
        expect(SentinelVerdict(onTask: false, confidence: 1, reason: "", nudge: "", block: nil,
                               point: nil).overlayPoint(in: screen) == CGPoint(x: 720, y: 270),
               "missing position falls back to a sensible default")

        let withPoint = "{\"on_task\": false, \"confidence\": 0.9, \"reason\": \"x\", \"nudge\": \"y\", \"block\": null, \"point\": {\"x\": 100, \"y\": 200}}"
        if let v = try? Brain.parse(withPoint) {
            expect(v.point == GridPoint(x: 100, y: 200), "grid position parses out of the reply")
        } else {
            fail("reply with a point should parse")
        }
        let noPoint = "{\"on_task\": false, \"confidence\": 0.9, \"reason\": \"x\", \"nudge\": \"y\", \"block\": null, \"point\": null}"
        if let v = try? Brain.parse(noPoint) {
            expect(v.point == nil, "null position parses as no position")
        } else {
            fail("reply with a null point should parse")
        }

        // ── Target Locking & Shift Detection ──────────────────────────────────
        section("target locking & shift detection (zero credits spent on-target)")
        let lockedXcode = LockedTarget(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                                       windowTitle: "Sentinel.swift", domain: nil, url: nil, lockedAt: Date())
        expect(sentinel.isMatchingLockedTarget(xcode, target: lockedXcode), "matching xcode file is on-target")

        let lockedDocs = LockedTarget(appName: "Google Chrome", bundleID: "com.google.Chrome",
                                      windowTitle: "Google Docs - Essay", domain: "docs.google.com",
                                      url: "https://docs.google.com/document/d/123", lockedAt: Date())
        let docsProbe = FocusProbe(app: "Google Chrome", bundleID: "com.google.Chrome",
                                   windowTitle: "Google Docs", url: "https://docs.google.com/document/d/123",
                                   idleSeconds: 1, at: Date())
        expect(sentinel.isMatchingLockedTarget(docsProbe, target: lockedDocs), "matching browser domain is on-target")

        // Shift away from locked Xcode to Chrome YouTube
        expect(!sentinel.isMatchingLockedTarget(chrome, target: lockedXcode), "switching from xcode to youtube is off-target shift")

        // Shift away from Google Docs to Chrome YouTube
        expect(!sentinel.isMatchingLockedTarget(chrome, target: lockedDocs), "switching tabs from docs to youtube is off-target shift")

        // ── Semantic Topic Continuity (0ms Pre-Filter) ──────────────────────
        section("semantic topic continuity (0ms pre-filter, zero false alarms)")
        let lockedWaveOptics = LockedTarget(
            appName: "Preview",
            bundleID: "com.apple.Preview",
            windowTitle: "Wave Optics.pdf",
            domain: nil,
            url: nil,
            lockedAt: Date()
        )
        let waveOpticsQuestions = FocusProbe(
            app: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Wave Optics Practice Questions | Khan Academy",
            url: "https://khanacademy.org/science/physics/wave-optics",
            idleSeconds: 1,
            at: Date()
        )
        let youtubeCatMemes = FocusProbe(
            app: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "YouTube - Funny Cat Memes",
            url: "https://www.youtube.com/watch?v=cats",
            idleSeconds: 1,
            at: Date()
        )
        expect(Sentinel.isTopicRelated(goal: "studying wave optics pdf", target: lockedWaveOptics, current: waveOpticsQuestions),
               "Wave Optics PDF -> Chrome practice questions is approved instantly (topic continuity)")
        expect(!Sentinel.isTopicRelated(goal: "studying wave optics pdf", target: lockedWaveOptics, current: youtubeCatMemes),
               "Wave Optics PDF -> YouTube cat memes correctly rejects topic pre-filter")

        let calculusHomework = FocusProbe(
            app: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Desmos Graphing Calculator - Calculus Functions",
            url: "https://www.desmos.com/calculator",
            idleSeconds: 1,
            at: Date()
        )
        expect(Sentinel.isTopicRelated(goal: "Finish calculus problem set 4", target: nil, current: calculusHomework),
               "Calculus goal -> Desmos calculus calculator is approved as topic related")

        // ── Sentinel judge resolution ────────────────────────────────────────
        section("hybrid AI provider resolution")
        if let judge = AIConfig.resolveForSentinel() {
            // The local llama3.2:1b model was measured calling YouTube, Reddit and Steam all
            // "on-task", so the Sentinel's judge is Token Harbor's DeepSeek V4.1 Flash, which
            // scored 6/6 on the same cases.
            expect(judge.provider == .tokenHarbor && judge.model == "deepseek-v4.1-flash",
                   "resolveForSentinel routes to Token Harbor deepseek-v4.1-flash")
            expect(judge.endpoint.absoluteString == "https://tokenharbor.ai/v1/chat/completions",
                   "and points at the Token Harbor endpoint")
            expect(!judge.apiKey.isEmpty, "with a usable key")
        } else {
            fail("resolveForSentinel should return the Token Harbor provider")
        }
        expect(AIConfig.hasAnyKey, "AIConfig has active provider configured")
        // No trace of the retired local model should remain anywhere in the routing table.
        expect(!AIProvider.allCases.contains { $0.rawValue == "local" },
               "the local 1B provider is gone from the provider list")

        // ── Hermes AI Study Learner & Memory ─────────────────────────────────
        section("Hermes AI Study Learner & Memory Engine")
        let learner = StudyLearner.shared
        learner.startFocusSession(goal: "Quantum Mechanics & Wave Optics")
        expect(learner.profile.subjects["Quantum Mechanics & Wave Optics"] != nil || learner.profile.totalFocusMinutes >= 0,
               "study session initialized with subject")
        learner.recordFocusProgress(app: "Xcode", domain: "developer.apple.com", durationMinutes: 15.0)
        expect((learner.profile.productiveTools["Xcode"] ?? 0) >= 0.95,
               "productive tool confidence increased")
        expect((learner.profile.subjects["Quantum Mechanics & Wave Optics"]?.minutesSpent ?? 0) >= 15.0,
               "subject study duration logged")

        learner.recordDrift(culprit: "youtube.com", sessionDurationMins: 35.0)
        expect((learner.profile.distractionTriggers["youtube.com"] ?? 0) >= 1,
               "distraction trigger recorded")

        learner.addLearnedFact("Prepares for physics exam and prefers 40-minute blocks")
        expect(learner.profile.userNotes.contains("Prepares for physics exam and prefers 40-minute blocks"),
               "explicit personal study fact recorded")

        let promptCtx = learner.systemPromptContext()
        expect(promptCtx.localizedCaseInsensitiveContains("hermes") && promptCtx.contains("Quantum Mechanics & Wave Optics"),
               "system prompt context contains synthesized study subject and insights")

        // ── Vorssaint Reverse-Engineered Notch Geometry & Curves ───────────────
        section("Vorssaint Reverse-Engineered Notch Geometry")
        let dummyScreen = NSScreen.main ?? NSScreen.screens.first!
        let attachedGeo = NotchGeometry(screen: dummyScreen, preference: .attached, floatingGap: 10.0)
        let floatingGeo = NotchGeometry(screen: dummyScreen, preference: .floating, floatingGap: 12.0)

        let s34 = attachedGeo.shoulder(for: 34.0)
        let expectedS = min(14.0, 34.0 * 0.19)
        expect(abs(s34 - expectedS) < 0.001, "shoulder formula matches reverse-engineered min(14, h * 0.19)")
        expect(abs(attachedGeo.shoulder(for: 20.0) - (20.0 * 0.19)) < 0.001, "shoulder for small height matches 20 * 0.19 = 3.8 without artificial clamp")
        expect(attachedGeo.shoulder(for: 100.0) == 14.0, "shoulder correctly clamps to 14.0 for large panels")
        expect(floatingGeo.shoulder(for: 34.0) == 0.0, "floating island pill has 0 shoulder fillet")

        let rAttached = attachedGeo.cornerRadius(for: 34.0, shoulder: s34)
        expect(rAttached >= 8.0 && rAttached <= 20.0, "attached bottom corner squircle radius in bounds")

        let rFloating = floatingGeo.cornerRadius(for: 34.0, shoulder: 0)
        expect(rFloating == 17.0, "floating pill corner radius is half-height squircle")
        expect(floatingGeo.cornerRadius(for: 60.0, shoulder: 0) == 28.0, "floating pill corner radius matches Vorssaint capsuleRadius clamp of 28.0")

        expect(NotchGeometry.capsuleGap(barHeight: 24.0) == 2.0, "capsule gap matches Vorssaint formula for 24pt bar (2.0)")
        expect(NotchGeometry.capsuleGap(barHeight: 38.0) == 9.0, "capsule gap matches Vorssaint formula for 38pt bar (9.0)")

        let attachedPath = attachedGeo.buildPath(in: CGRect(x: 0, y: 0, width: 220, height: 34))
        expect(!attachedPath.isEmpty, "attached notch path is non-empty")
        expect(attachedPath.boundingBox.width == 220, "attached notch path covers specified width")

        expect(attachedGeo.contains(CGPoint(x: 110, y: 17), in: CGRect(x: 0, y: 0, width: 220, height: 34)), "center of attached notch is inside contour")
        expect(!attachedGeo.contains(CGPoint(x: 1, y: 1), in: CGRect(x: 0, y: 0, width: 220, height: 34)), "bottom corner cutaway is outside attached notch contour")

        let floatingPath = floatingGeo.buildPath(in: CGRect(x: 0, y: 0, width: 220, height: 34))
        expect(!floatingPath.isEmpty, "floating island path is non-empty")

        let attachedFrame = attachedGeo.windowFrame(for: CGSize(width: 220, height: 34))
        expect(attachedFrame.origin.y <= dummyScreen.frame.maxY - 34, "attached notch hugs screen top bezel")

        let floatingFrame = floatingGeo.windowFrame(for: CGSize(width: 220, height: 34))
        expect(floatingFrame.origin.y < dummyScreen.frame.maxY - 34, "floating island pill is inset from top with gap")

        // ── Summary ──────────────────────────────────────────────────────────────────────────
        print("")
        // Put the user's real choice back: the suite must leave no trace in UserDefaults.
        Settings.shared.sentinelAct = savedAct
        if failures == 0 {
            print("✅  \(checks) checks passed — the guard rails hold.")
        } else {
            print("❌  \(failures) of \(checks) checks FAILED.")
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Tiny test harness

    private static func section(_ title: String) {
        print("\n── \(title) ──")
    }

    private static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        if condition {
            print("  ok    \(label)")
        } else {
            fail(label)
        }
    }

    private static func fail(_ label: String) {
        failures += 1
        print("  FAIL  \(label)")
    }
}