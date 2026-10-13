import Foundation

/// How a completed workflow was verified. Only verified completions are observed.
public enum WorkflowVerificationKind: String, Codable, Equatable, Sendable {
    case observableResult
    case savedArtifactReopened
    case explicitUserConfirmed
}

/// One normalized, privacy-safe action. Stores a stable tool name and coarse
/// parameter categories only — never argument values.
public struct NormalizedWorkflowAction: Codable, Equatable, Sendable {
    public let toolName: String
    public let parameterCategories: [String: String]

    public init(toolName: String, parameterCategories: [String: String]) {
        self.toolName = toolName
        self.parameterCategories = parameterCategories
    }
}

/// A verified successful workflow, reduced to normalized structure only.
public struct WorkflowObservation: Codable, Equatable, Sendable {
    public let normalizedIntent: String
    public let actionSequence: [NormalizedWorkflowAction]
    public let verificationKind: WorkflowVerificationKind
    public let completedAt: Date

    public init(normalizedIntent: String,
                actionSequence: [NormalizedWorkflowAction],
                verificationKind: WorkflowVerificationKind,
                completedAt: Date) {
        self.normalizedIntent = normalizedIntent
        self.actionSequence = actionSequence
        self.verificationKind = verificationKind
        self.completedAt = completedAt
    }
}

/// Lifecycle state of a workflow skill. Only `published` skills reach planning.
public enum WorkflowSkillStatus: String, Codable, Equatable, Sendable {
    case proposed
    case published
    case paused
    case rejected
}

/// A local, owner-reviewed workflow skill proposal.
public struct WorkflowSkillProposal: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let title: String
    public let description: String
    public let preconditions: [String]
    public let steps: [String]
    public let evidenceCount: Int
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let status: WorkflowSkillStatus

    public init(id: UUID = UUID(),
                revision: Int,
                title: String,
                description: String,
                preconditions: [String],
                steps: [String],
                evidenceCount: Int,
                firstSeenAt: Date,
                lastSeenAt: Date,
                status: WorkflowSkillStatus) {
        self.id = id
        self.revision = revision
        self.title = title
        self.description = description
        self.preconditions = preconditions
        self.steps = steps
        self.evidenceCount = evidenceCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.status = status
    }

    public func withStatus(_ status: WorkflowSkillStatus) -> WorkflowSkillProposal {
        WorkflowSkillProposal(id: id, revision: revision, title: title, description: description,
                              preconditions: preconditions, steps: steps, evidenceCount: evidenceCount,
                              firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt, status: status)
    }
}
