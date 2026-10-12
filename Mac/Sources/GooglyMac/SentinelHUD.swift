import AppKit
import GooglyShared

/// The warning card.
///
/// When the Sentinel thinks the user has drifted, this slides in from the top of the screen and
/// counts down. The countdown is the point: nothing closes without warning, and the user can send
/// Bluey away with one keystroke, one click, or by simply going back to work — all three cancel it.
@MainActor
final class SentinelHUD {
    private var window: NSWindow?
    private var panel: PanelView?
    /// Called when the countdown finishes or the user accepts immediately.
    var onAccept: (() -> Void)?
    /// Called when the user dismisses the warning.
    var onDismiss: (() -> Void)?

    private var countdownTimer: Timer?
    private var secondsLeft: Double = 0

    /// Show the card. `onAccept` fires when the countdown runs out (enforcement proceeds);
    /// `onDismiss` fires if the user waves it away in time.
    func warn(title: String, detail: String, action: String, seconds: Double,
              onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onAccept = onAccept
        self.onDismiss = onDismiss

        let panel = panel ?? makePanel()
        panel.configure(headline: title, detail: detail, action: action, seconds: seconds)
        self.panel = panel

        // A grabbable card sits over everything until the countdown ends.
        window?.orderFrontRegardless()

        secondsLeft = seconds
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.secondsLeft -= 0.1
                panel.update(secondsLeft: max(0, self.secondsLeft))
                if self.secondsLeft <= 0 {
                    timer.invalidate()
                    self.fireAccept()
                }
            }
        }
    }

    /// Take the card down without enforcing anything.
    func dismiss() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        window?.orderOut(nil)
        panel = nil
        window = nil
    }

    private func fireAccept() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        let accept = onAccept
        onAccept = nil
        onDismiss = nil
        accept?()
    }

    private func makePanel() -> PanelView {
        guard let screen = NSScreen.screens.first else { return PanelView(frame: .zero) }
        let width: CGFloat = 460
        let height: CGFloat = 132
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - height - 24,
                           width: width, height: height)

        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The card is clickable (to accept) while the rest of the screen stays untouched.
        window.ignoresMouseEvents = false

        let panel = PanelView(frame: NSRect(origin: .zero, size: frame.size))
        panel.onAccept = { [weak self] in self?.fireAccept() }
        panel.onDismiss = { [weak self] in
            self?.onDismiss?()
            self?.dismiss()
        }
        window.contentView = panel
        self.window = window
        return panel
    }

    // MARK: - Card

    final class PanelView: NSView {
        var onAccept: (() -> Void)?
        var onDismiss: (() -> Void)?

        private let headline = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private let actionLabel = NSTextField(labelWithString: "")
        private let acceptButton = NSButton()
        private let stayButton = NSButton()
        private var progress: Double = 1

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 18
            layer?.masksToBounds = true
            build()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        private func build() {
            headline.font = Fonts.display(17)
            headline.textColor = .white
            headline.lineBreakMode = .byTruncatingTail
            detail.font = .systemFont(ofSize: 12.5)
            detail.textColor = NSColor(hex: Palette.berry1, alpha: 0.92)
            detail.lineBreakMode = .byTruncatingTail
            actionLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
            actionLabel.textColor = NSColor(hex: Palette.inkSoft)

            acceptButton.title = "Do it now"
            acceptButton.bezelStyle = .rounded
            acceptButton.target = self
            acceptButton.action = #selector(acceptTapped)
            stayButton.title = "I'm back — stay"
            stayButton.bezelStyle = .rounded
            stayButton.keyEquivalent = "\u{1b}" // esc
            stayButton.target = self
            stayButton.action = #selector(stayTapped)

            for view in [headline, detail, actionLabel, acceptButton, stayButton] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }

            NSLayoutConstraint.activate([
                headline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
                headline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
                headline.topAnchor.constraint(equalTo: topAnchor, constant: 16),

                detail.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: headline.trailingAnchor),
                detail.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 4),

                actionLabel.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
                actionLabel.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),

                stayButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                stayButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
                acceptButton.trailingAnchor.constraint(equalTo: stayButton.leadingAnchor, constant: -8),
                acceptButton.centerYAnchor.constraint(equalTo: stayButton.centerYAnchor),
                actionLabel.centerYAnchor.constraint(equalTo: stayButton.centerYAnchor),
                actionLabel.trailingAnchor.constraint(lessThanOrEqualTo: acceptButton.leadingAnchor, constant: -10),
            ])
        }

        func configure(headline text: String, detail detailText: String, action: String, seconds: Double) {
            headline.stringValue = text
            detail.stringValue = detailText
            actionLabel.stringValue = action
            progress = 1
            needsDisplay = true
        }

        func update(secondsLeft: Double) {
            actionLabel.stringValue = actionLabel.stringValue.replacingOccurrences(
                of: #"\s*\(\d+s\)$"#, with: "", options: .regularExpression)
            progress = max(0, min(1, secondsLeft / max(1, Settings.shared.warnSeconds)))
            needsDisplay = true
        }

        @objc private func acceptTapped() { onAccept?() }
        @objc private func stayTapped() { onDismiss?() }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20)

            // 1. Dark acrylic obsidian fill (matches Dynamic Notch & Apple system alerts)
            NSColor(white: 0.08, alpha: 0.94).setFill()
            path.fill()

            // 2. Subtle specular gloss gradient along top edge
            let glossRect = NSRect(x: 0, y: bounds.height - 30, width: bounds.width, height: 30)
            let glossGradient = NSGradient(colors: [
                NSColor(white: 1.0, alpha: 0.12),
                NSColor(white: 1.0, alpha: 0.0)
            ])
            glossGradient?.draw(in: glossRect, angle: 270)

            // 3. Smooth drain countdown progress bar
            let barHeight: CGFloat = 3.5
            let barY: CGFloat = 0
            let trackPath = NSBezierPath(rect: NSRect(x: 0, y: barY, width: bounds.width, height: barHeight))
            NSColor(white: 1.0, alpha: 0.10).setFill()
            trackPath.fill()

            if progress > 0 {
                let bar = NSRect(x: 0, y: barY, width: bounds.width * progress, height: barHeight)
                let warnGradient = NSGradient(colors: [
                    NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.13, alpha: 0.95), // amber
                    NSColor(calibratedRed: 0.93, green: 0.27, blue: 0.31, alpha: 0.95)  // coral
                ])
                warnGradient?.draw(in: bar, angle: 0)
            }

            // 4. Subtle titanium rim stroke
            NSColor(white: 1.0, alpha: 0.16).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
    }
}