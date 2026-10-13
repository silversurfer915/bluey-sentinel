import Foundation

/// The system prompt split into a byte-stable prefix and per-request context.
/// Prefix reuse depends on `stableSystem` being identical for the same mode and
/// tool capability set; only `dynamicSystem` may change between requests.
public struct PromptContext: Equatable, Sendable {
    public static let prefixVersion = "bluey-prompt-v2"
    public let stableSystem: String
    public let dynamicSystem: String?

    public init(stableSystem: String, dynamicSystem: String?) {
        self.stableSystem = stableSystem
        self.dynamicSystem = dynamicSystem
    }
}

/// Everything needed to compose a prompt context. Static guide text is passed
/// in so the builder stays pure and deterministic.
public struct PromptContextInput: Sendable {
    public let personality: String
    public let isConversational: Bool
    public let computerControl: Bool
    public let conversationalGuide: String
    public let toolGuide: String
    public let computerGuide: String
    public let autonomyInstruction: String
    public let studyInstruction: String?
    public let learnerContext: String?
    public let memoryContext: String?
    public let liveContext: String?

    public init(personality: String,
                isConversational: Bool,
                computerControl: Bool,
                conversationalGuide: String,
                toolGuide: String,
                computerGuide: String,
                autonomyInstruction: String,
                studyInstruction: String? = nil,
                learnerContext: String? = nil,
                memoryContext: String? = nil,
                liveContext: String? = nil) {
        self.personality = personality
        self.isConversational = isConversational
        self.computerControl = computerControl
        self.conversationalGuide = conversationalGuide
        self.toolGuide = toolGuide
        self.computerGuide = computerGuide
        self.autonomyInstruction = autonomyInstruction
        self.studyInstruction = studyInstruction
        self.learnerContext = learnerContext
        self.memoryContext = memoryContext
        self.liveContext = liveContext
    }
}

/// Composes stable and dynamic system text, and assembles the final message
/// order: stable system → dynamic system → history → user.
public struct PromptContextBuilder: Sendable {
    public init() {}

    public func build(_ input: PromptContextInput) -> PromptContext {
        var stable = input.personality
        if input.isConversational {
            stable += "\n\n" + input.conversationalGuide
        } else {
            stable += "\n\n" + input.toolGuide
            if input.computerControl {
                stable += "\n\n" + input.computerGuide
            }
        }

        let dynamicSections = [
            input.autonomyInstruction,
            input.studyInstruction ?? "",
            input.learnerContext ?? "",
            input.memoryContext ?? "",
            input.liveContext ?? "",
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let dynamic = dynamicSections.isEmpty ? nil : dynamicSections.joined(separator: "\n\n")
        return PromptContext(stableSystem: stable, dynamicSystem: dynamic)
    }

    /// Builds the provider message array in the required order.
    public static func assembleMessages(context: PromptContext,
                                        history: [[String: Any]],
                                        userMessage: [String: Any]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": context.stableSystem]]
        if let dynamic = context.dynamicSystem, !dynamic.isEmpty {
            messages.append(["role": "system", "content": dynamic])
        }
        messages.append(contentsOf: history)
        messages.append(userMessage)
        return messages
    }

    /// Keeps tool schemas in a deterministic name order.
    public static func sortedTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        func name(_ tool: [String: Any]) -> String {
            (tool["function"] as? [String: Any])?["name"] as? String ?? ""
        }
        return tools.sorted { name($0) < name($1) }
    }
}
