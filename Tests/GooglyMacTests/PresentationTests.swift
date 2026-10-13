import XCTest
@testable import GooglyMac
final class PresentationTests: XCTestCase {
    func testActivityPriorityPreventsMusicInterruptions() {
        XCTAssertEqual(NotchPresentation.choose(warning: true, busy: true, listening: true), .warning)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: true, listening: true), .task)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: false, listening: true), .listening)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: false, listening: false), .passive)
    }

    @MainActor
    func testWorkspaceReopenPreservesActivePage() {
        BlueyWorkspace.shared.show(page: "Token Caching")
        XCTAssertEqual(BlueyState.shared.workspacePage, "Token Caching")

        // Reopening / clicking dock icon calls show() without page argument
        BlueyWorkspace.shared.show()
        XCTAssertEqual(BlueyState.shared.workspacePage, "Token Caching", "Reopening workspace must preserve currently selected tab")

        // Explicit Settings call switches to Settings
        BlueyWorkspace.shared.show(settings: true)
        XCTAssertEqual(BlueyState.shared.workspacePage, "Settings")
    }

    // MARK: - Memory dashboard model

    func testMemoryDashboardMetricsAndFiltering() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let items = [
            MemoryItem(id: "a", type: .profile, content: "I live in Coimbatore",
                       createdAt: now, updatedAt: now.addingTimeInterval(-86_400),
                       source: .explicitProfile, confidence: 0.95,
                       replacementKey: "profile:residence", isPinned: true,
                       recallCount: 1, lastRecalledAt: now.addingTimeInterval(-2 * 86_400)),
            MemoryItem(id: "b", type: .preference, content: "I prefer dark mode",
                       createdAt: now, updatedAt: now.addingTimeInterval(-10 * 86_400),
                       source: .explicitPreference, confidence: 0.95,
                       replacementKey: "preference:appearance:global"),
            MemoryItem(id: "c", type: .lesson, content: "Never close Terminal",
                       createdAt: now, updatedAt: now.addingTimeInterval(-400 * 86_400),
                       source: .correction, confidence: 0.98,
                       lastRecalledAt: now.addingTimeInterval(-30 * 86_400)),
        ]
        let model = MemoryDashboardModel(items: items, now: now)
        XCTAssertEqual(model.metrics.total, 3)
        XCTAssertEqual(model.metrics.pinned, 1)
        XCTAssertEqual(model.metrics.learnedThisWeek, 1)
        XCTAssertEqual(model.metrics.recalledThisWeek, 1)
        XCTAssertEqual(model.filtered.map(\.id), ["a", "b", "c"], "Newest updated first")
        XCTAssertEqual(model.recentlyLearned.count, 3)

        XCTAssertEqual(MemoryDashboardModel(items: items, filter: .type(.profile), now: now).filtered.map(\.id), ["a"])
        XCTAssertEqual(MemoryDashboardModel(items: items, query: "dark", now: now).filtered.map(\.id), ["b"])
        XCTAssertTrue(MemoryDashboardModel(items: items, query: "nonexistent", now: now).filtered.isEmpty)
    }

    func testMemoryDashboardConfidenceLabels() {
        let model = MemoryDashboardModel(items: [])
        XCTAssertEqual(model.confidenceLabel(for: MemoryItem(type: .profile, content: "x", source: .manual)), "Manual")
        XCTAssertEqual(model.confidenceLabel(for: MemoryItem(type: .profile, content: "x", source: .explicitProfile)), "Explicit")
        XCTAssertEqual(model.confidenceLabel(for: MemoryItem(type: .preference, content: "x", source: .explicitPreference)), "Explicit")
        XCTAssertEqual(model.confidenceLabel(for: MemoryItem(type: .lesson, content: "x", source: .correction)), "Correction")
        XCTAssertEqual(model.confidenceLabel(for: MemoryItem(type: .taskOutcome, content: "x", source: .taskOutcome)), "Confirmed outcome")
        XCTAssertEqual(model.confidenceLabel(for: MemoryItem(type: .profile, content: "x", source: .legacy)), "Legacy")
    }

    func testMemoryDashboardBoundsTriggerSummary() {
        let item = MemoryItem(type: .lesson, content: "x",
                              triggerContext: String(repeating: "word ", count: 50))
        let model = MemoryDashboardModel(items: [item])
        let summary = model.safeTriggerSummary(for: item)
        XCTAssertNotNil(summary)
        XCTAssertLessThanOrEqual(summary?.count ?? 0, 80)
        XCTAssertTrue(summary?.hasSuffix("…") ?? false)
    }

    @MainActor
    func testMemoryDashboardViewModelPinAndDelete() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dash_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MemoryStore(fileURL: url)
        store.save(MemoryItem(type: .profile, content: "I live in Coimbatore",
                              source: .explicitProfile, confidence: 0.95,
                              replacementKey: "profile:residence"))
        let viewModel = MemoryDashboardViewModel(store: store)
        XCTAssertEqual(viewModel.model.metrics.total, 1)

        let id = try! XCTUnwrap(viewModel.items.first?.id)
        viewModel.setPinned(id: id, isPinned: true)
        XCTAssertEqual(viewModel.model.metrics.pinned, 1)

        viewModel.delete(id: id)
        XCTAssertEqual(viewModel.model.metrics.total, 0)
    }
}
