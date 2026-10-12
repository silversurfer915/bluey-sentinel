import XCTest
@testable import GooglyMac
final class PolicyTests: XCTestCase {
    func testConsequentialActionsRequireRealConfirmation() {
        XCTAssertTrue(ActionPolicy.requiresConfirmation(name: "click", label: "Send message", arguments: [:]))
        XCTAssertTrue(ActionPolicy.requiresConfirmation(name: "click", label: "that spot", arguments: [:]))
        XCTAssertTrue(ActionPolicy.requiresConfirmation(name: "press_keys", label: "", arguments: ["keys": "cmd+w"]))
        XCTAssertTrue(ActionPolicy.requiresConfirmation(name: "type_text", label: "", arguments: ["text": "hello\n"]))
        XCTAssertFalse(ActionPolicy.requiresConfirmation(name: "click", label: "Next page", arguments: [:]))
    }
    func testServiceErrorsNeverEchoSecrets() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ErrorProtocol.self]
        let ai = AIConfig.ResolvedProvider(provider: .custom, name: "test", endpoint: URL(string: "https://example.com/v1/chat/completions")!, apiKey: "secret-key", model: "model", supportsVision: false)
        do {
            _ = try await AIClient.send(["model": "model"], ai: ai, session: URLSession(configuration: config))
            XCTFail("expected failure")
        } catch { XCTAssertFalse(error.localizedDescription.contains("secret-key")) }
    }
}
private final class ErrorProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("secret-key".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
