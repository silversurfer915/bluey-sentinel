import XCTest
@testable import GooglyMac

final class ProviderTests: XCTestCase {
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
}
