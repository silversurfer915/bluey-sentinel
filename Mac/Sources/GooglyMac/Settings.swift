import Foundation
import GooglyShared

/// User choices from the menu bar, kept between launches.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var onChange: (() -> Void)?

    var autonomyMode: AutonomyMode {
        get { AutonomyMode(rawValue: defaults.string(forKey: "autonomyMode") ?? "") ?? .confirmConsequences }
        set { defaults.set(newValue.rawValue, forKey: "autonomyMode"); onChange?() }
    }

    /// Cursor size in points (the design's default is 72).
    var cursorSize: Double {
        get { defaults.object(forKey: "cursorSize") as? Double ?? 72 }
        set { defaults.set(newValue, forKey: "cursorSize"); onChange?() }
    }

    var glow: Bool {
        get { defaults.object(forKey: "glow") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "glow"); onChange?() }
    }

    var showCursor: Bool {
        get { defaults.object(forKey: "showCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCursor"); onChange?() }
    }

    /// Where the phone sits under the screen, 0 = left edge, 1 = right edge.
    var phonePosition: Double {
        get { defaults.object(forKey: "phonePosition") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "phonePosition"); onChange?() }
    }

    /// When idle, hide the big cursor and let the phone's eyes follow your own mouse.
    var followMouse: Bool {
        get { defaults.object(forKey: "followMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followMouse"); onChange?() }
    }

    var captions: Bool {
        get { defaults.object(forKey: "captions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captions"); onChange?() }
    }

    /// Lets him click, type, press keys and open things when you ask.
    var computerControl: Bool {
        get { defaults.object(forKey: "computerControl") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "computerControl"); onChange?() }
    }

    /// How the cursor's path shows while it flies.
    var trail: PointerTrail {
        get { PointerTrail(rawValue: defaults.string(forKey: "trail") ?? "") ?? .comet }
        set { defaults.set(newValue.rawValue, forKey: "trail"); onChange?() }
    }

    /// The mood picked by hand in the menu.
    var mood: Mood {
        get { Mood(rawValue: defaults.string(forKey: "mood") ?? "") ?? .listening }
        set { defaults.set(newValue.rawValue, forKey: "mood"); onChange?() }
    }

    /// The AI provider for conversation, research, and sentinel reasoning.
    var aiProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "aiProvider"); onChange?() }
    }

    var customEndpoint: String {
        get { defaults.string(forKey: "customEndpoint") ?? "" }
        set { defaults.set(newValue, forKey: "customEndpoint"); onChange?() }
    }
    var customModel: String {
        get { defaults.string(forKey: "customModel") ?? "" }
        set { defaults.set(newValue, forKey: "customModel"); onChange?() }
    }
    var customVision: Bool {
        get { defaults.bool(forKey: "customVision") }
        set { defaults.set(newValue, forKey: "customVision"); onChange?() }
    }
    var providerFallback: Bool {
        get { defaults.bool(forKey: "providerFallback") }
        set { defaults.set(newValue, forKey: "providerFallback"); onChange?() }
    }

    // MARK: - Dual-Model Brain Routing

    var fastProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: "fastProvider") ?? "") ?? .gemini }
        set { defaults.set(newValue.rawValue, forKey: "fastProvider"); onChange?() }
    }
    var fastCustomModel: String {
        get { defaults.string(forKey: "fastCustomModel") ?? "gemini-3.1-flash-lite" }
        set { defaults.set(newValue, forKey: "fastCustomModel"); onChange?() }
    }
    var flagshipProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: "flagshipProvider") ?? "") ?? .deepseek }
        set { defaults.set(newValue.rawValue, forKey: "flagshipProvider"); onChange?() }
    }
    var flagshipCustomModel: String {
        get { defaults.string(forKey: "flagshipCustomModel") ?? "deepseek-chat" }
        set { defaults.set(newValue, forKey: "flagshipCustomModel"); onChange?() }
    }
    var modelRoutingMode: ModelRoutingMode {
        get { ModelRoutingMode(rawValue: defaults.string(forKey: "modelRoutingMode") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "modelRoutingMode"); onChange?() }
    }
    var lastAttributedModel: String {
        get { defaults.string(forKey: "lastAttributedModel") ?? "" }
        set { defaults.set(newValue, forKey: "lastAttributedModel"); onChange?() }
    }
    var lastAttributedTier: ModelTier {
        get { ModelTier(rawValue: defaults.string(forKey: "lastAttributedTier") ?? "") ?? .fast }
        set { defaults.set(newValue.rawValue, forKey: "lastAttributedTier"); onChange?() }
    }

    // MARK: - Mac Voice Input

    /// When true, allows using your Mac's built-in microphone for voice commands when no phone is connected.
    var macMicEnabled: Bool {
        get { defaults.object(forKey: "macMicEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "macMicEnabled"); onChange?() }
    }

    // MARK: - Notch Nest (Virtual Notch on MacBook Air)

    var notchCoexistence: Bool {
        get { defaults.object(forKey: "notchCoexistence") as? Bool ?? FileManager.default.fileExists(atPath: "/Applications/Vorssaint.app") }
        set { defaults.set(newValue, forKey: "notchCoexistence"); onChange?() }
    }

    /// When true, a virtual hardware-style Notch / Dynamic Island sits at the top of the screen where Bluey lives.
    var notchEnabled: Bool {
        get { false }
        set { defaults.set(newValue, forKey: "notchEnabled"); onChange?() }
    }

    /// When true, music playing in Apple Music or Spotify expands the notch with track info and playback controls.
    var notchMusicEnabled: Bool {
        get { defaults.object(forKey: "notchMusicEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "notchMusicEnabled"); onChange?() }
    }

    /// When true, Bluey plays cute animations (bungee drop, nap, peek) when your Mac is idle.
    var notchIdlePlayEnabled: Bool {
        get { defaults.object(forKey: "notchIdlePlayEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "notchIdlePlayEnabled"); onChange?() }
    }

    /// When true, Bluey stays on the lock screen keeping watch while your Mac is locked.
    var notchOnLockScreen: Bool {
        get { defaults.object(forKey: "notchOnLockScreen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notchOnLockScreen"); onChange?() }
    }

    /// Notch silhouette style: auto (matches hardware), attached (bezel fillet), or floating (capsule pill).
    var notchSilhouette: NotchSilhouette {
        get { NotchSilhouette(rawValue: defaults.string(forKey: "notchSilhouette") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "notchSilhouette"); onChange?() }
    }

    /// Gap in points when using the floating Dynamic Island silhouette.
    var notchFloatingGap: Double {
        get { defaults.object(forKey: "notchFloatingGap") as? Double ?? 10.0 }
        set { defaults.set(newValue, forKey: "notchFloatingGap"); onChange?() }
    }

    /// Whether the Hermes-style AI learning engine observes user study habits and adapts over time.
    var aiLearningEnabled: Bool {
        get { defaults.object(forKey: "aiLearningEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "aiLearningEnabled"); onChange?() }
    }

    // MARK: - Focus Sentinel

    /// Master switch for the focus watcher.
    var sentinelEnabled: Bool {
        get { defaults.object(forKey: "sentinelEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "sentinelEnabled"); onChange?() }
    }

    /// What the user is supposed to be doing. Empty means the Sentinel stays quiet.
    var focusGoal: String {
        get { defaults.string(forKey: "focusGoal") ?? "" }
        set { defaults.set(newValue, forKey: "focusGoal"); onChange?() }
    }

    /// When on, the Sentinel may actually close the distraction after warning. When off it only warns.
    var sentinelAct: Bool {
        get { defaults.object(forKey: "sentinelAct") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "sentinelAct"); onChange?() }
    }

    /// Seconds between brain checks while the user is actively at the keyboard.
    var checkInterval: Double {
        get { defaults.object(forKey: "checkInterval") as? Double ?? 5 }
        set { defaults.set(newValue, forKey: "checkInterval"); onChange?() }
    }

    /// How long the user must be off-task before it counts as real drift, not a glance.
    /// How long the user must be off-task before it counts as real drift, not a glance.
    /// `defaultSustainSeconds` is the shipped value; the self-test asserts on that constant rather
    /// than on whatever the machine currently has stored, so tuning it live cannot fail the suite.
    static let defaultSustainSeconds: Double = 60
    var sustainSeconds: Double {
        get { defaults.object(forKey: "sustainSeconds") as? Double ?? Self.defaultSustainSeconds }
        set { defaults.set(newValue, forKey: "sustainSeconds"); onChange?() }
    }

    /// How many consecutive off-task checks are needed on top of the sustained window.
    var strikes: Int {
        get { defaults.object(forKey: "strikes") as? Int ?? 2 }
        set { defaults.set(newValue, forKey: "strikes"); onChange?() }
    }

    /// How sure the brain must be before the Sentinel acts.
    var acceptConfidence: Double {
        get { defaults.object(forKey: "acceptConfidence") as? Double ?? 0.7 }
        set { defaults.set(newValue, forKey: "acceptConfidence"); onChange?() }
    }

    /// Seconds the warning card counts down before enforcing.
    var warnSeconds: Double {
        get { defaults.object(forKey: "warnSeconds") as? Double ?? 10 }
        set { defaults.set(newValue, forKey: "warnSeconds"); onChange?() }
    }

    /// Quiet period after a warning or an enforcement, so it never nags back to back.
    var cooldownSeconds: Double {
        get { defaults.object(forKey: "cooldownSeconds") as? Double ?? 120 }
        set { defaults.set(newValue, forKey: "cooldownSeconds"); onChange?() }
    }

    /// Idle time that means "away from the desk", which clears any drift and pauses judging.
    var idleResetSeconds: Double {
        get { defaults.object(forKey: "idleResetSeconds") as? Double ?? 90 }
        set { defaults.set(newValue, forKey: "idleResetSeconds"); onChange?() }
    }

    /// Apps and domains the Sentinel must never judge or close.
    var exemptApps: [String] {
        get {
            let list = defaults.stringArray(forKey: "exemptApps") ?? Self.defaultExempt
            // Do not automatically exempt code editors from old defaults; user must explicitly add them
            return list.filter { $0 != "Xcode" && $0 != "Terminal" }
        }
        set { defaults.set(newValue, forKey: "exemptApps"); onChange?() }
    }

    /// Sensible starting exemptions: essential meeting/call apps.
    static let defaultExempt = ["DeepSeek Harness", "zoom.us", "meet.google.com"]

    /// Let the Sentinel speak its nudge out loud, in the free local voice.
    var voiceEnabled: Bool {
        get { defaults.object(forKey: "voiceEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "voiceEnabled"); onChange?() }
    }

    /// Which macOS voice to use; nil means pick a good installed one automatically.
    var voiceIdentifier: String? {
        get { defaults.string(forKey: "voiceIdentifier") }
        set { defaults.set(newValue, forKey: "voiceIdentifier"); onChange?() }
    }

    /// Use DeepSeek's thinking pass. More accurate, slower and pricier; off is right for focus checks.
    var deepseekThinking: Bool {
        get { defaults.object(forKey: "deepseekThinking") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "deepseekThinking"); onChange?() }
    }

    /// When a drift is caught, fly the character over and have him point at the distraction.
    var sentinelPoints: Bool {
        get { defaults.object(forKey: "sentinelPoints") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sentinelPoints"); onChange?() }
    }

    /// The window or browser tab the user has explicitly locked focus onto.
    var sentinelLockedTarget: LockedTarget? {
        get {
            guard let data = defaults.data(forKey: "sentinelLockedTarget") else { return nil }
            return try? JSONDecoder().decode(LockedTarget.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "sentinelLockedTarget")
            } else {
                defaults.removeObject(forKey: "sentinelLockedTarget")
            }
            onChange?()
        }
    }

    /// When false, automatic continuous timer polling is disabled to save credits.
    /// Sentinel only checks when moving away from a locked target or when manually requested.
    var sentinelAutoPolling: Bool {
        get { defaults.object(forKey: "sentinelAutoPolling") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sentinelAutoPolling"); onChange?() }
    }
}

/// Represents a single window or browser tab that the user has locked onto.
struct LockedTarget: Codable, Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var domain: String?
    var url: String?
    var lockedAt: Date = Date()

    var displayName: String {
        if let domain, !domain.isEmpty {
            if let windowTitle, !windowTitle.isEmpty {
                return "\(domain) (\(windowTitle.prefix(25)))"
            }
            return domain
        }
        if let windowTitle, !windowTitle.isEmpty {
            let app = appName ?? "App"
            return "\(app): \(windowTitle.prefix(30))"
        }
        return appName ?? "Active Target"
    }
}
