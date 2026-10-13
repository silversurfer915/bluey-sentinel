import SwiftUI

/// Memory & Skills page. Two distinct stores and concepts behind one native
/// segmented control: personal memories versus learned procedures.
struct MemorySkillsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case memories = "Memories"
        case skills = "Learned skills"
        var id: String { rawValue }
    }

    @State private var section: Section = .memories

    var body: some View {
        VStack(alignment: .leading, spacing: BlueyTheme.space4) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .accessibilityLabel("Memories or learned skills")

            switch section {
            case .memories:
                MemoryDashboardView()
            case .skills:
                WorkflowLearningView()
            }
        }
    }
}
