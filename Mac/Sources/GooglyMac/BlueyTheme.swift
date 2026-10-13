import AppKit
import SwiftUI
import GooglyShared

/// Bluey design system — "Calm Warm Study Studio".
///
/// Three layers: primitives (raw values) → semantic roles → component roles.
/// Every screen consumes semantic tokens; no screen-local hex values.
public enum BlueyTheme {

    // MARK: - Primitives (light / dark)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// Warm paper canvas behind grouped surfaces.
    public static let canvas = dynamic(0xF5F3EE, 0x17191D)
    /// Main cards, popover and settings groups.
    public static let surface = dynamic(0xFFFFFF, 0x22252A)
    /// Selected rows, inset panels, composer.
    public static let surfaceRaised = dynamic(0xFBFAF7, 0x292D33)
    /// Main text.
    public static let textPrimary = dynamic(0x24262B, 0xF2F1EC)
    /// Supporting labels and metadata.
    public static let textSecondary = dynamic(0x656A73, 0xB2B5BC)
    /// Tertiary metadata; still meets normal-text contrast on the canvas.
    public static let textTertiary = dynamic(0x696E76, 0x8E949D)
    /// Primary action, selected navigation, Focus Thread.
    public static let accent = dynamic(0x5366CF, 0xA9B6FF)
    /// Selected navigation and quiet focus backgrounds.
    public static let accentSubtle = dynamic(0xE9ECFA, 0x30364E)
    public static let selection = accentSubtle
    /// Section separation and table rules.
    public static let separator = dynamic(0xE5E2DA, 0x3A3E45)
    /// Connected, completed, or healthy state.
    public static let success = dynamic(0x287653, 0x75C99A)
    /// Warning, permission needed, paused-with-attention.
    public static let attention = dynamic(0x95600F, 0xE7B963)
    /// Emergency Stop and irreversible actions.
    public static let destructive = dynamic(0xB23F45, 0xF08D91)

    // MARK: - Backward-compatible semantic aliases

    public static let primary = accent
    public static let primaryHover = accent
    public static let primaryDark = dynamic(0x3D4DA8, 0x8B9BF0)
    public static let warning = attention
    public static let error = destructive
    public static let purple = accent
    public static let cardBackground = canvas
    public static let elevatedCard = surface
    public static let glassSurface = surface
    /// Retired decorative gradients; kept as flat fills so no screen renders neon.
    public static let accentGradient = LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    public static let darkSurfaceGradient = LinearGradient(colors: [surface, surface], startPoint: .top, endPoint: .bottom)

    // MARK: - Spacing

    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 24
    public static let space6: CGFloat = 32
    public static let space7: CGFloat = 40

    // MARK: - Shape

    public static let radiusControl: CGFloat = 8
    public static let radiusCard: CGFloat = 14
    public static let radiusHero: CGFloat = 18
    /// Legacy aliases mapped onto the new shape scale.
    public static let radiusSmall: CGFloat = 8
    public static let radiusMedium: CGFloat = 10
    public static let radiusLarge: CGFloat = 14
    public static let radiusPill: CGFloat = 999

    // MARK: - Control sizing

    public static let controlHeightMac: CGFloat = 36
    public static let controlHeightIOS: CGFloat = 48

    // MARK: - Motion

    /// Standard navigation/selection change: 160–220 ms ease-out, no bounce.
    public static let motionStandard = Animation.easeOut(duration: 0.19)
    public static let motionQuick = Animation.easeOut(duration: 0.16)
    /// Legacy spring aliases now resolve to calm ease-out motion.
    public static let springQuick = motionStandard
    public static let springSmooth = Animation.easeOut(duration: 0.22)
    public static let springBouncy = Animation.easeOut(duration: 0.22)

    // MARK: - Depth

    /// One very soft native shadow, only when a card must lift above the canvas.
    public static func cardShadow(radius: CGFloat = 12, y: CGFloat = 3) -> some View {
        EmptyView()
    }

    public static let softShadowColor = Color.black.opacity(0.04)
    public static let softShadowRadius: CGFloat = 12
    public static let softShadowY: CGFloat = 3
}

// MARK: - Color hex helper

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Shared components

/// The Bluey character mark. Decorative by default; hide from VoiceOver when used
/// next to a text label.
public struct BlueyMark: View {
    let size: CGFloat
    let accessibilityHidden: Bool

    public init(size: CGFloat = 30, accessibilityHidden: Bool = true) {
        self.size = size
        self.accessibilityHidden = accessibilityHidden
    }

    public var body: some View {
        BlueyLogoBadge(size: size)
            .accessibilityHidden(accessibilityHidden)
    }
}

/// Flat tonal card: surface fill, optional hairline border, one soft shadow only
/// when it must lift above the canvas.
public struct BlueyCard<Content: View>: View {
    var cornerRadius: CGFloat
    var padding: CGFloat
    var raised: Bool
    var content: () -> Content

    public init(cornerRadius: CGFloat = BlueyTheme.radiusCard,
                padding: CGFloat = BlueyTheme.space4,
                raised: Bool = false,
                @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.raised = raised
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(raised ? BlueyTheme.surfaceRaised : BlueyTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(BlueyTheme.separator, lineWidth: 1)
            )
    }
}

/// Legacy glass card, now rendered as a flat tonal card (no frosted glass).
public struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = BlueyTheme.radiusCard
    var padding: CGFloat = BlueyTheme.space4
    var content: () -> Content

    public init(cornerRadius: CGFloat = BlueyTheme.radiusCard, padding: CGFloat = BlueyTheme.space4, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        BlueyCard(cornerRadius: cornerRadius, padding: padding, content: content)
    }
}

/// Status badge: tinted background, semantic icon, and a readable label.
/// State is never encoded through color alone.
public struct StatusBadge: View {
    public enum Kind {
        case ready, listening, working, active, paused, offline, needsPermission, stopped, neutral
    }

    let kind: Kind
    let label: String

    public init(_ kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }

    private var symbol: String {
        switch kind {
        case .ready: return "checkmark.circle.fill"
        case .listening: return "mic.fill"
        case .working: return "ellipsis.circle.fill"
        case .active: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .offline: return "wifi.slash"
        case .needsPermission: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        case .neutral: return "circle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .ready, .active: return BlueyTheme.success
        case .listening, .working, .neutral: return BlueyTheme.accent
        case .paused, .needsPermission: return BlueyTheme.attention
        case .offline: return BlueyTheme.textSecondary
        case .stopped: return BlueyTheme.destructive
        }
    }

    public var body: some View {
        HStack(spacing: BlueyTheme.space1) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, BlueyTheme.space2)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// Inline notice for neutral/success/attention/error states. Never color-only.
public struct InlineNotice: View {
    public enum Variant { case neutral, success, attention, error }

    let variant: Variant
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    public init(variant: Variant, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.variant = variant
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
    }

    private var tint: Color {
        switch variant {
        case .neutral: return BlueyTheme.accent
        case .success: return BlueyTheme.success
        case .attention: return BlueyTheme.attention
        case .error: return BlueyTheme.destructive
        }
    }

    private var symbol: String {
        switch variant {
        case .neutral: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: BlueyTheme.space3) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BlueyTheme.space1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(BlueyTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).controlSize(.small).padding(.top, BlueyTheme.space1)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notice")
            }
        }
        .padding(BlueyTheme.space3)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: BlueyTheme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BlueyTheme.radiusCard, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Native unavailable-content empty state with one useful next action.
public struct EmptyState: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    public init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: BlueyTheme.space3) {
            BlueyMark(size: 44)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(BlueyTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.regular)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.vertical, BlueyTheme.space7)
    }
}

/// The Focus Thread: a slim indigo progress stroke with a neutral track.
/// Always paired with a numeric time and a textual state.
public struct FocusThread: View {
    /// 0...1 when a plan exists; nil when only elapsed time is known.
    let progress: Double?
    let paused: Bool

    public init(progress: Double?, paused: Bool = false) {
        self.progress = progress
        self.paused = paused
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(BlueyTheme.separator)
                if let progress {
                    Capsule()
                        .fill(paused ? BlueyTheme.attention : BlueyTheme.accent)
                        .frame(width: max(0, min(1, progress)) * geo.size.width)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Page header: title, one-line subtitle, optional state chip.
public struct PageHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView?

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = nil
    }

    public init<T: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack(alignment: .top, spacing: BlueyTheme.space4) {
            VStack(alignment: .leading, spacing: BlueyTheme.space1) {
                Text(title).font(.system(size: 23, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(BlueyTheme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: BlueyTheme.space3)
            if let trailing { trailing }
        }
    }
}

/// Model attribution chip showing tier and model name.
public struct ModelAttributionChip: View {
    let text: String
    var isFlagship: Bool = false

    public init(text: String, isFlagship: Bool = false) {
        self.text = text
        self.isFlagship = isFlagship
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isFlagship ? "brain" : "bolt.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(BlueyTheme.accent)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BlueyTheme.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(BlueyTheme.accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(BlueyTheme.accent.opacity(0.25), lineWidth: 1))
    }
}

/// Interactive suggestion chip.
public struct PromptSuggestionChip: View {
    let title: String
    let icon: String
    let action: () -> Void

    public init(title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(BlueyTheme.accent)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(BlueyTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: BlueyTheme.radiusControl, style: .continuous).fill(BlueyTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: BlueyTheme.radiusControl, style: .continuous).strokeBorder(BlueyTheme.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Listening waveform. Shows a static icon when Reduce Motion is on.
public struct AnimatedWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var barCount: Int = 5
    var color: Color = BlueyTheme.accent
    @State private var heights: [CGFloat] = [0.3, 0.7, 0.9, 0.6, 0.4]

    public init(barCount: Int = 5, color: Color = BlueyTheme.accent) {
        self.barCount = barCount
        self.color = color
    }

    public var body: some View {
        if reduceMotion {
            Image(systemName: "mic.fill").font(.system(size: 14)).foregroundStyle(color)
                .accessibilityLabel("Listening")
        } else {
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 3, height: max(4, 18 * (i < heights.count ? heights[i] : 0.5)))
                        .animation(Animation.easeInOut(duration: 0.22).repeatForever(autoreverses: true).delay(Double(i) * 0.07),
                                   value: i < heights.count ? heights[i] : 0.5)
                }
            }
            .onAppear {
                for i in 0..<heights.count { heights[i] = CGFloat.random(in: 0.3...1.0) }
            }
            .accessibilityLabel("Listening")
        }
    }
}
