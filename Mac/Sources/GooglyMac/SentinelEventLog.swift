import Foundation

struct SentinelEvent: Identifiable, Codable {
    var id: UUID
    var timestamp: Date
    var trigger: String
    var app: String
    var windowTitle: String
    var domain: String?
    var outcome: String
    var isDrift: Bool

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         trigger: String,
         app: String,
         windowTitle: String,
         domain: String? = nil,
         outcome: String,
         isDrift: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.trigger = trigger
        self.app = app
        self.windowTitle = windowTitle
        self.domain = domain
        self.outcome = outcome
        self.isDrift = isDrift
    }
}

/// A thread-safe, rolling in-memory logger for Focus Sentinel detection events.
/// Allows verifying that context-change events and evaluations are firing in real time.
final class SentinelEventLog: @unchecked Sendable {
    static let shared = SentinelEventLog()

    private let lock = NSLock()
    private var _events: [SentinelEvent] = []
    var onChange: (() -> Void)?

    init() {}

    func record(trigger: String,
                app: String,
                windowTitle: String,
                domain: String? = nil,
                outcome: String,
                isDrift: Bool = false) {
        let event = SentinelEvent(
            trigger: trigger,
            app: app,
            windowTitle: windowTitle,
            domain: domain,
            outcome: outcome,
            isDrift: isDrift
        )
        lock.lock()
        _events.insert(event, at: 0)
        if _events.count > 200 {
            _events = Array(_events.prefix(200))
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    func recentEvents(limit: Int = 100) -> [SentinelEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_events.prefix(limit))
    }

    func clear() {
        lock.lock()
        _events.removeAll()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }
}
