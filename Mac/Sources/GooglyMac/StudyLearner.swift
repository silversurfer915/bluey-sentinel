import AppKit
import Foundation

/// Represents user study statistics for a single subject or project.
struct SubjectRecord: Codable, Equatable {
    var name: String
    var minutesSpent: Double
    var sessionCount: Int
    var lastStudiedAt: Date
}

/// Persistent user profile capturing how the user studies, their work habits, tools, and fatigue patterns.
struct StudyProfile: Codable, Equatable {
    var userName: String = ""
    var totalFocusMinutes: Double = 0
    var sessionsCompleted: Int = 0
    var streakDays: Int = 1
    var lastActiveDate: Date? = nil

    /// Subjects and topics studied over time (e.g. "Wave Optics", "Swift Programming", "Calculus")
    var subjects: [String: SubjectRecord] = [:]

    /// Learned productive applications and domains with confidence score (0.0 ... 1.0)
    var productiveTools: [String: Double] = [:]

    /// Distraction triggers and occurrence counts
    var distractionTriggers: [String: Int] = [:]

    /// Average focus endurance in minutes before fatigue or drift occurs
    var averageEnduranceMinutes: Double = 42.0

    /// Hourly study distribution (hour 0-23 -> minutes focused)
    var hourlyProductivity: [Int: Double] = [:]

    /// Personal study facts and preferences learned from user chat / commands
    var userNotes: [String] = []

    /// Hermes agent synthesized reflection on user study habits
    var synthesizedInsight: String = ""
}

/// The Hermes-style persistent learning agent engine.
/// Observes focus sessions, tracks topics studied, learns productive tools vs distractions,
/// reflects on cognitive endurance, and feeds context directly into the AI Brain.
@MainActor
final class StudyLearner {
    static let shared = StudyLearner()

    private(set) var profile: StudyProfile = StudyProfile()
    private let storageURL: URL
    private var lastSessionStart: Date?
    private var activeSubject: String?

    var onChange: (() -> Void)?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = appSupport.appendingPathComponent("Googly", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.storageURL = folder.appendingPathComponent("study_profile.json")

        load()
        if profile.productiveTools.isEmpty {
            seedDefaults()
        }
        performReflection()
    }

    private func seedDefaults() {
        // Pre-seed high confidence for standard development and learning tools
        profile.productiveTools["Xcode"] = 0.95
        profile.productiveTools["Visual Studio Code"] = 0.95
        profile.productiveTools["Terminal"] = 0.92
        profile.productiveTools["Anki"] = 0.90
        profile.productiveTools["Obsidian"] = 0.90
        profile.productiveTools["Notion"] = 0.88
        profile.productiveTools["Preview"] = 0.85
        profile.productiveTools["arxiv.org"] = 0.95
        profile.productiveTools["github.com"] = 0.95
        profile.productiveTools["stackoverflow.com"] = 0.90
    }

    // MARK: - Persistence

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(StudyProfile.self, from: data) else {
            return
        }
        self.profile = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(profile) {
            try? data.write(to: storageURL, options: .atomic)
        }
        onChange?()
    }

    // MARK: - Study Session Tracking

    /// Starts or resumes a focus block for a given goal or subject.
    func startFocusSession(goal: String) {
        lastSessionStart = Date()
        activeSubject = cleanSubjectName(goal)
        updateStreak()
        save()
    }

    /// Records periodic focus progress (e.g. called each minute the user remains on-task).
    func recordFocusProgress(app: String?, domain: String?, durationMinutes: Double = 1.0) {
        profile.totalFocusMinutes += durationMinutes

        // Record hourly productivity
        let hour = Calendar.current.component(.hour, from: Date())
        profile.hourlyProductivity[hour, default: 0] += durationMinutes

        // Record subject progress
        if let subject = activeSubject, !subject.isEmpty {
            if var record = profile.subjects[subject] {
                record.minutesSpent += durationMinutes
                record.lastStudiedAt = Date()
                profile.subjects[subject] = record
            } else {
                profile.subjects[subject] = SubjectRecord(
                    name: subject,
                    minutesSpent: durationMinutes,
                    sessionCount: 1,
                    lastStudiedAt: Date()
                )
            }
        }

        // Strengthen productive tool confidence
        if let app = app, !app.isEmpty {
            let current = profile.productiveTools[app] ?? 0.5
            profile.productiveTools[app] = min(0.99, current + 0.01)
        }
        if let domain = domain, !domain.isEmpty {
            let current = profile.productiveTools[domain] ?? 0.5
            profile.productiveTools[domain] = min(0.99, current + 0.01)
        }

        save()
    }

    /// Records completed session.
    func completeFocusSession() {
        if let start = lastSessionStart {
            let elapsedMins = Date().timeIntervalSince(start) / 60.0
            if elapsedMins >= 10.0 {
                profile.sessionsCompleted += 1
                if let subject = activeSubject, var record = profile.subjects[subject] {
                    record.sessionCount += 1
                    profile.subjects[subject] = record
                }
            }
        }
        lastSessionStart = nil
        performReflection()
        save()
    }

    /// Records an off-task drift event to learn triggers and cognitive endurance.
    func recordDrift(culprit: String, sessionDurationMins: Double) {
        let cleanCulprit = culprit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanCulprit.isEmpty {
            profile.distractionTriggers[cleanCulprit, default: 0] += 1
        }

        // Adjust average endurance if drift happened during an active block
        if sessionDurationMins >= 5.0 {
            let alpha = 0.25
            profile.averageEnduranceMinutes = (1.0 - alpha) * profile.averageEnduranceMinutes + alpha * sessionDurationMins
        }

        performReflection()
        save()
    }

    /// Records an explicit personal study fact or goal mentioned by the user.
    func addLearnedFact(_ fact: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !profile.userNotes.contains(trimmed) else { return }
        profile.userNotes.append(trimmed)
        performReflection()
        save()
    }

    private func updateStreak() {
        let now = Date()
        let calendar = Calendar.current
        if let last = profile.lastActiveDate {
            if calendar.isDateInToday(last) {
                // Already counted today
            } else if calendar.isDateInYesterday(last) {
                profile.streakDays += 1
            } else {
                profile.streakDays = 1
            }
        } else {
            profile.streakDays = 1
        }
        profile.lastActiveDate = now
    }

    // MARK: - Hermes Reflection & Synthesis Loop

    /// Synthesizes observed behavior into high-level cognitive insights.
    func performReflection() {
        var insights: [String] = []

        // 1. Top subjects
        let sortedSubjects = profile.subjects.values.sorted { $0.minutesSpent > $1.minutesSpent }
        if let top = sortedSubjects.first {
            let hours = String(format: "%.1f", top.minutesSpent / 60.0)
            insights.append("Main study focus: \(top.name) (\(hours) hrs)")
        }

        // 2. Endurance
        let endMins = Int(profile.averageEnduranceMinutes.rounded())
        insights.append("Focus endurance: ~\(endMins)m before fatigue")

        // 3. Peak hours
        if let peak = profile.hourlyProductivity.max(by: { $0.value < $1.value }), peak.value > 15 {
            let hourFormatted = String(format: "%02d:00", peak.key)
            insights.append("Peak productivity window: \(hourFormatted)")
        }

        // 4. Distractions
        if let topDistraction = profile.distractionTriggers.max(by: { $0.value < $1.value }) {
            insights.append("Watch out for: \(topDistraction.key)")
        }

        profile.synthesizedInsight = insights.joined(separator: " • ")
    }

    // MARK: - AI Context Generation

    /// System prompt context injected into Brain.swift.
    func systemPromptContext() -> String {
        var lines: [String] = []
        lines.append("--- USER STUDY PROFILE & LEARNING CONTEXT (Hermes Engine) ---")

        let sortedSubjects = profile.subjects.values.sorted { $0.minutesSpent > $1.minutesSpent }.prefix(3)
        if !sortedSubjects.isEmpty {
            let subs = sortedSubjects.map { "\($0.name) (\(Int($0.minutesSpent))m)" }.joined(separator: ", ")
            lines.append("• Established Study Subjects: \(subs)")
        }

        let topTools = profile.productiveTools.filter { $0.value >= 0.8 }.map { $0.key }.sorted().prefix(8)
        if !topTools.isEmpty {
            lines.append("• User's Proven Productive Tools & Sites: \(topTools.joined(separator: ", "))")
        }

        let triggers = profile.distractionTriggers.sorted { $0.value > $1.value }.prefix(4).map { $0.key }
        if !triggers.isEmpty {
            lines.append("• Common Distraction Triggers: \(triggers.joined(separator: ", "))")
        }

        lines.append("• Focus Endurance: ~\(Int(profile.averageEnduranceMinutes)) minutes average")

        if !profile.userNotes.isEmpty {
            lines.append("• Known User Preferences & Goals:")
            for note in profile.userNotes.suffix(5) {
                lines.append("  - \(note)")
            }
        }

        if !profile.synthesizedInsight.isEmpty {
            lines.append("• AI Synthesis: \(profile.synthesizedInsight)")
        }

        lines.append("• PERSONALIZED GUIDANCE: Adapt your nudges to this user's study context. Encourage them with awareness of their streak (\(profile.streakDays) days) and active subject.")
        lines.append("-------------------------------------------------------------")

        return lines.joined(separator: "\n")
    }

    private func cleanSubjectName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "Study", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Work on", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Finish", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }
}
