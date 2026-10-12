import Foundation

/// Supported AI reasoning providers.
enum AIProvider: String, CaseIterable {
    case auto = "auto"
    case tokenHarbor = "tokenharbor"
    case gemini = "gemini"
    case deepseek = "deepseek"

    var title: String {
        switch self {
        case .auto: return "Auto (Token Harbor for Sentinel, Cloud for General Brain)"
        case .tokenHarbor: return "Token Harbor (DeepSeek V4.1 Flash)"
        case .gemini: return "Google Gemini (gemini-3.1-flash-lite)"
        case .deepseek: return "DeepSeek platform (deepseek-chat)"
        }
    }
}

/// Central configuration and endpoint resolver for AI reasoning across Bluey and the Sentinel.
enum AIConfig {
    // MARK: - Token Harbor
    //
    // The Sentinel's judge. It replaced a local `llama3.2:1b` (Ollama) model, which was measured
    // calling YouTube, Reddit and Steam all "on-task" — it failed in the permissive direction, so
    // the Sentinel never fired. `deepseek-v4.1-flash` scored 6/6 on the same cases at ~1.9s, and
    // unlike any keyword list it can tell a Wave Optics lecture on YouTube from funny cats on
    // YouTube.
    static let tokenHarborEndpoint = URL(string: "https://tokenharbor.ai/v1/chat/completions")!
    static let tokenHarborSentinelModel = "deepseek-v4.1-flash"

    static var tokenHarborKey: String? {
        Keychain.get(.tokenHarbor) ?? ProcessInfo.processInfo.environment["TOKENHARBOR_API_KEY"]
    }

    static let geminiModel = "gemini-3.1-flash-lite"
    static let deepseekModel = "deepseek-chat"

    static let geminiEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    static let deepseekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    static var geminiKey: String? {
        Keychain.get(.gemini) ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
    }

    static var deepseekKey: String? {
        Keychain.get(.deepseek) ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
    }

    static var hasAnyKey: Bool {
        tokenHarborKey != nil || geminiKey != nil || deepseekKey != nil
    }

    struct ResolvedProvider {
        let provider: AIProvider
        let name: String
        let endpoint: URL
        let apiKey: String
        let model: String
        let supportsVision: Bool
    }

    /// The Sentinel's judge. Token Harbor's DeepSeek V4.1 Flash when a key is present; otherwise
    /// any other cloud key the user has configured, so the feature never silently stops working.
    static func resolveForSentinel() -> ResolvedProvider? {
        if let key = tokenHarborKey, !key.isEmpty {
            return ResolvedProvider(
                provider: .tokenHarbor,
                name: "Token Harbor (deepseek-v4.1-flash)",
                endpoint: tokenHarborEndpoint,
                apiKey: key,
                model: tokenHarborSentinelModel,
                supportsVision: false
            )
        }
        if let key = geminiKey, !key.isEmpty {
            return ResolvedProvider(
                provider: .gemini, name: "Gemini", endpoint: geminiEndpoint,
                apiKey: key, model: geminiModel, supportsVision: true
            )
        }
        if let key = deepseekKey, !key.isEmpty {
            return ResolvedProvider(
                provider: .deepseek, name: "DeepSeek", endpoint: deepseekEndpoint,
                apiKey: key, model: deepseekModel, supportsVision: false
            )
        }
        return nil
    }

    /// Resolves the active AI provider based on user settings and available keys.
    /// Gemini (gemini-3.1-flash-lite) is preferred by default for its speed, low cost, and multimodal vision.
    static func resolve() -> ResolvedProvider? {
        let preferred = Settings.shared.aiProvider

        switch preferred {
        case .tokenHarbor:
            if let key = tokenHarborKey {
                return ResolvedProvider(
                    provider: .tokenHarbor,
                    name: "Token Harbor",
                    endpoint: tokenHarborEndpoint,
                    apiKey: key,
                    model: tokenHarborSentinelModel,
                    supportsVision: false
                )
            }
        case .gemini:
            if let key = geminiKey {
                return ResolvedProvider(
                    provider: .gemini,
                    name: "Gemini",
                    endpoint: geminiEndpoint,
                    apiKey: key,
                    model: geminiModel,
                    supportsVision: true
                )
            }
        case .deepseek:
            if let key = deepseekKey {
                return ResolvedProvider(
                    provider: .deepseek,
                    name: "DeepSeek",
                    endpoint: deepseekEndpoint,
                    apiKey: key,
                    model: deepseekModel,
                    supportsVision: false
                )
            }
        case .auto:
            // Token Harbor is the Sentinel's judge, so when it is available it is also the sensible
            // default for the conversational brain.
            if let key = tokenHarborKey {
                return ResolvedProvider(
                    provider: .tokenHarbor,
                    name: "Token Harbor",
                    endpoint: tokenHarborEndpoint,
                    apiKey: key,
                    model: tokenHarborSentinelModel,
                    supportsVision: false
                )
            }
            if let key = geminiKey {
                return ResolvedProvider(
                    provider: .gemini,
                    name: "Gemini",
                    endpoint: geminiEndpoint,
                    apiKey: key,
                    model: geminiModel,
                    supportsVision: true
                )
            } else if let key = deepseekKey {
                return ResolvedProvider(
                    provider: .deepseek,
                    name: "DeepSeek",
                    endpoint: deepseekEndpoint,
                    apiKey: key,
                    model: deepseekModel,
                    supportsVision: false
                )
            }
        }

        // Fallback: if the preferred provider has no key, use whichever key is available.
        if let key = tokenHarborKey {
            return ResolvedProvider(
                provider: .tokenHarbor, name: "Token Harbor", endpoint: tokenHarborEndpoint,
                apiKey: key, model: tokenHarborSentinelModel, supportsVision: false
            )
        }
        if let key = geminiKey {
            return ResolvedProvider(
                provider: .gemini,
                name: "Gemini",
                endpoint: geminiEndpoint,
                apiKey: key,
                model: geminiModel,
                supportsVision: true
            )
        }
        if let key = deepseekKey {
            return ResolvedProvider(
                provider: .deepseek,
                name: "DeepSeek",
                endpoint: deepseekEndpoint,
                apiKey: key,
                model: deepseekModel,
                supportsVision: false
            )
        }

        // Nothing was usable. The Sentinel itself can still run if any provider resolves, so try that
        // before giving up entirely.
        return resolveForSentinel()
    }
}
