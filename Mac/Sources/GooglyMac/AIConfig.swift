import Foundation

enum AIProvider: String, CaseIterable {
    case auto, gemini, tokenHarbor = "tokenharbor", deepseek, custom
    var title: String {
        switch self {
        case .auto: return "Automatic · Gemini first"
        case .gemini: return "Gemini 3.1 Flash Lite"
        case .tokenHarbor: return "Token Harbor"
        case .deepseek: return "DeepSeek"
        case .custom: return "Custom provider"
        }
    }
}

struct ProviderConfiguration {
    var preferred: AIProvider
    var customEndpoint: String
    var customModel: String
    var customVision: Bool
    var allowFallback: Bool
}

/// Shared routing for conversation, focus judgments, and research.
enum AIConfig {
    static let geminiModel = "gemini-3.1-flash-lite"
    static let deepseekModel = "deepseek-chat"
    static let tokenHarborSentinelModel = "deepseek-v4.1-flash"
    static let geminiEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    static let tokenHarborEndpoint = URL(string: "https://tokenharbor.ai/v1/chat/completions")!
    static let deepseekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static var geminiKey: String? { Keychain.get(.gemini) ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] }
    static var tokenHarborKey: String? { Keychain.get(.tokenHarbor) ?? ProcessInfo.processInfo.environment["TOKENHARBOR_API_KEY"] }
    static var deepseekKey: String? { Keychain.get(.deepseek) ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] }

    struct ResolvedProvider {
        let provider: AIProvider
        let name: String
        let endpoint: URL
        let apiKey: String
        let model: String
        let supportsVision: Bool
    }
    static var configuration: ProviderConfiguration {
        let s = Settings.shared
        return ProviderConfiguration(preferred: s.aiProvider, customEndpoint: s.customEndpoint,
                                     customModel: s.customModel, customVision: s.customVision,
                                     allowFallback: s.providerFallback)
    }
    static var configuredKeys: [AIProvider: String] {
        var keys: [AIProvider: String] = [:]
        keys[.gemini] = geminiKey
        keys[.tokenHarbor] = tokenHarborKey
        keys[.deepseek] = deepseekKey
        keys[.custom] = Keychain.get(.custom)
        return keys
    }
    static func endpoint(_ input: String) -> URL? {
        guard var url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { return nil }
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = "/" + url.path
        if !url.path.hasSuffix("/chat/completions") {
            url.path = url.path == "/" ? "/v1/chat/completions" : url.path + "/chat/completions"
        }
        return url.url
    }
    static func candidates(configuration c: ProviderConfiguration, keys: [AIProvider: String]) -> [ResolvedProvider] {
        let defaults: [AIProvider] = [.gemini, .tokenHarbor, .deepseek]
        let order = c.preferred == .auto ? defaults : [c.preferred] + (c.allowFallback ? defaults.filter { $0 != c.preferred } : [])
        return order.compactMap { provider in
            guard let key = keys[provider]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
            switch provider {
            case .gemini: return ResolvedProvider(provider: provider, name: provider.title, endpoint: geminiEndpoint, apiKey: key, model: geminiModel, supportsVision: true)
            case .tokenHarbor: return ResolvedProvider(provider: provider, name: provider.title, endpoint: tokenHarborEndpoint, apiKey: key, model: tokenHarborSentinelModel, supportsVision: false)
            case .deepseek: return ResolvedProvider(provider: provider, name: provider.title, endpoint: deepseekEndpoint, apiKey: key, model: deepseekModel, supportsVision: false)
            case .custom:
                guard let url = endpoint(c.customEndpoint), !c.customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ResolvedProvider(provider: provider, name: "Custom · \(c.customModel)", endpoint: url, apiKey: key, model: c.customModel, supportsVision: c.customVision)
            case .auto: return nil
            }
        }
    }
    static func resolve() -> ResolvedProvider? { candidates(configuration: configuration, keys: configuredKeys).first }
    static func resolveForSentinel() -> ResolvedProvider? { resolve() }
    static var hasAnyKey: Bool { resolve() != nil }
}
