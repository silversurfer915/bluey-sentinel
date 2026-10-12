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

    private var snapshotTimer: Timer?
    private var pollTimer: Timer?
    private var contextFetchedAt = Date.distantPast
    private var currentServerRevision = 0
    private var outbox: [OutboxOperation] = []
    private var isSyncing = false

    private static var defaultOutboxURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly/sanctra_outbox.json")
    }

    private let outboxURL: URL
    private let applyState: ((SanctraActiveSession?) -> Void)?
    public init(client: SanctraClient = SanctraClient(), outboxURL: URL? = nil, applyState: ((SanctraActiveSession?) -> Void)? = nil) {
        self.client = client
        self.outboxURL = outboxURL ?? Self.defaultOutboxURL
        self.applyState = applyState
        loadOutbox()
    }

    public func start() {
        refreshConnection()
        scheduleNextPoll()
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in PhoneSessionManager.shared.syncWithLocalState() }
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        snapshotTimer?.invalidate(); snapshotTimer = nil
    }

    public func connect() async throws {
        let acc = try await client.fetchAccount()
        account = acc; isConnected = true; syncError = nil
        currentServerRevision = 0
        studyContext = try? await client.fetchContext()
        contextFetchedAt = Date()
        await syncNow()
    }
    private func adopt(_ session: SanctraActiveSession?) {
        if let applyState { applyState(session) } else { BlueyCoordinator.shared.adoptCanonical(session) }
    }
    public func refreshConnection() {
        Task {
            do {
                try await self.connect()
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

        do {
            // Reconcile authority before replaying queued operations.
            let state = try await client.fetchSync(revision: currentServerRevision)
            lastSyncDate = Date(); syncError = nil
            if !state.notModified {
                currentServerRevision = state.revision
                activeCanonicalSession = state.activeSession
                if !outbox.contains(where: { $0.accountUid == account?.uid && $0.action == "create" }) {
                    adopt(state.activeSession)
                }
            }
            await flushOutbox()
            guard isConnected else { return }
            let latest = try await client.fetchSync(revision: nil)
            currentServerRevision = latest.revision
            activeCanonicalSession = latest.activeSession
            if !outbox.contains(where: { $0.accountUid == account?.uid && $0.action == "create" }) {
                adopt(latest.activeSession)
            }
            if studyContext == nil || Date().timeIntervalSince(contextFetchedAt) > 60 { studyContext = try? await client.fetchContext(); contextFetchedAt = Date() }
        } catch {
            if case SanctraError.unauthenticated = error { isConnected = false }
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
        let pending = outbox
        for op in pending {
            guard isConnected, op.accountUid == currentUid else { continue }
            do {
                if op.action == "create" {
                    let (session, _) = try await client.createSession(operationId: op.operationId, sessionId: op.sessionId, subjectId: op.subjectId ?? "general", subjectName: op.subjectName ?? "Study", topicTitle: op.topicTitle, plannedDurationSeconds: op.plannedSeconds ?? 1800, startTime: op.timestamp)
                    activeCanonicalSession = session
                } else {
                    let (session, _) = try await client.mutateSession(sessionId: op.sessionId, operationId: op.operationId, action: op.action, expectedRevision: op.expectedRevision)
                    activeCanonicalSession = session.status == "active" ? session : nil
                }
                outbox.removeAll { $0.id == op.id }
                saveOutbox()
            } catch {
                if case SanctraError.conflict(let message) = error {
                    BlueyState.shared.warning = "Sanctra session conflict: " + message
                    outbox.removeAll { $0.id == op.id }; saveOutbox()
                } else {
                    if case SanctraError.unauthenticated = error { isConnected = false }
                    syncError = error.localizedDescription
                    break // Preserve this operation and every later queued operation.
                }
            }
        }
    }

    private func saveOutbox() {
        pendingOutboxCount = outbox.count
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        try? FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: outboxURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outboxURL.path)
    }

    private func loadOutbox() {
        guard let data = try? Data(contentsOf: outboxURL),
              let loaded = try? JSONDecoder().decode([OutboxOperation].self, from: data) else { return }
        outbox = loaded
        pendingOutboxCount = loaded.count
    }
}
