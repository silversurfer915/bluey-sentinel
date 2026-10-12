import Foundation

struct SanctraAccount: Codable, Sendable {
    let uid: String
    let displayName: String
    let timezone: String

    init(uid: String, displayName: String, timezone: String) {
        self.uid = uid
        self.displayName = displayName
        self.timezone = timezone
    }
}

struct SanctraSubject: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let color: String?

    init(id: String, name: String, color: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
    }
}

struct SanctraTopic: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let subjectId: String?
    let completed: Bool?
    let revisionCount: Int?

    init(id: String, title: String, subjectId: String? = nil, completed: Bool? = nil, revisionCount: Int? = nil) {
        self.id = id
        self.title = title
        self.subjectId = subjectId
        self.completed = completed
        self.revisionCount = revisionCount
    }
}

struct SanctraGoal: Codable, Sendable {
    let dailyGoalHours: Double?
    let weeklyTargetHours: Double?

    init(dailyGoalHours: Double? = nil, weeklyTargetHours: Double? = nil) {
        self.dailyGoalHours = dailyGoalHours
        self.weeklyTargetHours = weeklyTargetHours
    }
}

struct SanctraStreaks: Codable, Sendable {
    let streakDays: Int?
    let streakDate: String?
    let streakUtcOffset: Int?

    init(streakDays: Int? = nil, streakDate: String? = nil, streakUtcOffset: Int? = nil) {
        self.streakDays = streakDays
        self.streakDate = streakDate
        self.streakUtcOffset = streakUtcOffset
    }
}

struct SanctraActiveSession: Codable, Sendable {
    let id: String
    let subjectId: String?
    let subjectName: String?
    let topicId: String?
    let topicTitle: String?
    let plannedDurationSeconds: Int?
    let actualDurationSeconds: Int?
    let startTime: Double?
    let status: String
    let isPaused: Bool
    let pausedAt: Double?
    let runningSince: Double?
    let accumulatedSeconds: Int?
    let mode: String?
    let source: String?
    let revision: Int?

    init(
        id: String,
        subjectId: String? = nil,
        subjectName: String? = nil,
        topicId: String? = nil,
        topicTitle: String? = nil,
        plannedDurationSeconds: Int? = nil,
        actualDurationSeconds: Int? = nil,
        startTime: Double? = nil,
        status: String = "active",
        isPaused: Bool = false,
        pausedAt: Double? = nil,
        runningSince: Double? = nil,
        accumulatedSeconds: Int? = nil,
        mode: String? = "stopwatch",
        source: String? = "mac-app",
        revision: Int? = 1
    ) {
        self.id = id
        self.subjectId = subjectId
        self.subjectName = subjectName
        self.topicId = topicId
        self.topicTitle = topicTitle
        self.plannedDurationSeconds = plannedDurationSeconds
        self.actualDurationSeconds = actualDurationSeconds
        self.startTime = startTime
        self.status = status
        self.isPaused = isPaused
        self.pausedAt = pausedAt
        self.runningSince = runningSince
        self.accumulatedSeconds = accumulatedSeconds
        self.mode = mode
        self.source = source
        self.revision = revision
    }
}

struct SanctraStudyContext: Codable, Sendable {
    let revision: String?
    let account: SanctraAccount?
    let streaks: SanctraStreaks?
    let subjects: [SanctraSubject]?
    let topics: [SanctraTopic]?
    let goals: SanctraGoal?

    init(
        revision: String? = nil,
        account: SanctraAccount? = nil,
        streaks: SanctraStreaks? = nil,
        subjects: [SanctraSubject]? = nil,
        topics: [SanctraTopic]? = nil,
        goals: SanctraGoal? = nil
    ) {
        self.revision = revision
        self.account = account
        self.streaks = streaks
        self.subjects = subjects
        self.topics = topics
        self.goals = goals
    }
}

struct SanctraSyncState: Sendable {
    let revision: Int
    let serverTime: Double
    let activeSession: SanctraActiveSession?
    let notModified: Bool

    init(revision: Int, serverTime: Double, activeSession: SanctraActiveSession?, notModified: Bool) {
        self.revision = revision
        self.serverTime = serverTime
        self.activeSession = activeSession
        self.notModified = notModified
    }
}

enum SanctraError: LocalizedError, Sendable {
    case unauthenticated
    case forbidden(String)
    case notFound
    case conflict(String)
    case serverError(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthenticated: return "Sign in or reconnect your Sanctra personal token in Settings."
        case .forbidden(let msg): return "Sanctra access denied: \(msg)"
        case .notFound: return "Requested Sanctra study record was not found."
        case .conflict(let msg): return "Study session conflict: \(msg)"
        case .serverError(let code, let msg): return "Sanctra server error (\(code)): \(msg)"
        case .network(let msg): return "Network error connecting to Sanctra: \(msg)"
        }
    }
}

final class SanctraClient: Sendable {
    let baseURL: URL
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://api.sanctrastudy.live/v1/personal")!,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String? = { Keychain.get(.sanctraPersonalToken) }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, etag: String? = nil) throws -> URLRequest {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw SanctraError.unauthenticated
        }
        let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
        var components = URLComponents(url: baseURL.appendingPathComponent(pieces[0]), resolvingAgainstBaseURL: false)!
        if pieces.count > 1 { components.percentEncodedQuery = pieces[1] }
        guard let url = components.url else { throw SanctraError.network("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let etag {
            request.setValue("\"\(etag)\"", forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    func fetchAccount() async throws -> SanctraAccount {
        let request = try makeRequest("account")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        struct Envelope: Decodable { let account: SanctraAccount }
        return try JSONDecoder().decode(Envelope.self, from: data).account
    }

    func fetchContext() async throws -> SanctraStudyContext {
        let request = try makeRequest("context")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(SanctraStudyContext.self, from: data)
    }

    func fetchSync(revision: Int?) async throws -> SanctraSyncState {
        var path = "sync"
        if let revision { path += "?revision=\(revision)" }
        let request = try makeRequest(path, etag: revision.map { String($0) })
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SanctraError.network("Invalid response") }
        if http.statusCode == 304 {
            return SanctraSyncState(revision: revision ?? 0, serverTime: Date().timeIntervalSince1970 * 1000, activeSession: nil, notModified: true)
        }
        try validateResponse(response, data: data)

        struct RawSync: Codable {
            let revision: Int?
            let serverTime: Double?
            let activeSession: SanctraActiveSession?
        }
        let raw = try JSONDecoder().decode(RawSync.self, from: data)
        return SanctraSyncState(
            revision: raw.revision ?? 0,
            serverTime: raw.serverTime ?? Date().timeIntervalSince1970 * 1000,
            activeSession: raw.activeSession,
            notModified: false
        )
    }

    func createSession(
        operationId: String,
        sessionId: String,
        subjectId: String,
        subjectName: String,
        topicId: String? = nil,
        topicTitle: String? = nil,
        plannedDurationSeconds: Int = 1800,
        mode: String = "stopwatch",
        startTime: Double = Date().timeIntervalSince1970 * 1000
    ) async throws -> (session: SanctraActiveSession, revision: Int) {
        var payload: [String: Any] = [
            "operationId": operationId,
            "sessionId": sessionId,
            "subjectId": subjectId,
            "subjectName": subjectName,
            "plannedDurationSeconds": plannedDurationSeconds,
            "mode": mode,
            "source": "mac-app",
            "deviceId": "mac",
            "status": "active",
            "startTime": startTime
        ]
        if let topicId { payload["topicId"] = topicId }
        if let topicTitle { payload["topicTitle"] = topicTitle }
        let body = try JSONSerialization.data(withJSONObject: payload)

        let request = try makeRequest("sessions", method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)

        struct CreateRes: Codable {
            let session: SanctraActiveSession
            let revision: Int
        }
        let res = try JSONDecoder().decode(CreateRes.self, from: data)
        return (res.session, res.revision)
    }

    func mutateSession(
        sessionId: String,
        operationId: String,
        action: String,
        expectedRevision: Int? = nil,
        notes: String? = nil
    ) async throws -> (session: SanctraActiveSession, revision: Int) {
        var payload: [String: Any] = [
            "operationId": operationId,
            "action": action
        ]
        if let expectedRevision { payload["expectedRevision"] = expectedRevision }
        if let notes { payload["notes"] = notes }
        let body = try JSONSerialization.data(withJSONObject: payload)

        let request = try makeRequest("sessions/\(sessionId)", method: "PATCH", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)

        struct MutateRes: Codable {
            let session: SanctraActiveSession
            let revision: Int
        }
        let res = try JSONDecoder().decode(MutateRes.self, from: data)
        return (res.session, res.revision)
    }

    /// Bounded authenticated study resources for the assistant. Tokens never enter returned text.
    func readResource(_ resource: String) async throws -> String {
        guard ["subjects", "topics", "goals", "notes", "sessions", "plans", "tasks", "calendar", "context"].contains(resource) else { throw SanctraError.notFound }
        let request = try makeRequest(resource)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        guard data.count <= 512_000 else { throw SanctraError.network("Study response too large") }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func fetchHistory(cursor: String? = nil) async throws -> String {
        var path = "sessions?limit=50"
        if let cursor {
            guard cursor.count <= 128, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?#"))) else { throw SanctraError.notFound }
            path += "&cursor=" + encoded
        }
        let request = try makeRequest(path)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func createPlans(body: Data) async throws -> String {
        guard body.count <= 64_000 else { throw SanctraError.network("Plan batch too large") }
        let request = try makeRequest("plans", method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SanctraError.network("Invalid response") }
        if (200...299).contains(http.statusCode) { return }

        let message: String
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["message"] as? String {
            message = msg
        } else {
            message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        }

        switch http.statusCode {
        case 401: throw SanctraError.unauthenticated
        case 403: throw SanctraError.forbidden(message)
        case 404: throw SanctraError.notFound
        case 409: throw SanctraError.conflict(message)
        default: throw SanctraError.serverError(http.statusCode, message)
        }
    }
}
