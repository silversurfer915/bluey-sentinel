import AppKit
import Foundation

/// Defines whether the notch is attached flush to the screen bezel or floats like a dynamic island pill.
enum NotchSilhouette: String, Codable, CaseIterable {
    case auto
    case attached
    case floating

    var title: String {
        switch self {
        case .auto: return "Auto (Physical Notch Aware)"
        case .attached: return "Hardware Bezel Attached"
        case .floating: return "Floating Island Pill"
        }
    }
}

/// Reverse-engineered geometry and Bezier math mirroring Vorssaint's `NotchGeometry` and `NotchShape`.
struct NotchGeometry: Equatable {
    let screenBounds: CGRect
    let safeAreaTop: CGFloat
    let silhouettePreference: NotchSilhouette
    let floatingGap: CGFloat

    static let cubicBezierK: CGFloat = 0.55228475 // Exact circle/squircle factor: 4/3 * (sqrt(2) - 1)
    static let cubicBezierInvK: CGFloat = 0.44771525 // (1.0 - k)

    init(
        screen: NSScreen,
        preference: NotchSilhouette = .auto,
        floatingGap: CGFloat = 10.0
    ) {
        self.screenBounds = screen.frame
        self.safeAreaTop = screen.safeAreaInsets.top
        self.silhouettePreference = preference
        self.floatingGap = floatingGap
    }

    /// True if the current physical display has a hardware notch (safe area inset > 0).
    var isNotched: Bool {
        safeAreaTop > 0
    }

    /// Resolved silhouette: if .auto, uses .attached on MacBook displays with hardware notch, and .floating on notchless screens.
    var resolvedSilhouette: NotchSilhouette {
        switch silhouettePreference {
        case .auto:
            return isNotched ? .attached : .floating
        case .attached:
            return .attached
        case .floating:
            return .floating
        }
    }

    /// Vorssaint's exact shoulder fillet width formula from `NotchLayout.shoulder(height:)`: `min(14.0, height * 0.19)`
    func shoulder(for height: CGFloat) -> CGFloat {
        guard resolvedSilhouette == .attached else { return 0 }
        return min(14.0, max(0.0, height * 0.19))
    }

    /// Vorssaint's dynamic capsule gap formula from `NotchLayout.capsuleGap(barHeight:)`
    static func capsuleGap(barHeight: CGFloat) -> CGFloat {
        let raw = floor((barHeight - 20.0) / 2.0)
        return max(2.0, max(0.0, raw))
    }

    /// Corner squircle radius matching Vorssaint's `NotchLayout.capsuleRadius` (up to 28.0) and bottom attached squircle
    func cornerRadius(for height: CGFloat, shoulder: CGFloat, width: CGFloat = 220) -> CGFloat {
        if resolvedSilhouette == .floating {
            return min(28.0, height / 2.0)
        }
        let availableH = height - shoulder
        let availableW = width - 2.0 * shoulder
        return min(20.0, max(8.0, min(availableH / 2.0, availableW / 2.0)))
    }

    /// Computes window positioning on screen for a given content size.
    func windowFrame(for contentSize: CGSize) -> NSRect {
        let effectiveHeight: CGFloat
        if resolvedSilhouette == .attached && isNotched {
            // Guarantee coverage of the hardware notch safe area
            effectiveHeight = max(safeAreaTop, contentSize.height)
        } else {
            effectiveHeight = contentSize.height
        }

        let originX = screenBounds.midX - contentSize.width / 2.0
        let originY: CGFloat

        switch resolvedSilhouette {
        case .attached, .auto:
            originY = screenBounds.maxY - effectiveHeight
        case .floating:
            originY = screenBounds.maxY - effectiveHeight - floatingGap
        }

        return NSRect(
            x: originX,
            y: originY,
            width: contentSize.width,
            height: effectiveHeight
        )
    }

    /// Builds the precision Bezier path for the notch backdrop matching Vorssaint's `NotchShape.path`.
    /// In Cocoa/AppKit view coordinates: origin (0,0) is bottom-left, y=height is top edge hugging screen bezel.
    func buildPath(in rect: CGRect) -> CGPath {
        let w = rect.width
        let h = rect.height

        if resolvedSilhouette == .floating {
            // Floating Dynamic Island capsule: continuous squircle
            let r = cornerRadius(for: h, shoulder: 0, width: w)
            return CGPath(
                roundedRect: rect,
                cornerWidth: r,
                cornerHeight: r,
                transform: nil
            )
        }

        // Hardware attached notch with continuous shoulder fillets
        let s = shoulder(for: h)
        let r = cornerRadius(for: h, shoulder: s, width: w)
        let k = Self.cubicBezierK
        let invK = Self.cubicBezierInvK

        let path = CGMutablePath()

        // 1. Start at top-left screen bezel edge
        path.move(to: CGPoint(x: 0, y: h))

        // 2. Line along screen top bezel to top-right
        path.addLine(to: CGPoint(x: w, y: h))

        // 3. Right shoulder fillet (curves inward and down into the notch body)
        // Tangent at (w, h) is horizontal pointing left (-k*s): control1.x = w - s * k, control1.y = h
        // Tangent arriving at (w - s, h - s) is vertical pointing down: control2.x = w - s, control2.y = h - s * invK
        path.addCurve(
            to: CGPoint(x: w - s, y: h - s),
            control1: CGPoint(x: w - s * k, y: h),
            control2: CGPoint(x: w - s, y: h - s * invK)
        )

        // 4. Down the right vertical edge
        path.addLine(to: CGPoint(x: w - s, y: r))

        // 5. Bottom-right squircle corner
        path.addCurve(
            to: CGPoint(x: w - s - r, y: 0),
            control1: CGPoint(x: w - s, y: r * invK),
            control2: CGPoint(x: w - s - r * invK, y: 0)
        )

        // 6. Horizontal bottom edge
        path.addLine(to: CGPoint(x: s + r, y: 0))

        // 7. Bottom-left squircle corner
        path.addCurve(
            to: CGPoint(x: s, y: r),
            control1: CGPoint(x: s + r * invK, y: 0),
            control2: CGPoint(x: s, y: r * invK)
        )

        // 8. Up the left vertical edge
        path.addLine(to: CGPoint(x: s, y: h - s))

        // 9. Left shoulder fillet (curves smoothly outward to top bezel)
        // Tangent leaving (s, h - s) is vertical pointing up: control1.x = s, control1.y = h - s * invK
        // Tangent arriving at (0, h) is horizontal pointing left (-k*s): control2.x = s * k, control2.y = h
        path.addCurve(
            to: CGPoint(x: 0, y: h),
            control1: CGPoint(x: s, y: h - s * invK),
            control2: CGPoint(x: s * k, y: h)
        )

        path.closeSubpath()
        return path
    }

    /// Builds an open Bezier path for stroking the exposed outer rim of the notch.
    /// For .attached silhouette, this excludes the top edge (y=h) against the physical screen bezel,
    /// eliminating any visible top seam or line against the display bezel.
    func exposedRimPath(in rect: CGRect) -> CGPath {
        if resolvedSilhouette == .floating {
            return buildPath(in: rect)
        }

        let w = rect.width
        let h = rect.height
        let s = shoulder(for: h)
        let r = cornerRadius(for: h, shoulder: s, width: w)
        let k = Self.cubicBezierK
        let invK = Self.cubicBezierInvK

        let path = CGMutablePath()

        // Start at top-right bezel edge where the right shoulder fillet begins
        path.move(to: CGPoint(x: w, y: h))

        // 1. Right shoulder fillet
        path.addCurve(
            to: CGPoint(x: w - s, y: h - s),
            control1: CGPoint(x: w - s * k, y: h),
            control2: CGPoint(x: w - s, y: h - s * invK)
        )

        // 2. Down right edge
        path.addLine(to: CGPoint(x: w - s, y: r))

        // 3. Bottom-right corner
        path.addCurve(
            to: CGPoint(x: w - s - r, y: 0),
            control1: CGPoint(x: w - s, y: r * invK),
            control2: CGPoint(x: w - s - r * invK, y: 0)
        )

        // 4. Horizontal bottom edge
        path.addLine(to: CGPoint(x: s + r, y: 0))

        // 5. Bottom-left corner
        path.addCurve(
            to: CGPoint(x: s, y: r),
            control1: CGPoint(x: s + r * invK, y: 0),
            control2: CGPoint(x: s, y: r * invK)
        )

        // 6. Up left edge
        path.addLine(to: CGPoint(x: s, y: h - s))

        // 7. Left shoulder fillet up to top-left bezel edge
        path.addCurve(
            to: CGPoint(x: 0, y: h),
            control1: CGPoint(x: s, y: h - s * invK),
            control2: CGPoint(x: s * k, y: h)
        )

        return path
    }

    /// Determines if a point in the view bounds is inside the notch silhouette (reverse-engineered from Vorssaint `NotchGeometry.contains`).
    func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = buildPath(in: rect)
        return path.contains(point)
    }
}
