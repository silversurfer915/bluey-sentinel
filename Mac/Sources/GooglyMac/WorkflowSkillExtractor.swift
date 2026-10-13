import Foundation
import CryptoKit

/// Deterministic, privacy-safe workflow extraction.
///
/// It stores only normalized tool names and coarse parameter categories. Original
/// prompts, URLs, file paths, window titles, tool arguments, images, and results
/// are discarded and never reach the store.
public struct WorkflowSkillExtractor: Sendable {
    public init() {}

    public static let minimumEvidence = 3
    public static let minimumDistinctDays = 2

    // MARK: - Eligibility

    /// Produces an observation only for an explicitly verified `.completed`
    /// workflow. Failed, cancelled, unfinished, or conversation-only turns yield nil.
    public func observation(intent: String,
                            calls: [(name: String, arguments: [String: Any])],
                            verificationKind: WorkflowVerificationKind?,
                            outcome: VerifiedTaskOutcome?,
                            completedAt: Date = Date()) -> WorkflowObservation? {
        guard let verificationKind else { return nil }
        guard case .completed = outcome else { return nil }

        let actions = normalizedActions(from: calls)
        guard !actions.isEmpty else { return nil }

        let normalizedIntent = Self.normalizedIntent(intent)
        return WorkflowObservation(normalizedIntent: normalizedIntent,
                                   actionSequence: actions,
                                   verificationKind: verificationKind,
                                   completedAt: completedAt)
    }

    // MARK: - Normalization

    public func normalizedActions(from calls: [(name: String, arguments: [String: Any])]) -> [NormalizedWorkflowAction] {
        calls.map { NormalizedWorkflowAction(toolName: $0.name, parameterCategories: Self.categories(for: $0.name)) }
    }

    /// Maps a tool to a fixed set of coarse categories. Argument values are never read.
    public static func categories(for toolName: String) -> [String: String] {
        categoryTable[toolName] ?? ["category": "other"]
    }

    /// Reduces a request to one of a small set of coarse buckets so no original
    /// words are ever persisted.
    public static func normalizedIntent(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("research") || lower.contains("web") || lower.contains("look up") || lower.contains("search") {
            return "web-research"
        }
        if lower.contains("file") || lower.contains("folder") || lower.contains("download") {
            return "file-management"
        }
        if lower.contains("focus") || lower.contains("study") {
            return "focus"
        }
        if lower.contains("click") || lower.contains("open") || lower.contains("type")
            || lower.contains("computer") || lower.contains("browser") {
            return "computer-use"
        }
        return "general"
    }

    // MARK: - Thresholding

    /// Groups observations by normalized intent and ordered action sequence, and
    /// emits one proposal when the evidence threshold is met.
    public func proposals(from observations: [WorkflowObservation]) -> [WorkflowSkillProposal] {
        var groups: [String: [WorkflowObservation]] = [:]
        for observation in observations {
            groups[Self.signature(observation), default: []].append(observation)
        }

        var result: [WorkflowSkillProposal] = []
        for (signature, group) in groups {
            guard group.count >= Self.minimumEvidence else { continue }
            let dates = group.map(\.completedAt).sorted()
            let distinctDays = Set(dates.map { Calendar.current.startOfDay(for: $0) }).count
            guard distinctDays >= Self.minimumDistinctDays else { continue }

            let actions = group[0].actionSequence
            let intent = group[0].normalizedIntent
            result.append(WorkflowSkillProposal(
                id: Self.stableID(for: signature),
                revision: 1,
                title: Self.title(intent: intent, actions: actions),
                description: Self.describe(intent: intent, actions: actions, count: group.count),
                preconditions: Self.preconditions(for: actions),
                steps: actions.map(Self.step),
                evidenceCount: group.count,
                firstSeenAt: dates.first ?? Date(),
                lastSeenAt: dates.last ?? Date(),
                status: .proposed
            ))
        }
        return result.sorted { $0.title < $1.title }
    }

    /// A deterministic id derived from a workflow signature, so regenerated
    /// proposals dedupe without storing original content.
    static func stableID(for signature: String) -> UUID {
        let digest = SHA256.hash(data: Data(signature.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func signature(_ observation: WorkflowObservation) -> String {
        let actions = observation.actionSequence.map { action -> String in
            let categories = action.parameterCategories
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            return "\(action.toolName)[\(categories)]"
        }.joined(separator: ">")
        return "\(observation.normalizedIntent)|\(actions)"
    }

    // MARK: - Human-readable proposal text

    private static func intentLabel(_ intent: String) -> String {
        switch intent {
        case "web-research": return "Web research"
        case "file-management": return "File management"
        case "focus": return "Focus session"
        case "computer-use": return "Computer use"
        default: return "General workflow"
        }
    }

    static func title(intent: String, actions: [NormalizedWorkflowAction]) -> String {
        "\(intentLabel(intent)) · \(actions.count) steps"
    }

    static func describe(intent: String, actions: [NormalizedWorkflowAction], count: Int) -> String {
        "A \(intentLabel(intent).lowercased()) routine of \(actions.count) verified steps, seen \(count) times. Bluey still re-observes and verifies each step before acting."
    }

    static func step(_ action: NormalizedWorkflowAction) -> String {
        let hint = action.parameterCategories
            .sorted { $0.key < $1.key }
            .map { $0.value }
            .joined(separator: ", ")
        return hint.isEmpty ? action.toolName : "\(action.toolName) — \(hint)"
    }

    static func preconditions(for actions: [NormalizedWorkflowAction]) -> [String] {
        var result = ["Re-observe the current screen before acting"]
        if actions.contains(where: { $0.parameterCategories["destination"] == "browser" }) {
            result.append("The destination page must be reachable")
        }
        if actions.contains(where: { $0.parameterCategories["fileAction"] != nil }) {
            result.append("The referenced workspace files must still exist")
        }
        return result
    }

    private static let categoryTable: [String: [String: String]] = [
        "look_at_screen": ["observation": "screen"],
        "computer_snapshot": ["observation": "screen"],
        "computer_read": ["observation": "screen"],
        "point_at": ["target": "visible-control"],
        "point_at_spot": ["target": "visible-control"],
        "click": ["target": "visible-control"],
        "computer_click": ["target": "visible-control"],
        "type_text": ["target": "text-field"],
        "computer_type": ["target": "text-field"],
        "press_keys": ["input": "keys"],
        "computer_key": ["input": "keys"],
        "scroll": ["motion": "scroll"],
        "computer_scroll": ["motion": "scroll"],
        "drag": ["motion": "drag"],
        "open_app": ["destination": "app"],
        "computer_open_app": ["destination": "app"],
        "open_url": ["destination": "browser"],
        "computer_navigate": ["destination": "browser"],
        "read_web_page": ["research": "page"],
        "web_research": ["research": "web"],
        "computer_list_files": ["fileAction": "list"],
        "computer_read_file": ["fileAction": "read"],
        "computer_write_file": ["fileAction": "write"],
        "computer_run_command": ["command": "shell"],
        "computer_request_help": ["handoff": "human"],
        "computer_request_secret": ["handoff": "secret"],
        "start_focus": ["focus": "start"],
        "focus_control": ["focus": "control"],
        "update_plan": ["planning": "steps"],
    ]
}
