import XCTest
@testable import GooglyMac

final class ProviderTests: XCTestCase {
    private var tempURL: URL!
    private var tracker: CacheTracker!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("provider_cache_\(UUID().uuidString).sqlite")
        tracker = CacheTracker(store: CacheStore(fileURL: tempURL))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        MockURLProtocol.handler = nil
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        session = nil
        tracker = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + suffix))
        }
        super.tearDown()
    }

    private func resolved(_ provider: AIProvider, model: String, tier: ModelTier = .fast) -> AIConfig.ResolvedProvider {
        AIConfig.ResolvedProvider(provider: provider, name: provider.title,
                                  endpoint: URL(string: "https://example.com/v1/chat/completions")!,
                                  apiKey: "test-key", model: model, supportsVision: false, tier: tier)
    }

    private func respond(_ json: String) {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
    }

    // MARK: - Provider configuration (existing)

    func testAutoPrefersGeminiAndFallsBackToHarbor() {
        let config = ProviderConfiguration(preferred: .auto, customEndpoint: "", customModel: "", customVision: false, allowFallback: true)
        XCTAssertEqual(AIConfig.candidates(configuration: config, keys: [.gemini: "g", .tokenHarbor: "t"]).map(\.provider), [.gemini, .tokenHarbor])
        XCTAssertEqual(AIConfig.candidates(configuration: config, keys: [.tokenHarbor: "t"]).first?.provider, .tokenHarbor)
    }
    func testCustomURLValidationAndCapabilities() {
        var config = ProviderConfiguration(preferred: .custom, customEndpoint: "https://example.com/v1", customModel: "my-model", customVision: true, allowFallback: false)
        let custom = AIConfig.candidates(configuration: config, keys: [.custom: "key"]).first
        XCTAssertEqual(custom?.endpoint.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(custom?.model, "my-model")
        XCTAssertEqual(custom?.supportsVision, true)
        config.customEndpoint = "http://example.com/v1"
        XCTAssertTrue(AIConfig.candidates(configuration: config, keys: [.custom: "key"]).isEmpty)
        config.customEndpoint = "http://localhost:11434/v1"
        XCTAssertNotNil(AIConfig.candidates(configuration: config, keys: [.custom: "key"]).first)
        config.customEndpoint = "https://user:password@example.com/v1"
        XCTAssertTrue(AIConfig.candidates(configuration: config, keys: [.custom: "key"]).isEmpty)
    }
    func testExplicitSelectionDoesNotSilentlyFallback() {
        let config = ProviderConfiguration(preferred: .gemini, customEndpoint: "", customModel: "", customVision: false, allowFallback: false)
        XCTAssertTrue(AIConfig.candidates(configuration: config, keys: [.tokenHarbor: "key"]).isEmpty)
    }

    // MARK: - Request recording

    func testSuccessfulResponseRecordsProviderIdentityAndPrefix() async throws {
        respond(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}"#)
        _ = try await AIClient.sendRecorded(["model": "deepseek-chat"],
                                            ai: resolved(.deepseek, model: "deepseek-chat", tier: .flagship),
                                            session: session, recorder: tracker)

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 1)
        let log = try XCTUnwrap(snapshot.recentLogs.first)
        XCTAssertEqual(log.provider, .deepseek)
        XCTAssertEqual(log.model, "deepseek-chat")
        XCTAssertEqual(log.tier, .flagship)
        XCTAssertEqual(log.prefixVersion, "bluey-prompt-v2")
        XCTAssertEqual(log.usage.evidence, .confirmed)
    }

    func testUnknownUsageStillCreatesARow() async throws {
        respond(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":2000,"completion_tokens":120}}"#)
        _ = try await AIClient.sendRecorded(["model": "gemini-flash"],
                                            ai: resolved(.gemini, model: "gemini-flash"),
                                            session: session, recorder: tracker)

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 1)
        XCTAssertEqual(snapshot.unknownTelemetryRequests, 1)
        XCTAssertNil(snapshot.confirmedHitRate)
    }

    func testNetworkFailureDoesNotRecord() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await AIClient.sendRecorded(["model": "m"], ai: resolved(.custom, model: "m"),
                                                session: session, recorder: tracker)
            XCTFail("Expected the request to throw")
        } catch {}
        XCTAssertEqual(tracker.snapshot().totalRequests, 0)
    }

    func testNonSuccessStatusDoesNotRecord() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("error".utf8))
        }
        do {
            _ = try await AIClient.sendRecorded(["model": "m"], ai: resolved(.custom, model: "m"),
                                                session: session, recorder: tracker)
            XCTFail("Expected the request to throw")
        } catch {}
        XCTAssertEqual(tracker.snapshot().totalRequests, 0)
    }

    func testCancelledRequestDoesNotRecord() async {
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let task = Task { try await AIClient.sendRecorded(["model": "m"], ai: resolved(.custom, model: "m"),
                                                          session: session, recorder: tracker) }
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(tracker.snapshot().totalRequests, 0)
    }

    func testMalformedMessageWithValidUsageIsStillRecorded() async throws {
        respond(#"{"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}"#)
        let data = try await AIClient.sendRecorded(["model": "deepseek-chat"],
                                                   ai: resolved(.deepseek, model: "deepseek-chat"),
                                                   session: session, recorder: tracker)
        XCTAssertThrowsError(try AIClient.message(data))
        XCTAssertEqual(tracker.snapshot().totalRequests, 1,
                       "Valid usage must be counted even when the message shape is malformed")
    }

    @MainActor
    func testAgentLoopRecordsEveryRoundAndKeepsStablePrefixFirst() async throws {
        respond(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":10,"completion_tokens":1,"prompt_cache_hit_tokens":5,"prompt_cache_miss_tokens":5}}"#)

        var round = 0
        var captured: [[[String: Any]]] = []
        let context = PromptContext(stableSystem: "STABLE_PREFIX", dynamicSystem: "DYNAMIC_CONTEXT")
        let initial = PromptContextBuilder.assembleMessages(context: context, history: [],
                                                            userMessage: ["role": "user", "content": "do it"])

        _ = try await AgentRunner(maxTurns: 4).run(messages: initial, vision: false, request: { messages in
            captured.append(messages)
            round += 1
            _ = try await AIClient.sendRecorded(["model": "m"], ai: self.resolved(.deepseek, model: "deepseek-chat"),
                                                session: self.session, recorder: self.tracker)
            if round == 1 {
                let call = AgentCall(id: "c1", name: "computer_click", arguments: "{}")
                return AgentResponse(rawMessage: ["role": "assistant",
                                                  "tool_calls": [["id": "c1", "function": ["name": "computer_click", "arguments": "{}"]]]],
                                     text: nil, calls: [call])
            }
            return AgentResponse(rawMessage: ["role": "assistant", "content": "done"], text: "done", calls: [])
        }, execute: { _ in AgentToolResult(text: "clicked", image: nil) }, progress: { _ in })

        XCTAssertGreaterThanOrEqual(captured.count, 2)
        XCTAssertEqual(tracker.snapshot().totalRequests, captured.count,
                       "Each provider round must get its own telemetry row")
        for messages in captured {
            XCTAssertEqual(messages.first?["content"] as? String, "STABLE_PREFIX")
            XCTAssertEqual(messages.dropFirst().first?["content"] as? String, "DYNAMIC_CONTEXT")
        }
    }
}

/// Minimal URLProtocol mock so request tests never touch the network.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
