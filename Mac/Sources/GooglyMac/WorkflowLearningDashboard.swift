import SwiftUI

/// Testable presentation logic for the Workflow Learning dashboard.
public struct WorkflowLearningModel {
    public let proposals: [WorkflowSkillProposal]

    public init(proposals: [WorkflowSkillProposal]) {
        self.proposals = proposals
    }

    public var candidates: [WorkflowSkillProposal] {
        proposals.filter { $0.status == .proposed }.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    public var active: [WorkflowSkillProposal] {
        proposals.filter { $0.status == .published || $0.status == .paused }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    public var rejectedCount: Int {
        proposals.filter { $0.status == .rejected }.count
    }

    public func statusLabel(_ status: WorkflowSkillStatus) -> String {
        switch status {
        case .proposed: return "Proposed"
        case .published: return "Published"
        case .paused: return "Paused"
        case .rejected: return "Rejected"
        }
    }
}

/// Owns workflow-learning state and owner lifecycle actions.
@MainActor
public final class WorkflowLearningViewModel: ObservableObject {
    @Published public private(set) var proposals: [WorkflowSkillProposal]

    private let store: WorkflowLearningStore?

    public init(store: WorkflowLearningStore = .shared) {
        self.store = store
        self.proposals = store.proposals()
        store.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Fixture-only initializer: no store, no side effects.
    public init(fixtureProposals: [WorkflowSkillProposal]) {
        self.store = nil
        self.proposals = fixtureProposals
    }

    public var model: WorkflowLearningModel { WorkflowLearningModel(proposals: proposals) }

    public func refresh() { if let store { proposals = store.proposals() } }

    public func publish(_ proposal: WorkflowSkillProposal) { store?.publish(id: proposal.id); refresh() }
    public func reject(_ proposal: WorkflowSkillProposal) { store?.reject(id: proposal.id); refresh() }
    public func pause(_ proposal: WorkflowSkillProposal) { store?.pause(id: proposal.id); refresh() }
    public func resume(_ proposal: WorkflowSkillProposal) { store?.resume(id: proposal.id); refresh() }
    public func delete(_ proposal: WorkflowSkillProposal) { store?.delete(id: proposal.id); refresh() }

    public func edit(_ proposal: WorkflowSkillProposal, title: String, description: String, steps: [String]) {
        store?.editProposal(id: proposal.id, title: title, description: description,
                            preconditions: proposal.preconditions, steps: steps)
        refresh()
    }
}

/// Calm, owner-reviewed workflow learning dashboard.
public struct WorkflowLearningView: View {
    @StateObject private var model: WorkflowLearningViewModel

    public init(store: WorkflowLearningStore? = nil) {
        #if DEBUG
        if UIPreviewFixtures.isActive {
            _model = StateObject(wrappedValue: WorkflowLearningViewModel(fixtureProposals: UIPreviewFixtures.workflowProposals()))
            return
        }
        #endif
        _model = StateObject(wrappedValue: WorkflowLearningViewModel(store: store ?? .shared))
    }

    public var body: some View {
        let dashboard = model.model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                banner
                if dashboard.candidates.isEmpty && dashboard.active.isEmpty {
                    emptyState
                } else {
                    if !dashboard.candidates.isEmpty { candidateSection(dashboard) }
                    if !dashboard.active.isEmpty { activeSection(dashboard) }
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(BlueyTheme.primary)
                Text("Workflow learning").font(.system(size: 12.5, weight: .semibold))
            }
            Text("Bluey notices repeatable workflows it completed successfully and drafts a skill. Nothing runs until you publish it, and every step still passes the normal permission and verification checks.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(2.5)
        }
        .padding(12)
        .background(BlueyTheme.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BlueyTheme.primary.opacity(0.15), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("No workflow proposals yet.").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            Text("Complete the same task successfully a few times and Bluey will draft a skill for your review.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    private func candidateSection(_ dashboard: WorkflowLearningModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proposals awaiting review").font(.system(size: 14, weight: .semibold))
            ForEach(dashboard.candidates) { proposal in
                card(proposal, dashboard: dashboard, isActive: false)
            }
        }
    }

    private func activeSection(_ dashboard: WorkflowLearningModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Published skills").font(.system(size: 14, weight: .semibold))
            ForEach(dashboard.active) { proposal in
                card(proposal, dashboard: dashboard, isActive: true)
            }
        }
    }

    private func card(_ proposal: WorkflowSkillProposal, dashboard: WorkflowLearningModel, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(dashboard.statusLabel(proposal.status))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(proposal.status == .published ? BlueyTheme.success : BlueyTheme.primary)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background((proposal.status == .published ? BlueyTheme.success : BlueyTheme.primary).opacity(0.12), in: Capsule())
                Text("v\(proposal.revision)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
            }

            Text(proposal.title).font(.system(size: 13, weight: .semibold))
            Text(proposal.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(2)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(proposal.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            if !proposal.preconditions.isEmpty {
                Text("Preconditions: " + proposal.preconditions.joined(separator: "; "))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("\(proposal.evidenceCount) verified runs")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text("\(proposal.firstSeenAt.formatted(date: .abbreviated, time: .omitted)) – \(proposal.lastSeenAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()

                if isActive {
                    if proposal.status == .published {
                        Button("Pause") { model.pause(proposal) }.controlSize(.small)
                    } else {
                        Button("Resume") { model.resume(proposal) }.controlSize(.small)
                    }
                    Button("Delete", role: .destructive) { model.delete(proposal) }.controlSize(.small)
                } else {
                    Button("Publish") { model.publish(proposal) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Reject") { model.reject(proposal) }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
