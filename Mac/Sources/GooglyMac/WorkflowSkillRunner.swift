import Foundation

/// Injects approved skills into planning as bounded suggestions only.
///
/// A skill can never grant permissions, skip approvals, suppress Emergency Stop,
/// or run a stored macro. The agent still observes current state, dispatches each
/// action through the normal gateway/policy, and verifies each result.
public struct WorkflowSkillRunner: Sendable {
    public init() {}

    public static let maxSkills = 3

    /// Returns a bounded dynamic-context section, or nil when nothing matches.
    /// Only published skills are ever considered; proposed/rejected/paused are ignored.
    public func plannerContext(for request: String,
                               skills: [WorkflowSkillProposal],
                               limit: Int = maxSkills) -> String? {
        let matches = skills
            .filter { $0.status == .published }
            .filter { matches(request: request, skill: $0) }
        guard !matches.isEmpty else { return nil }

        var lines = ["Known workflows (suggestions only; re-observe and verify every step):"]
        for skill in matches.prefix(limit) {
            lines.append("- \(skill.title): \(skill.steps.joined(separator: " → "))")
        }
        return lines.joined(separator: "\n")
    }

    func matches(request: String, skill: WorkflowSkillProposal) -> Bool {
        let requestTokens = Set(MemoryTokenizer.tokenize(request))
        guard !requestTokens.isEmpty else { return false }
        let skillText = ([skill.title, skill.description] + skill.steps + skill.preconditions).joined(separator: " ")
        let skillTokens = Set(MemoryTokenizer.tokenize(skillText))
        return !requestTokens.intersection(skillTokens).isEmpty
    }
}
