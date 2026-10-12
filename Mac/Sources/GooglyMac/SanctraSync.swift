import AppKit
import Foundation

struct OutboxOperation: Codable, Sendable {
    let id: String
    let operationId: String
    let sessionId: String
    let action: String // "create", "pause", "resume", "finish"
    let timestamp: Double
    let accountUid: String
    let subjectId: String?
    let subjectName: String?
    let topicTitle: String?
    let plannedSeconds: Int?
    let expectedRevision: Int?

    init(
        id: String = UUID().uuidString,
        operationId: String = UUID().uuidString,
        sessionId: String,
        action: String,
        timestamp: Double = Date().timeIntervalSince1970 * 1000,
        accountUid: String,
        subjectId: String? = nil,
        subjectName: String? = nil,
        topicTitle: String? = nil,
        plannedSeconds: Int? = nil,
        expectedRevision: Int? = nil
    ) {
        self.id = id
        self.operationId = operationId
        self.sessionId = sessionId
        self.action = action
        self.timestamp = timestamp
        self.accountUid = accountUid
        self.subjectId = subjectId
        self.subjectName = subjectName
        self.topicTitle = topicTitle
        self.plannedSeconds = plannedSeconds
        self.expectedRevision = expectedRevision
    }
}

@MainActor
final class SanctraSync: ObservableObject {
    static let shared = SanctraSync()

    let client: SanctraClient
    @Published private(set) var isConnected = false
    @Published private(set) var account: SanctraAccount?
    @Published private(set) var studyContext: SanctraStudyContext?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var pendingOutboxCount = 0
    @Published private(set) var syncError: String?
    @Published private(set) var activeCanonicalSession: SanctraActiveSession?

    private var pollTimer: Timer?
    private var currentServerRevision = 0
    private var outbox: [OutboxOperation] = []
    private var isSyncing = false

    private static var outboxURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly/sanctra_outbox.json")
    }

    public init(client: SanctraClient = SanctraClient()) {
        self.client = client
        loadOutbox()
    }

    public func start() {
        refreshConnection()
        scheduleNextPoll()
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    public func refreshConnection() {
        Task {
            do {
                let acc = try await client.fetchAccount()
                self.account = acc
                self.isConnected = true
                self.syncError = nil
                self.studyContext = try? await client.fetchContext()
                await self.syncNow()
            } catch {
                if case SanctraError.unauthenticated = error {
                    self.isConnected = false
                    self.account = nil
                }
                self.syncError = error.localizedDescription
            }
        }
    }

    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        let interval: TimeInterval = activeCanonicalSession != nil || BlueyCoordinator.shared.focusClock.isActive ? 3.0 : 15.0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
                self?.scheduleNextPoll()
            }
        }
    }

    public func syncNow() async {
        guard isConnected, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // 1. Flush durable outbox
        await flushOutbox()

        // 2. Fetch server state
        do {
            let state = try await client.fetchSync(revision: currentServerRevision)
            lastSyncDate = Date()
            syncError = nil

            if !state.notModified {
                currentServerRevision = state.revision
                activeCanonicalSession = state.activeSession

                // Reconcile local state with remote session
                if let active = state.activeSession {
                    let coordinator = BlueyCoordinator.shared
                    if !coordinator.focusClock.isActive {
                        let name = (active.subjectName ?? "Study") + (active.topicTitle.map { ": \($0)" } ?? "")
                        Settings.shared.focusGoal = name
                        await coordinator.execute(.startFocus(name))
                    }
                }
            }
        } catch {
            if case SanctraError.unauthenticated = error {
                isConnected = false
            }
            syncError = error.localizedDescription
        }
    }

    // MARK: - Outbox Management

    public func queueSessionStart(
        sessionId: String,
        subjectId: String,
        subjectName: String,
        topicTitle: String? = nil,
        plannedSeconds: Int = 1800
    ) {
        guard let uid = account?.uid else { return }
        let op = OutboxOperation(
            sessionId: sessionId,
            action: "create",
            accountUid: uid,
            subjectId: subjectId,
            subjectName: subjectName,
            topicTitle: topicTitle,
            plannedSeconds: plannedSeconds
        )
        outbox.append(op)
        saveOutbox()
        Task { await syncNow() }
    }

    public func queueSessionAction(
        sessionId: String,
        action: String,
        expectedRevision: Int? = nil
    ) {
        guard let uid = account?.uid else { return }
        let op = OutboxOperation(
            sessionId: sessionId,
            action: action,
            accountUid: uid,
            expectedRevision: expectedRevision
        )
        outbox.append(op)
        saveOutbox()
        Task { await syncNow() }
    }

    private func flushOutbox() async {
        guard let currentUid = account?.uid else { return }
        var remaining: [OutboxOperation] = []

        for op in outbox {
            // Discard outbox operations that belong to a different account
            guard op.accountUid == currentUid else { continue }

            do {
                if op.action == "create" {
                    let (session, rev) = try await client.createSession(
                        operationId: op.operationId,
                        sessionId: op.sessionId,
                        subjectId: op.subjectId ?? "general",
                        subjectName: op.subjectName ?? "Study",
                        topicTitle: op.topicTitle,
                        plannedDurationSeconds: op.plannedSeconds ?? 1800
                    )
                    currentServerRevision = rev
                    activeCanonicalSession = session
                } else {
                    let (session, rev) = try await client.mutateSession(
                        sessionId: op.sessionId,
                        operationId: op.operationId,
                        action: op.action,
                        expectedRevision: op.expectedRevision
                    )
                    currentServerRevision = rev
                    activeCanonicalSession = session.status == "active" ? session : nil
                }
            } catch {
                if case SanctraError.conflict(let message) = error {
                    // Conflict reported by server: surface to UI, discard operation
                    BlueyState.shared.warning = "Sanctra session conflict: \(message)"
                } else if case SanctraError.unauthenticated = error {
                    isConnected = false
                    remaining.append(op)
                    break
                } else {
                    // Network or temporary failure: keep in queue to retry
                    remaining.append(op)
                }
            }
        }

        outbox = remaining
        saveOutbox()
    }

    private func saveOutbox() {
        pendingOutboxCount = outbox.count
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        try? FileManager.default.createDirectory(at: Self.outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.outboxURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.outboxURL.path)
    }

    private func loadOutbox() {
        guard let data = try? Data(contentsOf: Self.outboxURL),
              let loaded = try? JSONDecoder().decode([OutboxOperation].self, from: data) else { return }
        outbox = loaded
        pendingOutboxCount = loaded.count
    }
}
