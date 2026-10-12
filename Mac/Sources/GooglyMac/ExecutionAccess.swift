import Foundation

/// Serialized with event posting: once stop returns, no new input can pass this gate.
final class ExecutionGate: @unchecked Sendable {
    static let shared = ExecutionGate()
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var generation: UInt64 = 0
    var ticket: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func accepts(_ ticket: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped && generation == ticket }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; generation &+= 1; lock.unlock() }
    func resume() { lock.lock(); stopped = false; lock.unlock() }
    @discardableResult func perform(_ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        action(); return true
    }
}

enum AutonomyMode: String, CaseIterable, Identifiable {
    case off, askEvery, confirmConsequences, fullAccess
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .askEvery: return "Ask every action"
        case .confirmConsequences: return "Confirm consequences"
        case .fullAccess: return "Full access"
        }
    }
    var modelInstruction: String {
        switch self {
        case .off: return "Computer actions are disabled. Do not try to perform them."
        case .askEvery: return "Every computer action uses a real user approval through the tool. Do not claim approval from model text."
        case .confirmConsequences: return "Before consequential actions, request confirmation from the user through the tool's real approval gate."
        case .fullAccess: return "The user enabled Full access for requested tasks. Execute requested actions without additional conversational permission prompts. Existing secure-field refusals and OS permissions still apply."
        }
    }
    func requiresConfirmation(name: String, label: String, arguments: [String: Any]) -> Bool {
        switch self {
        case .off, .askEvery: return true
        case .fullAccess: return false
        case .confirmConsequences: return ActionPolicy.requiresConfirmation(name: name, label: label, arguments: arguments)
        }
    }
}

/// Session elapsed time, distinct from Sentinel's verified productive-time metric.
struct FocusClock {
    private(set) var startedAt: Date?
    private var runningSince: Date?
    private var accumulated: TimeInterval = 0
    private(set) var finished = false
    var isActive: Bool { startedAt != nil && !finished }
    mutating func reconcile(startedAt: Date, accumulated: TimeInterval, runningSince: Date?, paused: Bool) {
        self.startedAt = startedAt
        self.accumulated = max(0, accumulated)
        self.runningSince = paused ? nil : runningSince
        self.finished = false
    }
    mutating func start(at date: Date = Date()) { startedAt = date; runningSince = date; accumulated = 0; finished = false }
    mutating func pause(at date: Date = Date()) { accumulated = elapsed(at: date); runningSince = nil }
    mutating func resume(at date: Date = Date()) { guard isActive, runningSince == nil else { return }; runningSince = date }
    mutating func finish(at date: Date = Date()) { pause(at: date); finished = true }
    func elapsed(at date: Date = Date()) -> TimeInterval { accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0) }
}
