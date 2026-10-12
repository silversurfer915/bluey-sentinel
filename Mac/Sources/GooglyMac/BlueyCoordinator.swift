import AppKit
import Combine

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
    private(set) var paused = false
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
        NotchController.shared.refreshPresentation()
        onChange?()
    }
    @discardableResult func execute(_ command: BlueyCommand) async -> String {
        let s = Settings.shared
        switch command {
        case .startFocus(let goal):
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Tell me what you want to focus on." }
            resumeTask?.cancel(); paused = false
            if s.sentinelEnabled { sentinel.stop() }
            sentinel.unlockTarget()
            s.focusGoal = goal; s.sentinelEnabled = true; sentinel.start()
        case .lockTarget:
            resumeTask?.cancel(); paused = false
            await sentinel.lockCurrentTarget()
        case .unlockTarget: sentinel.unlockTarget()
        case .stopFocus:
            resumeTask?.cancel(); paused = false; s.sentinelEnabled = false; sentinel.stop()
        case .pauseFocus(let seconds):
            resumeTask?.cancel(); paused = true; s.sentinelEnabled = false; sentinel.stop()
            if seconds > 0 {
                resumeTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation() } catch { return }
                    await self?.execute(.resumeFocus)
                }
            }
        case .resumeFocus:
            guard !s.focusGoal.isEmpty || s.sentinelLockedTarget != nil else { return "Set a focus goal or lock a window first." }
            resumeTask?.cancel(); paused = false; s.sentinelEnabled = true; sentinel.start()
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
        case .openNotes: NSWorkspace.shared.open(MeetingNotes.root)
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
