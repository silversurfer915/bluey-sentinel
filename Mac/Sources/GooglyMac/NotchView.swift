import AppKit
import QuartzCore
import GooglyShared

/// Visual states for the Virtual Notch / Dynamic Island
enum NotchState: Equatable {
    case compact
    case idlePlay(phase: IdlePhase)
    case music
    case musicExpanded
    case studyInsight
    case locked
    case listening(caption: String)

    enum IdlePhase: Equatable {
        case peeking
        case bungee(dropY: CGFloat)
        case sleeping
    }

    @MainActor var size: CGSize {
        switch self {
        case .compact:
            let label = BlueyState.shared.focusStatus == "No focus session" ? "Bluey · ready" : BlueyState.shared.focusStatus
            if !label.isEmpty {
                let textW = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 82
                return CGSize(width: min(350, max(224, textW)), height: 34)
            }
            return CGSize(width: 216, height: 34)
        case .locked:
            return CGSize(width: 216, height: 34)
        case .idlePlay(let phase):
            switch phase {
            case .bungee:
                return CGSize(width: 216, height: 64)
            case .peeking, .sleeping:
                return CGSize(width: 210, height: 46)
            }
        case .music:
            return CGSize(width: 340, height: 36)
        case .musicExpanded:
            return CGSize(width: 390, height: 74)
        case .studyInsight:
            return CGSize(width: 440, height: 86)
        case .listening:
            return CGSize(width: 330, height: 36)
        }
    }
}

/// The custom view rendering the hardware-style dynamic notch, Bluey character,
/// Hermes AI study memory, and music dynamic island.
@MainActor
final class NotchView: NSView {
    var state: NotchState = .compact {
        didSet {
            if state != oldValue {
                needsDisplay = true
                updateTrackingAreas()
            }
        }
    }

    var onBlueyTapped: (() -> Void)?
    var onPlayPauseTapped: (() -> Void)?
    var onNextTapped: (() -> Void)?
    var onPreviousTapped: (() -> Void)?
    var onStudyTapped: (() -> Void)?
    var onHoverStateChanged: ((Bool) -> Void)?

    // Eye Tracking & Character state
    private var mouseLocation: CGPoint = .zero
    private var isBlinking = false
    private var blinkTimer: Timer?
    private var animationTimer: Timer?

    // Head bobbing for music
    private var musicBobOffset: CGFloat = 0
    private var musicBobDirection: CGFloat = 1
    private var eqBars: [CGFloat] = [0.4, 0.8, 0.5, 0.9, 0.6]

    // Floating Zzz for sleeping
    private var zzzParticles: [(x: CGFloat, y: CGFloat, alpha: CGFloat, size: CGFloat)] = []

    // Love / surprise pop
    private var popEmoji: String?
    private var popEmojiAlpha: CGFloat = 0
    private var popEmojiY: CGFloat = 0

    // Hover button state for expanded controls
    private var hoveredButton: String? = nil

    // Tracking area for interactive hover
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Bluey. Click to talk or open the current task.")
        setupTimers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        blinkTimer?.invalidate()
        animationTimer?.invalidate()
    }

    private func setupTimers() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 3.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.triggerBlink() }
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAnimations() }
        }
    }

    private func triggerBlink() {
        if case .idlePlay(phase: .sleeping) = state { return }
        if state == .locked { return }
        isBlinking = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.isBlinking = false
            self?.needsDisplay = true
        }
    }

    private func updateAnimations() {
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let m = NSEvent.mouseLocation
        if m != mouseLocation {
            mouseLocation = m
            needsDisplay = true
        }

        if case .music = state {
            updateMusicAnim()
        } else if case .musicExpanded = state {
            updateMusicAnim()
        } else if case .listening = state {
            updateMusicAnim()
        }

        let isSleeping = (state == .locked) || (state == .idlePlay(phase: .sleeping))
        if isSleeping {
            updateZzzParticles()
        } else if !zzzParticles.isEmpty {
            zzzParticles.removeAll()
            needsDisplay = true
        }

        if popEmoji != nil {
            popEmojiAlpha -= 0.04
            popEmojiY += 1.2
            if popEmojiAlpha <= 0 {
                popEmoji = nil
            }
            needsDisplay = true
        }
    }

    private func updateMusicAnim() {
        musicBobOffset += musicBobDirection * 0.4
        if musicBobOffset > 3.0 {
            musicBobDirection = -1
        } else if musicBobOffset < -1.0 {
            musicBobDirection = 1
        }

        for i in 0..<eqBars.count {
            let change = CGFloat.random(in: -0.18...0.18)
            eqBars[i] = max(0.12, min(0.96, eqBars[i] + change))
        }
        needsDisplay = true
    }

    private func updateZzzParticles() {
        if zzzParticles.count < 3 && Float.random(in: 0...1) < 0.08 {
            zzzParticles.append((x: bounds.midX + 18, y: 14, alpha: 0.9, size: 10))
        }

        var next: [(x: CGFloat, y: CGFloat, alpha: CGFloat, size: CGFloat)] = []
        for var p in zzzParticles {
            p.y += 0.8
            p.x += 0.3
            p.alpha -= 0.015
            p.size += 0.05
            if p.alpha > 0 {
                next.append(p)
            }
        }
        zzzParticles = next
        needsDisplay = true
    }

    func showReactionEmoji(_ emoji: String) {
        popEmoji = emoji
        popEmojiAlpha = 1.0
        popEmojiY = 0
        needsDisplay = true
    }

    // MARK: - Tracking Areas & Interaction

    /// The display the notch belongs to: the built-in notched screen when there is one, rather than
    /// whichever window happens to be focused. Using `window?.screen ?? NSScreen.main` made the
    /// character jump to an external monitor as soon as a window there was clicked — and on a
    /// non-notched display the silhouette silently became a floating pill. `first!` also crashed
    /// during display teardown, when the screen list can be momentarily empty.
    private var anchorScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard let screen = anchorScreen else { return nil }
        let geometry = NotchGeometry(
            screen: screen,
            preference: Settings.shared.notchCoexistence ? .floating : Settings.shared.notchSilhouette,
            floatingGap: Settings.shared.notchCoexistence ? max(40, screen.safeAreaInsets.top + 12) : Settings.shared.notchFloatingGap
        )
        guard geometry.contains(point, in: bounds) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        onHoverStateChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredButton = nil
        needsDisplay = true
        onHoverStateChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .musicExpanded = state {
            let midY: CGFloat = 18
            let prevHovered = hoveredButton
            if CGRect(x: 175, y: midY - 14, width: 30, height: 28).contains(p) {
                hoveredButton = "prev"
            } else if CGRect(x: 215, y: midY - 14, width: 34, height: 28).contains(p) {
                hoveredButton = "play"
            } else if CGRect(x: 258, y: midY - 14, width: 30, height: 28).contains(p) {
                hoveredButton = "next"
            } else {
                hoveredButton = nil
            }
            if prevHovered != hoveredButton {
                needsDisplay = true
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // Haptic feedback for tactile satisfaction
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        // 1. Controls in musicExpanded mode
        if case .musicExpanded = state {
            let midY: CGFloat = 18
            if CGRect(x: 175, y: midY - 14, width: 30, height: 28).contains(p) {
                onPreviousTapped?()
                return
            }
            if CGRect(x: 215, y: midY - 14, width: 34, height: 28).contains(p) {
                onPlayPauseTapped?()
                return
            }
            if CGRect(x: 258, y: midY - 14, width: 30, height: 28).contains(p) {
                onNextTapped?()
                return
            }
        }

        // 2. Study Insight dismissal or toggle
        if case .studyInsight = state {
            onStudyTapped?()
            return
        }

        // 3. Compact mode: clicking study pill (right side) opens study insights!
        if case .compact = state, p.x > 75 {
            onStudyTapped?()
            return
        }

        // 4. Listening mode
        if case .listening = state {
            onBlueyTapped?()
            showReactionEmoji("🎙️")
            return
        }

        // 5. Bluey character click
        if p.x <= 75 || (state == .compact && p.x <= bounds.width) {
            onBlueyTapped?()
            showReactionEmoji(["💙", "✨", "🧠", "⭐", "🎉"].randomElement() ?? "💙")
            return
        }

        // 6. Music pill toggle
        if case .music = state {
            onPlayPauseTapped?()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Hardware-style reverse-engineered notch backdrop
        drawNotchBody(in: ctx)

        // 2. Bluey Character
        drawBluey(in: ctx)

        // 3. Mode content
        switch state {
        case .compact:
            drawCompactStudyPill(in: ctx)
        case .music:
            drawMusicIsland(in: ctx, expanded: false)
        case .musicExpanded:
            drawMusicIsland(in: ctx, expanded: true)
        case .studyInsight:
            drawStudyInsightIsland(in: ctx)
        case .listening(let caption):
            drawListeningIsland(in: ctx, caption: caption)
        case .idlePlay, .locked:
            break
        }

        // 4. Sleeping Zzz
        drawZzz(in: ctx)

        // 5. Reaction Emoji
        drawReactionEmoji(in: ctx)
    }

    // MARK: - Notch Backdrop (Vorssaint Reverse-Engineered Geometry)

    private func drawNotchBody(in ctx: CGContext) {
        guard let screen = anchorScreen else { return }
        let geometry = NotchGeometry(
            screen: screen,
            preference: Settings.shared.notchCoexistence ? .floating : Settings.shared.notchSilhouette,
            floatingGap: Settings.shared.notchCoexistence ? max(40, screen.safeAreaInsets.top + 12) : Settings.shared.notchFloatingGap
        )
        let path = geometry.buildPath(in: bounds)

        ctx.saveGState()

        ctx.setFillColor(NSColor(white: 0.045, alpha: 0.98).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        // Specular titanium rim highlight (0.75pt) on exposed outer edges only (eliminates top bezel seam)
        ctx.saveGState()
        let rimPath = geometry.exposedRimPath(in: bounds)
        ctx.addPath(rimPath)
        ctx.setStrokeColor(NSColor(white: 0.28, alpha: 0.85).cgColor)
        ctx.setLineWidth(0.75)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Bluey Drawing

    private func drawBluey(in ctx: CGContext) {
        let isExpanded = (state == .music || state == .musicExpanded || state == .studyInsight || isListening)
        let blueyCenter: CGPoint

        if isExpanded {
            blueyCenter = CGPoint(x: 30, y: bounds.height - 17 + musicBobOffset)
        } else if case .idlePlay(phase: .bungee(let dropY)) = state {
            blueyCenter = CGPoint(x: 36, y: bounds.height - 17 - dropY)
            // Glowing hanging line
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(hex: Palette.berry1, alpha: 0.85).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 36, y: bounds.height))
            ctx.addLine(to: CGPoint(x: 36, y: blueyCenter.y + 10))
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            blueyCenter = CGPoint(x: 30, y: bounds.height - 17)
        }

        let bodyWidth: CGFloat = 22
        let bodyHeight: CGFloat = 20
        let bodyRect = CGRect(x: blueyCenter.x - bodyWidth / 2,
                              y: blueyCenter.y - bodyHeight / 2,
                              width: bodyWidth, height: bodyHeight)

        ctx.saveGState()
        let bodyPath = CGPath(ellipseIn: bodyRect, transform: nil)
        ctx.addPath(bodyPath)
        ctx.clip()

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = Palette.gradient.map { NSColor(hex: $0).cgColor } as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
                                   end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY), options: [])
        }

        ctx.setFillColor(NSColor(white: 1.0, alpha: 0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: bodyRect.minX + 3, y: bodyRect.maxY - 7, width: 6, height: 4))
        ctx.restoreGState()

        drawEyes(in: ctx, center: blueyCenter)
    }

    private var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    private func drawEyes(in ctx: CGContext, center: CGPoint) {
        let eyeWidth: CGFloat = 6.2
        let eyeHeight: CGFloat = 6.2
        let eyeSpacing: CGFloat = 6.8

        let leftEyeCenter = CGPoint(x: center.x - eyeSpacing / 2, y: center.y + 1)
        let rightEyeCenter = CGPoint(x: center.x + eyeSpacing / 2, y: center.y + 1)

        let isSleeping = (state == .locked) || (state == .idlePlay(phase: .sleeping))

        for eyeCenter in [leftEyeCenter, rightEyeCenter] {
            if isSleeping {
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                let arcPath = CGMutablePath()
                arcPath.move(to: CGPoint(x: eyeCenter.x - 3, y: eyeCenter.y - 0.5))
                arcPath.addQuadCurve(to: CGPoint(x: eyeCenter.x + 3, y: eyeCenter.y - 0.5),
                                     control: CGPoint(x: eyeCenter.x, y: eyeCenter.y - 2.5))
                ctx.addPath(arcPath)
                ctx.strokePath()
                ctx.restoreGState()
            } else if isBlinking {
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: eyeCenter.x - 2.8, y: eyeCenter.y))
                ctx.addLine(to: CGPoint(x: eyeCenter.x + 2.8, y: eyeCenter.y))
                ctx.strokePath()
                ctx.restoreGState()
            } else {
                let eyeRect = CGRect(x: eyeCenter.x - eyeWidth / 2,
                                     y: eyeCenter.y - eyeHeight / 2,
                                     width: eyeWidth, height: eyeHeight)
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: eyeRect)

                guard let window = self.window else { ctx.restoreGState(); continue }
                let windowOrigin = window.frame.origin
                let eyeScreenPoint = CGPoint(x: windowOrigin.x + eyeCenter.x,
                                             y: windowOrigin.y + eyeCenter.y)

                let dx = mouseLocation.x - eyeScreenPoint.x
                let dy = mouseLocation.y - eyeScreenPoint.y
                let dist = max(1.0, hypot(dx, dy))

                let maxOffset: CGFloat = 1.4
                let normX = (dx / dist) * maxOffset
                let normY = (dy / dist) * maxOffset

                let pupilRadius: CGFloat = 1.6
                let pupilRect = CGRect(x: eyeCenter.x + normX - pupilRadius,
                                       y: eyeCenter.y + normY - pupilRadius,
                                       width: pupilRadius * 2, height: pupilRadius * 2)

                ctx.setFillColor(NSColor(hex: Palette.ink).cgColor)
                ctx.fillEllipse(in: pupilRect)

                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: pupilRect.minX + 0.5, y: pupilRect.maxY - 1.2, width: 0.8, height: 0.8))
                ctx.restoreGState()
            }
        }
    }

    // MARK: - Compact Mode: Study Status Pill

    private func drawCompactStudyPill(in ctx: CGContext) {
        let label = BlueyState.shared.focusStatus == "No focus session" ? "Bluey · ready" : BlueyState.shared.focusStatus
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(white: 0.88, alpha: 1)])
        text.draw(with: CGRect(x: 50, y: bounds.height - 24, width: bounds.width - 90, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        NSAttributedString(string: "↗", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 0.7, alpha: 1)])
            .draw(at: CGPoint(x: bounds.width - 28, y: bounds.height - 25))
    }

    // MARK: - Music Dynamic Island

    private func drawMusicIsland(in ctx: CGContext, expanded: Bool) {
        let track = NowPlayingService.shared.currentTrack
        let title = track?.title ?? "Playing Audio"
        let artist = track?.artist ?? "Music"

        if !expanded {
            // Compact Island: [Bluey] [Title • Artist] [|||| Equalizer]
            let textRect = CGRect(x: 48, y: bounds.height - 24, width: bounds.width - 98, height: 16)
            let text = "\(title) • \(artist)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            str.draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

            drawEqualizerBars(in: ctx, origin: CGPoint(x: bounds.width - 36, y: bounds.height - 23))
        } else {
            // Expanded Island: Track + Artist + Media Buttons + Equalizer
            let titleRect = CGRect(x: 48, y: bounds.height - 25, width: bounds.width - 100, height: 16)
            let titleStr = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            titleStr.draw(with: titleRect, options: [.truncatesLastVisibleLine])

            let artistRect = CGRect(x: 48, y: bounds.height - 40, width: bounds.width - 100, height: 14)
            let artistStr = NSAttributedString(string: artist, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: NSColor(white: 0.72, alpha: 1.0)
            ])
            artistStr.draw(with: artistRect, options: [.truncatesLastVisibleLine])

            // Media Control Buttons (backward, play/pause, forward) with pill backdrops
            drawMediaButton(in: ctx, rect: CGRect(x: 175, y: 8, width: 30, height: 24), systemSymbol: "backward.fill", isHovered: hoveredButton == "prev")
            drawMediaButton(in: ctx, rect: CGRect(x: 215, y: 8, width: 34, height: 24),
                            systemSymbol: track?.isPlaying == true ? "pause.fill" : "play.fill",
                            isHovered: hoveredButton == "play", isProminent: true)
            drawMediaButton(in: ctx, rect: CGRect(x: 258, y: 8, width: 30, height: 24), systemSymbol: "forward.fill", isHovered: hoveredButton == "next")

            // Equalizer on the right
            drawEqualizerBars(in: ctx, origin: CGPoint(x: bounds.width - 38, y: 14))
        }
    }

    private func drawMediaButton(in ctx: CGContext, rect: CGRect, systemSymbol: String, isHovered: Bool, isProminent: Bool = false) {
        ctx.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)

        if isProminent {
            ctx.setFillColor(NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.94, alpha: isHovered ? 0.95 : 0.85).cgColor)
        } else {
            ctx.setFillColor(NSColor(white: isHovered ? 0.35 : 0.18, alpha: 0.75).cgColor)
        }
        ctx.fillPath()
        ctx.restoreGState()

        if let img = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: systemSymbol) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            let configured = img.withSymbolConfiguration(config) ?? img
            let iconSize = CGSize(width: 13, height: 13)
            let iconRect = CGRect(x: rect.midX - iconSize.width / 2, y: rect.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
            configured.draw(in: iconRect)
        }
    }

    // MARK: - Hermes Study Insight Island

    private func drawStudyInsightIsland(in ctx: CGContext) {
        let profile = StudyLearner.shared.profile

        // Top Row: Header + Streak
        let titleRect = CGRect(x: 50, y: bounds.height - 24, width: bounds.width - 150, height: 16)
        let titleStr = NSAttributedString(string: "🧠 Study Memory • Hermes Agent", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor(hex: Palette.berry1)
        ])
        titleStr.draw(with: titleRect, options: [.truncatesLastVisibleLine])

        let streakRect = CGRect(x: bounds.width - 86, y: bounds.height - 24, width: 76, height: 16)
        let streakStr = NSAttributedString(string: "🔥 \(profile.streakDays)d streak", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        streakStr.draw(with: streakRect, options: [.truncatesLastVisibleLine])

        // Bottom Area: Synthesized Reflection (48pt height with 2pt line spacing fits 3 full lines cleanly)
        let insight = profile.synthesizedInsight.isEmpty ?
            "Focus: \(Int(profile.totalFocusMinutes))m • Endurance: ~\(Int(profile.averageEnduranceMinutes))m" : profile.synthesizedInsight

        let insightRect = CGRect(x: 50, y: 10, width: bounds.width - 64, height: 48)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        let insightStr = NSAttributedString(string: insight, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.88, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ])
        insightStr.draw(with: insightRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    // MARK: - Listening Island

    private func drawListeningIsland(in ctx: CGContext, caption: String) {
        let display = caption.isEmpty ? "Listening… Speak now 🎙️" : caption
        let textRect = CGRect(x: 48, y: bounds.height - 24, width: bounds.width - 92, height: 16)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: display, attributes: attrs)
        str.draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

        if BlueyState.shared.listening { drawEqualizerBars(in: ctx, origin: CGPoint(x: bounds.width - 36, y: bounds.height - 23)) }
        else {
            let symbol = NSImage(systemSymbolName: BlueyState.shared.warning != nil ? "exclamationmark.circle" : "ellipsis", accessibilityDescription: "Open Bluey")
            symbol?.draw(in: CGRect(x: bounds.width - 31, y: bounds.height - 25, width: 16, height: 16))
        }
    }

    private func drawEqualizerBars(in ctx: CGContext, origin: CGPoint) {
        let barWidth: CGFloat = 2.4
        let spacing: CGFloat = 2.0
        let maxHeight: CGFloat = 13

        ctx.saveGState()
        for (i, val) in eqBars.enumerated() {
            let h = max(2.5, val * maxHeight)
            let rect = CGRect(x: origin.x + CGFloat(i) * (barWidth + spacing),
                              y: origin.y,
                              width: barWidth, height: h)
            ctx.setFillColor(NSColor(hex: Palette.berry1).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: - Zzz Particles & Emojis

    private func drawZzz(in ctx: CGContext) {
        for p in zzzParticles {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: p.size, weight: .bold),
                .foregroundColor: NSColor(hex: Palette.berry1, alpha: p.alpha)
            ]
            let str = NSAttributedString(string: "z", attributes: attrs)
            str.draw(at: CGPoint(x: p.x, y: p.y))
        }
    }

    private func drawReactionEmoji(in ctx: CGContext) {
        guard let emoji = popEmoji else { return }
        let center = CGPoint(x: bounds.midX - 10, y: bounds.height - 10 + popEmojiY)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor(white: 1.0, alpha: popEmojiAlpha)
        ]
        let str = NSAttributedString(string: emoji, attributes: attrs)
        str.draw(at: center)
    }
}
