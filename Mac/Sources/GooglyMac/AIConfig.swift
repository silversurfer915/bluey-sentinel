import Foundation

public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case auto, gemini, tokenHarbor = "tokenharbor", deepseek, custom
    public var title: String {
        switch self {
        case .auto: return "Automatic · Gemini first"
        case .gemini: return "Gemini 3.1 Flash Lite"
        case .tokenHarbor: return "Token Harbor"
        case .deepseek: return "DeepSeek"
        case .custom: return "Custom provider"
        }
    }
}

public enum ModelTier: String, CaseIterable, Codable, Sendable {
    case fast = "fast"
    case flagship = "flagship"

    public var title: String {
        switch self {
        case .fast: return "Fast · Quick answers & chat"
        case .flagship: return "Flagship · Computer-use & planning"
        }
    }

    public var badge: String {
        switch self {
        case .fast: return "⚡ Fast"
        case .flagship: return "🧠 Flagship"
        }
    }
}

public enum ModelRoutingMode: String, CaseIterable, Codable {
    case auto = "auto"
    case alwaysFast = "alwaysFast"
    case alwaysFlagship = "alwaysFlagship"

    public var title: String {
        switch self {
        case .auto: return "Auto-route by task & overrides"
        case .alwaysFast: return "Always Fast model"
        case .alwaysFlagship: return "Always Flagship model"
        }
    }
}

public enum TaskIntent: String, Codable, Equatable, Sendable {
    case conversation
    case computerUse
}

public enum ModelClassifier {
    public struct Decision: Equatable {
        public let tier: ModelTier
        public let reason: String
        public let overridden: Bool
        public let cleanedPrompt: String
        public let intent: TaskIntent

        public init(tier: ModelTier, reason: String, overridden: Bool, cleanedPrompt: String, intent: TaskIntent = .conversation) {
            self.tier = tier
            self.reason = reason
            self.overridden = overridden
            self.cleanedPrompt = cleanedPrompt
            self.intent = intent
        }
    }

    /// Determines whether a prompt asks to interact with the computer/screen or is a conversational chatbot query.
    public static func isComputerUsePrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Explicit screen inspection / awareness
        let screenPhrases = [
            "on my screen", "on the screen", "on screen",
            "look at my screen", "look at the screen", "look at screen",
            "see my screen", "see the screen", "check my screen", "check the screen",
            "what's on my screen", "what is on my screen", "what is on screen",
            "read my screen", "read the screen", "read this window", "read this screen",
            "on this page", "on this website", "in this window", "in this app",
            "this button", "this link", "this field", "this error",
            "point at", "point to", "find on screen", "search screen"
        ]
        for phrase in screenPhrases {
            if lower.contains(phrase) { return true }
        }

        // 2. Direct GUI action commands
        let actionPhrases = [
            "click", "double click", "right click", "tap on",
            "type into", "type in", "type text", "type my",
            "press key", "press keys", "press return", "press enter", "press cmd", "hit enter",
            "scroll down", "scroll up", "scroll to", "scroll page",
            "drag and drop", "drag from", "drag to",
            "open app", "launch app", "quit app", "close window", "minimize window",
            "open chrome", "open safari", "open xcode", "open terminal", "open finder",
            "switch to chrome", "switch to safari", "switch to xcode", "switch to terminal",
            "navigate to"
        ]
        for action in actionPhrases {
            if lower.contains(action) { return true }
        }

        // 3. Single action verbs as standalone words
        let singleActionWords = ["click", "scroll", "drag"]
        for word in singleActionWords {
            if matchesWord(word, in: lower) { return true }
        }

        if matchesWord("type", in: lower) && !lower.contains("type of") && !lower.contains("what type") {
            return true
        }

        if matchesWord("open", in: lower) {
            let openTargets = ["app", "window", "tab", "browser", "safari", "chrome", "xcode", "file", "folder", "terminal", "notes", "link", "url"]
            for target in openTargets {
                if lower.contains(target) { return true }
            }
        }

        // 4. Focus Sentinel / session control
        let focusPhrases = [
            "start focus", "lock window", "lock target", "pause focus", "resume focus", "check focus"
        ]
        for phrase in focusPhrases {
            if lower.contains(phrase) { return true }
        }

        return false
    }

    public static func classify(prompt: String, mode: ModelRoutingMode = .auto) -> Decision {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let isComputer = isComputerUsePrompt(trimmed)
        let intent: TaskIntent = isComputer ? .computerUse : .conversation

        // 1. Explicit per-message override keywords
        let flagshipPatterns = [
            "use big brain for this", "use big brain", "big brain",
            "use flagship for this", "use flagship", "flagship model", "pro model",
            "flagship tier", "use pro"
        ]
        for pattern in flagshipPatterns {
            if lower.contains(pattern) {
                let cleaned = removePattern(pattern, from: trimmed)
                return Decision(tier: .flagship, reason: "User override ('\(pattern)')", overridden: true, cleanedPrompt: cleaned, intent: intent)
            }
        }

        let fastPatterns = [
            "use fast model for this", "use fast model", "fast model",
            "fast brain", "quick answer", "use lite", "lite model"
        ]
        for pattern in fastPatterns {
            if lower.contains(pattern) {
                let cleaned = removePattern(pattern, from: trimmed)
                return Decision(tier: .fast, reason: "User override ('\(pattern)')", overridden: true, cleanedPrompt: cleaned, intent: intent)
            }
        }

        // 2. Routing mode enforcement if not auto
        if mode == .alwaysFast {
            return Decision(tier: .fast, reason: "Settings routing set to Always Fast", overridden: false, cleanedPrompt: trimmed, intent: intent)
        }
        if mode == .alwaysFlagship {
            return Decision(tier: .flagship, reason: "Settings routing set to Always Flagship", overridden: false, cleanedPrompt: trimmed, intent: intent)
        }

        // 3. Task Classification Heuristics
        // Computer-use / Screen understanding / Multi-step planning -> Flagship
        let flagshipIndicators = [
            "click", "press", "type", "drag", "scroll", "open", "launch",
            "screen", "window", "look at", "inspect", "find on", "read this",
            "plan", "multi-step", "steps", "solve", "code", "debug",
            "analyze", "write code", "search screen", "ocr", "browser", "tab"
        ]
        for indicator in flagshipIndicators {
            if matchesWord(indicator, in: lower) {
                return Decision(tier: .flagship, reason: "Screen action or reasoning ('\(indicator)')", overridden: false, cleanedPrompt: trimmed, intent: intent)
            }
        }

        // Casual conversation / jokes / quick questions -> Fast
        return Decision(tier: .fast, reason: "Quick query / casual conversation", overridden: false, cleanedPrompt: trimmed, intent: intent)
    }

    private static func removePattern(_ pattern: String, from text: String) -> String {
        var result = text
        if let range = result.range(of: pattern, options: .caseInsensitive) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.-:")))
    }

    private static func matchesWord(_ word: String, in text: String) -> Bool {
        if word.contains(" ") {
            return text.contains(word)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
        return text.contains(word)
    }
}

public struct ProviderConfiguration {
    public var preferred: AIProvider
    public var customEndpoint: String
    public var customModel: String
    public var customVision: Bool
    public var allowFallback: Bool
}

/// Shared routing for conversation, focus judgments, and research.
public enum AIConfig {
    public static let geminiModel = "gemini-3.1-flash-lite"
    public static let deepseekModel = "deepseek-chat"
    public static let tokenHarborSentinelModel = "deepseek-v4.1-flash"
    public static let geminiEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    public static let tokenHarborEndpoint = URL(string: "https://tokenharbor.ai/v1/chat/completions")!
    public static let deepseekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    public static var geminiKey: String? { Keychain.get(.gemini) ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] }
    public static var tokenHarborKey: String? { Keychain.get(.tokenHarbor) ?? ProcessInfo.processInfo.environment["TOKENHARBOR_API_KEY"] }
    public static var deepseekKey: String? { Keychain.get(.deepseek) ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] }

    public struct ResolvedProvider {
        public let provider: AIProvider
        public let name: String
        public let endpoint: URL
        public let apiKey: String
        public let model: String
        public let supportsVision: Bool
        public let tier: ModelTier

        public init(provider: AIProvider, name: String, endpoint: URL, apiKey: String, model: String, supportsVision: Bool, tier: ModelTier = .fast) {
            self.provider = provider
            self.name = name
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.model = model
            self.supportsVision = supportsVision
            self.tier = tier
        }
    }

    public static var configuration: ProviderConfiguration {
        let s = Settings.shared
        return ProviderConfiguration(preferred: s.aiProvider, customEndpoint: s.customEndpoint,
                                     customModel: s.customModel, customVision: s.customVision,
                                     allowFallback: s.providerFallback)
    }

    public static var configuredKeys: [AIProvider: String] {
        var keys: [AIProvider: String] = [:]
        keys[.gemini] = geminiKey
        keys[.tokenHarbor] = tokenHarborKey
        keys[.deepseek] = deepseekKey
        keys[.custom] = Keychain.get(.custom)
        return keys
    }

    public static func endpoint(_ input: String) -> URL? {
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

    public static func resolveProvider(_ provider: AIProvider, tier: ModelTier, modelOverride: String? = nil, keys: [AIProvider: String] = configuredKeys) -> ResolvedProvider? {
        guard let key = keys[provider]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        let s = Settings.shared
        switch provider {
        case .gemini:
            let model = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? modelOverride! : geminiModel
            return ResolvedProvider(provider: provider, name: "Gemini", endpoint: geminiEndpoint, apiKey: key, model: model, supportsVision: true, tier: tier)
        case .tokenHarbor:
            let model = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? modelOverride! : tokenHarborSentinelModel
            return ResolvedProvider(provider: provider, name: "Token Harbor", endpoint: tokenHarborEndpoint, apiKey: key, model: model, supportsVision: false, tier: tier)
        case .deepseek:
            let model = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? modelOverride! : deepseekModel
            return ResolvedProvider(provider: provider, name: "DeepSeek", endpoint: deepseekEndpoint, apiKey: key, model: model, supportsVision: false, tier: tier)
        case .custom:
            let endpointStr = s.customEndpoint
            let modelStr = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? modelOverride! : s.customModel
            guard let url = endpoint(endpointStr), !modelStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ResolvedProvider(provider: provider, name: "Custom · \(modelStr)", endpoint: url, apiKey: key, model: modelStr, supportsVision: s.customVision, tier: tier)
        case .auto:
            return nil
        }
    }

    public static func candidates(configuration c: ProviderConfiguration, keys: [AIProvider: String]) -> [ResolvedProvider] {
        let defaults: [AIProvider] = [.gemini, .tokenHarbor, .deepseek]
        let order = c.preferred == .auto ? defaults : [c.preferred] + (c.allowFallback ? defaults.filter { $0 != c.preferred } : [])
        return order.compactMap { provider in
            guard let key = keys[provider]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
            switch provider {
            case .gemini: return ResolvedProvider(provider: provider, name: provider.title, endpoint: geminiEndpoint, apiKey: key, model: geminiModel, supportsVision: true, tier: .fast)
            case .tokenHarbor: return ResolvedProvider(provider: provider, name: provider.title, endpoint: tokenHarborEndpoint, apiKey: key, model: tokenHarborSentinelModel, supportsVision: false, tier: .fast)
            case .deepseek: return ResolvedProvider(provider: provider, name: provider.title, endpoint: deepseekEndpoint, apiKey: key, model: deepseekModel, supportsVision: false, tier: .flagship)
            case .custom:
                guard let url = endpoint(c.customEndpoint), !c.customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ResolvedProvider(provider: provider, name: "Custom · \(c.customModel)", endpoint: url, apiKey: key, model: c.customModel, supportsVision: c.customVision, tier: .flagship)
            case .auto: return nil
            }
        }
    }

    /// Resolves provider specifically for the requested model tier (.fast or .flagship).
    public static func resolve(tier: ModelTier) -> ResolvedProvider? {
        let s = Settings.shared
        let keys = configuredKeys
        let preferredProvider = tier == .flagship ? s.flagshipProvider : s.fastProvider
        let preferredModel = tier == .flagship ? s.flagshipCustomModel : s.fastCustomModel

        if preferredProvider != .auto,
           let resolved = resolveProvider(preferredProvider, tier: tier, modelOverride: preferredModel, keys: keys) {
            return resolved
        }

        // Auto / Fallback strategy
        if tier == .flagship {
            // Flagship priority: DeepSeek -> Gemini -> TokenHarbor
            let flagshipOrder: [AIProvider] = [.deepseek, .gemini, .tokenHarbor, .custom]
            for p in flagshipOrder {
                if let resolved = resolveProvider(p, tier: .flagship, modelOverride: p == .deepseek ? deepseekModel : nil, keys: keys) {
                    return resolved
                }
            }
        } else {
            // Fast priority: Gemini -> TokenHarbor -> DeepSeek
            let fastOrder: [AIProvider] = [.gemini, .tokenHarbor, .deepseek, .custom]
            for p in fastOrder {
                if let resolved = resolveProvider(p, tier: .fast, modelOverride: p == .gemini ? geminiModel : nil, keys: keys) {
                    return resolved
                }
            }
        }

        return candidates(configuration: configuration, keys: keys).first
    }

    public static func resolve() -> ResolvedProvider? {
        return resolve(tier: .fast)
    }

    public static func resolveForSentinel() -> ResolvedProvider? {
        // Sentinel uses fast model (Gemini or Token Harbor)
        return resolve(tier: .fast)
    }

    public static var hasAnyKey: Bool { resolve() != nil }
}
