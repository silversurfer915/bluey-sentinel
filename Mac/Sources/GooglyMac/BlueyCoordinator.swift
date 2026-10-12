import AppKit
import Combine
import GooglyShared

/// Direct commands bypass the model; compound requests use the same operations through tools.
enum BlueyCommand: Equatable {
    case startFocus(String), lockTarget, unlockTarget, pauseFocus(TimeInterval), resumeFocus, stopFocus, checkFocus, focusStatus, dismissWarning, cancelTask, confirmAction, rejectAction, warnOnly, enableEnforcement, openNotes
    static func parse(_ input: String) -> BlueyCommand? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("bluey") { text = String(text.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        switch text {
        case "lock this window", "lock this tab", "lock current target": return .lockTarget
        case "unlock target", "unlock this window": return .unlockTarget
        case "resume focus", "resume watching": return .resumeFocus
        case "stop focus", "stop watching", "turn off focus sentinel": return .stopFocus
        case "pause focus", "pause watching": return .pauseFocus(0)
        case "check my focus", "check focus now": return .checkFocus
        case "focus status", "what is my focus goal": return .focusStatus
        case "i'm back", "i am back", "dismiss warning": return .dismissWarning
        case "yes proceed", "confirm action": return .confirmAction
        case "cancel action", "no cancel": return .rejectAction
        case "stop", "cancel", "stop task", "cancel task": return .cancelTask
        case "warn only", "disable enforcement": return .warnOnly
        case "enable enforcement", "close distractions after warning": return .enableEnforcement
        case "open meeting notes", "show meeting notes": return .openNotes
        default: break
        }
        if text.hasPrefix("pause focus for "), text.hasSuffix(" minutes") {
            let value = String(text.dropFirst(16).dropLast(8))
            let words = ["one": 1, "two": 2, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30]
            if let minutes = Int(value) ?? words[value], (1...240).contains(minutes) { return .pauseFocus(Double(minutes) * 60) }
            return nil
        }
        for prefix in ["focus on ", "start focus on ", "help me study "] where text.hasPrefix(prefix) {
            let goal = String(input.trimmingCharacters(in: .whitespacesAndNewlines).suffix(text.count - prefix.count))
            guard !goal.isEmpty, !text.contains(" and ") else { return nil }
            return .startFocus(goal)
        }
        return nil
    }
}

@MainActor
final class BlueyState: ObservableObject {
    static let shared = BlueyState()
    @Published var workspacePage = "Assistant"
    @Published var focusStatus = "No focus session"
    @Published var taskStatus = "Ready when you are"
    @Published var answer = "Ask about your screen, start a focus session, or give Bluey a task."
    @Published var transcript = ""
    @Published var busy = false
    @Published var listening = false
    @Published var warning: String?
    @Published var activeProvider = ""
    @Published var taskSteps: [String] = []
    @Published var pendingConfirmation: String?
}

@MainActor
final class BlueyCoordinator {
    static let shared = BlueyCoordinator()
    let sentinel = Sentinel()
    private var resumeTask: Task<Void, Never>?
    private(set) var localSessionId: String?
    private(set) var localRevision = 0
    private(set) var lastEventId: String?
    private var applyingRemote = false
    private(set) var lastTermination: String?
    private(set) var plannedSeconds = 1800
    private(set) var paused = false
    private(set) var focusClock = FocusClock()
    var onCancelTask: (() -> Void)?
    var onChange: (() -> Void)?
    func configure(overlay: CursorOverlay) {
        sentinel.configure(overlay: overlay)
        sentinel.onChange = { [weak self] in self?.refresh() }
    }
    func refresh() {
        let s = Settings.shared
        let goal = s.focusGoal.isEmpty ? (sentinel.lockedTarget?.displayName ?? "Focus session") : s.focusGoal
        BlueyState.shared.focusStatus = paused ? "Paused · \(goal)" : (s.sentinelEnabled ? "Focusing · \(goal)" : "No focus session")
        BlueyState.shared.activeProvider = AIConfig.resolve()?.name ?? "Add an AI provider"
        PhoneSessionManager.shared.syncWithLocalState()
        DockCompanion.shared.refresh()
        onChange?()
    }
    func adoptCanonical(_ session: SanctraActiveSession?) {
        guard let session, session.status == "active" else {
            if localSessionId != nil, SanctraSync.shared.isConnected {
                if let session { lastTermination = session.status == "abandoned" ? "abandon" : "finish" }
                else if focusClock.isActive { lastTermination = nil }
                focusClock.finish(); paused = false
                Settings.shared.sentinelEnabled = false; sentinel.stop()
                refresh()
            }
            return
        }
        let changed = localSessionId != session.id
        let pauseChanged = paused != session.isPaused
        localSessionId = session.id
        localRevision = session.revision ?? 0
        plannedSeconds = session.plannedDurationSeconds ?? 1800
        paused = session.isPaused
        Settings.shared.focusGoal = (session.subjectName ?? "Study") + (session.topicTitle.map { ": " + $0 } ?? "")
        focusClock.reconcile(startedAt: Date(timeIntervalSince1970: (session.startTime ?? Date().timeIntervalSince1970 * 1000) / 1000), accumulated: Double(session.accumulatedSeconds ?? session.actualDurationSeconds ?? 0), runningSince: session.runningSince.map { Date(timeIntervalSince1970: $0 / 1000) }, paused: paused)
        if paused || ExecutionGate.shared.isStopped { Settings.shared.sentinelEnabled = false; sentinel.stop() }
        else if !Settings.shared.sentinelEnabled { Settings.shared.sentinelEnabled = true; sentinel.start() }
        if changed { lastTermination = nil; lastEventId = "start_" + session.id }
        else if pauseChanged { lastEventId = (paused ? "pause_" : "resume_") + UUID().uuidString }
        refresh()
    }

    func startPhoneFocus(_ command: PhoneSessionCommand) async -> String? {
        guard !ExecutionGate.shared.isStopped else { return "Bluey is stopped. Resume execution first." }
        guard let duration = command.plannedSeconds, (60...86400).contains(duration) else { return "Choose a valid duration." }
        plannedSeconds = duration
        if SanctraSync.shared.isConnected {
            guard let subject = SanctraSync.shared.studyContext?.subjects?.first(where: { $0.id == command.subjectId || $0.name.caseInsensitiveCompare(command.subjectLabel ?? "") == .orderedSame }) else { return "Subject is not in your Sanctra account." }
            let sid = command.sessionId ?? "phone-" + UUID().uuidString
            do {
                let (session, _) = try await SanctraSync.shared.client.createSession(operationId: command.commandId, sessionId: sid, subjectId: subject.id, subjectName: subject.name, topicId: command.topicId, topicTitle: command.topicLabel, plannedDurationSeconds: duration, startTime: command.timestamp * 1000)
                adoptCanonical(session)
                await SanctraSync.shared.syncNow()
                return nil
            } catch { return error.localizedDescription }
        }
        let result = await execute(.startFocus(command.topicLabel?.isEmpty == false ? command.topicLabel! : command.subjectLabel ?? "Focus"))
        return result.hasPrefix("Bluey is stopped") ? result : nil
    }

    func abandonFocus() async {
        if SanctraSync.shared.isConnected, let active = SanctraSync.shared.activeCanonicalSession {
            SanctraSync.shared.queueSessionAction(sessionId: active.id, action: "abandon", expectedRevision: active.revision)
        }
        lastTermination = "abandon"; localRevision += 1; lastEventId = "abandon_" + UUID().uuidString
        resumeTask?.cancel(); focusClock.finish(); paused = false; Settings.shared.sentinelEnabled = false; sentinel.stop(); refresh()
    }

    @discardableResult func execute(_ command: BlueyCommand, notesOpener: ((URL) -> Void)? = nil, approval: ((String) async -> Bool)? = nil) async -> String {
        let s = Settings.shared
        if ExecutionGate.shared.isStopped {
            switch command {
            case .cancelTask, .focusStatus, .pauseFocus, .resumeFocus, .stopFocus, .dismissWarning: break
            default: return "Bluey is stopped. Resume explicitly to enable work."
            }
        }
        switch command {
        case .startFocus(let goal):
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Tell me what you want to focus on." }
            resumeTask?.cancel(); paused = false
            localSessionId = "mac-" + UUID().uuidString
            localRevision += 1; lastTermination = nil; lastEventId = "start_" + localSessionId!
            focusClock.start()
            if s.sentinelEnabled { sentinel.stop() }
            sentinel.unlockTarget()
            s.focusGoal = goal; s.sentinelEnabled = true; sentinel.start()
            if SanctraSync.shared.isConnected, !applyingRemote {
                let context = SanctraSync.shared.studyContext
                guard let subject = context?.subjects?.first(where: { goal.localizedCaseInsensitiveContains($0.name) }) else {
                    s.sentinelEnabled = false; sentinel.stop(); focusClock.finish()
                    return "Choose an existing Sanctra subject before starting shared focus."
                }
                SanctraSync.shared.queueSessionStart(sessionId: localSessionId!, subjectId: subject.id, subjectName: subject.name, plannedSeconds: plannedSeconds)
            }
        case .lockTarget:
            resumeTask?.cancel(); paused = false
            await sentinel.lockCurrentTarget()
            if !focusClock.isActive { focusClock.start() } else { focusClock.resume() }
        case .unlockTarget: sentinel.unlockTarget()
        case .stopFocus:
            lastTermination = "finish"; localRevision += 1; lastEventId = "finish_" + (localSessionId ?? UUID().uuidString)
            resumeTask?.cancel(); paused = false; focusClock.finish(); s.sentinelEnabled = false; sentinel.stop()
            if SanctraSync.shared.isConnected, let activeId = SanctraSync.shared.activeCanonicalSession?.id {
                SanctraSync.shared.queueSessionAction(sessionId: activeId, action: "finish", expectedRevision: SanctraSync.shared.activeCanonicalSession?.revision)
            }
        case .pauseFocus(let seconds):
            localRevision += 1; lastEventId = "pause_" + UUID().uuidString
            resumeTask?.cancel(); focusClock.pause(); paused = true; s.sentinelEnabled = false; sentinel.stop()
            if SanctraSync.shared.isConnected, let activeId = SanctraSync.shared.activeCanonicalSession?.id {
                SanctraSync.shared.queueSessionAction(sessionId: activeId, action: "pause", expectedRevision: SanctraSync.shared.activeCanonicalSession?.revision)
            }
            if seconds > 0 {
                resumeTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation() } catch { return }
                    await self?.execute(.resumeFocus)
                }
            }
        case .resumeFocus:
            localRevision += 1; lastEventId = "resume_" + UUID().uuidString
            guard !s.focusGoal.isEmpty || s.sentinelLockedTarget != nil else { return "Set a focus goal or lock a window first." }
            resumeTask?.cancel(); if !focusClock.isActive { focusClock.start() } else { focusClock.resume() }; paused = false; s.sentinelEnabled = true; sentinel.start()
            if SanctraSync.shared.isConnected, let activeId = SanctraSync.shared.activeCanonicalSession?.id {
                SanctraSync.shared.queueSessionAction(sessionId: activeId, action: "resume", expectedRevision: SanctraSync.shared.activeCanonicalSession?.revision)
            }
        case .checkFocus:
            guard s.sentinelEnabled else { return "Start a focus session first." }
            let verdict = await sentinel.checkNow()
            return verdict.confidence == 0 ? "Focus check unavailable. Check the provider and permissions." : verdict.reason
        case .dismissWarning: sentinel.dismissWarning()
        case .confirmAction: BlueyApproval.shared.resolve(true); return "Confirmed."
        case .rejectAction: BlueyApproval.shared.resolve(false); return "Action cancelled."
        case .cancelTask: onCancelTask?(); return "Task stopped. Your focus session stays as it was."
        case .warnOnly: s.sentinelAct = false; sentinel.dismissWarning()
        case .enableEnforcement: s.sentinelAct = true
        case .openNotes:
            guard s.computerControl, s.autonomyMode != .off else { return "Computer actions are disabled." }
            let ticket = ExecutionGate.shared.ticket
            if s.autonomyMode.requiresConfirmation(name: "open_meeting_notes", label: "Saved meeting notes", arguments: [:]) {
                let allowed: Bool
                if let approval { allowed = await approval("Open saved meeting notes?") }
                else { allowed = await BlueyApproval.shared.request("Open saved meeting notes?") }
                guard allowed else { return "Action cancelled." }
            }
            guard ExecutionGate.shared.accepts(ticket), !Task.isCancelled else { return "Bluey is stopped. Resume explicitly to enable work." }
            ExecutionGate.shared.perform {
                if let notesOpener { notesOpener(MeetingNotes.root) }
                else { NSWorkspace.shared.open(MeetingNotes.root) }
            }
        case .focusStatus: break
        }
        refresh()
        switch command {
        case .warnOnly: return "Focus warnings only."
        case .enableEnforcement: return "Distraction intervention enabled after a warning."
        case .dismissWarning: return "Warning dismissed."
        case .openNotes: return "Opened meeting notes."
        default: return BlueyState.shared.focusStatus
        }
    }
}
