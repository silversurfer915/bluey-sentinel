import Foundation

/// The smallest boundary needed to inject a telemetry recorder in tests.
protocol CacheRecording: AnyObject {
    @discardableResult
    func recordFromResponse(data: Data, provider: AIProvider, model: String,
                            tier: ModelTier, prefixVersion: String, latencyMs: Int) -> CacheRequestLog
}

extension CacheTracker: CacheRecording {}

/// Shared OpenAI-compatible transport; no UI action is retried by this layer.
enum AIClient {
    static func send(_ body: [String: Any], ai: AIConfig.ResolvedProvider, session: URLSession = .shared) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: ai.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(ai.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Never display raw service bodies: some gateways echo request content or authorization.
            throw BrainError.http(code, code == 401 || code == 403 ? "Check the provider key and access." : "Check the endpoint, model, connection, and quota.")
        }
        return data
    }

    /// Sends a request and persists one telemetry row only after a successful
    /// HTTP response. A failed, cancelled, or non-2xx request records nothing.
    @discardableResult
    static func sendRecorded(_ body: [String: Any],
                             ai: AIConfig.ResolvedProvider,
                             session: URLSession = .shared,
                             recorder: CacheRecording = CacheTracker.shared) async throws -> Data {
        let start = Date()
        let data = try await send(body, ai: ai, session: session)
        let latencyMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
        recorder.recordFromResponse(data: data, provider: ai.provider, model: ai.model,
                                    tier: ai.tier, prefixVersion: PromptContext.prefixVersion,
                                    latencyMs: latencyMs)
        return data
    }

    static func message(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else { throw BrainError.badShape("Missing assistant message") }
        if first["finish_reason"] as? String == "length" { throw BrainError.badShape("Reply exceeded its token budget. Try a smaller request.") }
        return message
    }
    static func testConnection() async throws -> String {
        guard let ai = AIConfig.resolve() else { throw BrainError.noKey }
        let data = try await send(["model": ai.model, "messages": [["role": "user", "content": "Reply with OK."]], "max_tokens": 32], ai: ai)
        _ = try message(data)
        return "Connected to \(ai.name) · \(ai.model)"
    }
}
