import AppKit
import SwiftUI
import GooglyShared

/// Unified Design System for Bluey — Crafted to premier AI companion standards (Claude / ChatGPT / Gemini quality).
public enum BlueyTheme {
    // MARK: - Colors & Gradients

    /// Vibrant royal blueberry brand primary
    public static let primary = Color(red: 0.30, green: 0.42, blue: 0.94)
    public static let primaryHover = Color(red: 0.25, green: 0.36, blue: 0.88)
    public static let primaryDark = Color(red: 0.17, green: 0.22, blue: 0.65)

    /// Subtle brand accent gradient for active highlights and buttons
    public static let accentGradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.48, blue: 0.98), Color(red: 0.24, green: 0.35, blue: 0.88)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle dark surface acrylic gradient
    public static let darkSurfaceGradient = LinearGradient(
        colors: [Color(white: 0.12).opacity(0.85), Color(white: 0.08).opacity(0.95)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Glass card background
    public static let glassSurface = Color(nsColor: .controlBackgroundColor).opacity(0.65)
    public static let cardBackground = Color(nsColor: .windowBackgroundColor)
    public static let elevatedCard = Color(nsColor: .controlBackgroundColor)

    /// Semantic status colors
    public static let success = Color(red: 0.13, green: 0.77, blue: 0.48)
    public static let warning = Color(red: 0.96, green: 0.62, blue: 0.13)
    public static let error = Color(red: 0.93, green: 0.27, blue: 0.31)
    public static let purple = Color(red: 0.64, green: 0.38, blue: 0.96)

    // MARK: - Radii & Layout Tokens

    public static let radiusSmall: CGFloat = 8
    public static let radiusMedium: CGFloat = 12
    public static let radiusLarge: CGFloat = 16
    public static let radiusCard: CGFloat = 18
    public static let radiusPill: CGFloat = 999

    // MARK: - Spring Physics

    public static let springQuick = Animation.spring(response: 0.28, dampingFraction: 0.78)
    public static let springSmooth = Animation.spring(response: 0.36, dampingFraction: 0.84)
    public static let springBouncy = Animation.spring(response: 0.42, dampingFraction: 0.72)

    // MARK: - Shadows

    public static func cardShadow(radius: CGFloat = 8, y: CGFloat = 3) -> some View {
        EmptyView()
    }
}

// MARK: - Reusable UI Components

/// A frosted glass card with subtle hairline border and soft ambient shadow
public struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = BlueyTheme.radiusCard
    var padding: CGFloat = 16
    var content: () -> Content

    public init(cornerRadius: CGFloat = BlueyTheme.radiusCard, padding: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
    }
}

/// Model attribution chip showing tier, model name, and performance metrics
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
                .foregroundStyle(isFlagship ? BlueyTheme.purple : BlueyTheme.primary)

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill((isFlagship ? BlueyTheme.purple : BlueyTheme.primary).opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder((isFlagship ? BlueyTheme.purple : BlueyTheme.primary).opacity(0.25), lineWidth: 1)
        )
    }
}

/// Interactive clickable suggestion prompt chip
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
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BlueyTheme.primary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Animated sound wave bars for listening state
public struct AnimatedWaveform: View {
    var barCount: Int = 5
    var color: Color = BlueyTheme.primary
    @State private var heights: [CGFloat] = [0.3, 0.7, 0.9, 0.6, 0.4]

    public init(barCount: Int = 5, color: Color = BlueyTheme.primary) {
        self.barCount = barCount
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3, height: max(4, 18 * (i < heights.count ? heights[i] : 0.5)))
                    .animation(
                        Animation.easeInOut(duration: 0.22)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.07),
                        value: heights[i]
                    )
            }
        }
        .onAppear {
            for i in 0..<heights.count {
                heights[i] = CGFloat.random(in: 0.3...1.0)
            }
        }
    }
}
