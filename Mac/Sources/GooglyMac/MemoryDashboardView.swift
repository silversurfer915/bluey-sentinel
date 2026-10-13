import SwiftUI

/// Category filter for the Memory dashboard.
public enum MemoryFilter: Hashable {
    case all
    case type(MemoryType)
}

/// Hero metrics for the Memory dashboard.
public struct MemoryDashboardMetrics: Equatable {
    public let total: Int
    public let pinned: Int
    public let learnedThisWeek: Int
    public let recalledThisWeek: Int
}

/// Pure, testable dashboard logic over a list of memories.
public struct MemoryDashboardModel {
    public let items: [MemoryItem]
    public let query: String
    public let filter: MemoryFilter
    public let now: Date

    public init(items: [MemoryItem], query: String = "", filter: MemoryFilter = .all, now: Date = Date()) {
        self.items = items
        self.query = query
        self.filter = filter
        self.now = now
    }

    private static let week: TimeInterval = 7 * 86_400

    public var metrics: MemoryDashboardMetrics {
        MemoryDashboardMetrics(
            total: items.count,
            pinned: items.filter(\.isPinned).count,
            learnedThisWeek: items.filter {
                $0.updatedAt <= now && now.timeIntervalSince($0.updatedAt) <= Self.week
            }.count,
            recalledThisWeek: items.filter {
                guard let recalled = $0.lastRecalledAt else { return false }
                return recalled <= now && now.timeIntervalSince(recalled) <= Self.week
            }.count
        )
    }

    /// Filtered by category and search, newest-first.
    public var filtered: [MemoryItem] {
        var list = items
        if case .type(let type) = filter {
            list = list.filter { $0.type == type }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            list = list.filter {
                $0.content.lowercased().contains(trimmed)
                    || ($0.triggerContext?.lowercased().contains(trimmed) ?? false)
            }
        }
        return list.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    public var recentlyLearned: [MemoryItem] {
        Array(filtered.prefix(5))
    }

    /// A safe, non-numeric confidence label derived from the memory source.
    public func confidenceLabel(for item: MemoryItem) -> String {
        switch item.source {
        case .manual: return "Manual"
        case .explicitProfile, .explicitPreference: return "Explicit"
        case .correction: return "Correction"
        case .taskOutcome: return "Confirmed outcome"
        case .legacy: return "Legacy"
        }
    }

    /// Bounds trigger context so a long user message is never shown in full.
    public func safeTriggerSummary(for item: MemoryItem) -> String? {
        guard let context = item.triggerContext?.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else { return nil }
        return context.count <= 80 ? context : String(context.prefix(77)) + "…"
    }
}

/// Owns Memory dashboard state and store mutations.
@MainActor
public final class MemoryDashboardViewModel: ObservableObject {
    @Published public private(set) var items: [MemoryItem]
    @Published public var query: String = ""
    @Published public var filter: MemoryFilter = .all

    private let store: MemoryStore?

    public init(store: MemoryStore = .shared) {
        self.store = store
        self.items = store.all()
        store.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Fixture-only initializer: no store, no side effects.
    public init(fixtureItems: [MemoryItem]) {
        self.store = nil
        self.items = fixtureItems
    }

    public var model: MemoryDashboardModel {
        MemoryDashboardModel(items: items, query: query, filter: filter)
    }

    public func refresh() { if let store { items = store.all() } }

    public func add(type: MemoryType, content: String, context: String?) {
        store?.addOrUpdate(type: type, content: content, triggerContext: context)
        refresh()
    }

    public func update(id: String, content: String) {
        store?.update(id: id, content: content)
        refresh()
    }

    public func delete(id: String) {
        store?.delete(id: id)
        refresh()
    }

    public func setPinned(id: String, isPinned: Bool) {
        store?.setPinned(id: id, isPinned: isPinned)
        refresh()
    }

    public func forgetEverything() {
        store?.forgetEverything()
        refresh()
    }
}

/// Premium, calm Memory dashboard. Mirrors the Bluey theme and is keyboard reachable.
public struct MemoryDashboardView: View {
    @StateObject private var model: MemoryDashboardViewModel

    @State private var showAdd = false
    @State private var newType: MemoryType = .profile
    @State private var newContent = ""
    @State private var newContext = ""
    @State private var editingID: String?
    @State private var editingContent = ""
    @State private var isConfirmingForget = false

    public init(store: MemoryStore? = nil) {
        #if DEBUG
        if UIPreviewFixtures.isActive {
            _model = StateObject(wrappedValue: MemoryDashboardViewModel(fixtureItems: UIPreviewFixtures.memoryItems))
            return
        }
        #endif
        _model = StateObject(wrappedValue: MemoryDashboardViewModel(store: store ?? .shared))
    }

    public var body: some View {
        let dashboard = model.model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroRow(dashboard.metrics)
                learningBanner
                controls
                if showAdd { addCard }
                searchBar
                cards(dashboard)
                privacyFooter
            }
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Forget all stored memories?", isPresented: $isConfirmingForget) {
            Button("Forget Everything", role: .destructive) {
                model.forgetEverything()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently wipes all profile facts, preferences, corrections, and recall metadata from your Mac.")
        }
    }

    // MARK: Sections

    private func heroRow(_ metrics: MemoryDashboardMetrics) -> some View {
        HStack(spacing: 14) {
            metricCard("Total memories", value: "\(metrics.total)", icon: "brain.head.profile")
            metricCard("Pinned", value: "\(metrics.pinned)", icon: "pin.fill")
            metricCard("Learned this week", value: "\(metrics.learnedThisWeek)", icon: "sparkles")
            metricCard("Recalled this week", value: "\(metrics.recalledThisWeek)", icon: "arrow.triangle.2.circlepath")
        }
    }

    private var learningBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(BlueyTheme.primary)
                Text("Conservative learning").font(.system(size: 12.5, weight: .semibold))
            }
            Text("Bluey saves only explicit facts, preferences, corrections, and verified task outcomes you state. It never saves questions, guesses, quoted text, secrets, or screen content.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(2.5)
        }
        .padding(12)
        .background(BlueyTheme.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BlueyTheme.primary.opacity(0.15), lineWidth: 1))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Category", selection: $model.filter) {
                Text("All Categories").tag(MemoryFilter.all)
                ForEach(MemoryType.allCases, id: \.self) { type in
                    Text(type.title).tag(MemoryFilter.type(type))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            .accessibilityLabel("Filter memories by category")

            Spacer()

            Button {
                showAdd.toggle()
            } label: {
                Label(showAdd ? "Cancel" : "Add Memory", systemImage: showAdd ? "xmark" : "plus")
            }
            .controlSize(.small)
            .accessibilityLabel(showAdd ? "Cancel adding a memory" : "Add a memory manually")

            Button(role: .destructive) {
                isConfirmingForget = true
            } label: {
                Label("Forget Everything", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Forget everything")
        }
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Category", selection: $newType) {
                    ForEach(MemoryType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                TextField("Trigger context (optional)", text: $newContext)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Fact, preference, or correction to remember…", text: $newContent)
                    .textFieldStyle(.roundedBorder)
                Button("Save Memory") {
                    let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    model.add(type: newType, content: trimmed,
                              context: newContext.isEmpty ? nil : newContext)
                    newContent = ""
                    newContext = ""
                    showAdd = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(BlueyTheme.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BlueyTheme.primary.opacity(0.18), lineWidth: 1))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search memories…", text: $model.query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search memories")
            if !model.query.isEmpty {
                Button(action: { model.query = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func cards(_ dashboard: MemoryDashboardModel) -> some View {
        if dashboard.filtered.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !dashboard.recentlyLearned.isEmpty {
                    Text("Recently learned").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(dashboard.filtered) { item in
                    memoryCard(item, dashboard: dashboard)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("Nothing saved yet.").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            Text("Teach Bluey explicitly, for example: “Remember that I live in Coimbatore.”")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func memoryCard(_ item: MemoryItem, dashboard: MemoryDashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(item.type.title, systemImage: item.type.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(item.type == .lesson ? BlueyTheme.warning : BlueyTheme.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background((item.type == .lesson ? BlueyTheme.warning : BlueyTheme.primary).opacity(0.12), in: Capsule())

                Text(dashboard.confidenceLabel(for: item))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                if let summary = dashboard.safeTriggerSummary(for: item) {
                    Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                Button {
                    model.setPinned(id: item.id, isPinned: !item.isPinned)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(item.isPinned ? BlueyTheme.primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isPinned ? "Unpin memory" : "Pin memory")

                Button {
                    editingID = item.id
                    editingContent = item.content
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit memory")

                Button(role: .destructive) {
                    model.delete(id: item.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete memory")
            }

            if editingID == item.id {
                HStack {
                    TextField("Content", text: $editingContent).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        model.update(id: item.id, content: editingContent)
                        editingID = nil
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { editingID = nil }.controlSize(.small)
                }
            } else {
                Text(item.content)
                    .font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Text("Updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if let reason = item.lastRecallReason {
                    Text("Last recall: \(reason)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var privacyFooter: some View {
        HStack {
            Text("🔒 100% private · stored in local SQLite on your Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func metricCard(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(BlueyTheme.primary)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
