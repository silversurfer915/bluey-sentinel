import AppKit

/// Count-up activity never implies a percentage of a fixed goal.
enum DockProgressPresentation {
    static func angle(elapsed: Double, planned: Int, countUp: Bool) -> Double {
        countUp ? 24 : min(max(0, elapsed) / Double(max(1, planned)), 1) * 360
    }
    static func celebrates(wasActive: Bool, isActive: Bool, termination: String?) -> Bool {
        wasActive && !isActive && termination == "finish"
    }
}

@MainActor
final class DockCompanion {
    static let shared = DockCompanion()
    private var timer: Timer?
    private var wasActive = false
    private var completedUntil: Date?
    private var masterIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "bluey-mac-1024", withExtension: "png"), let img = NSImage(contentsOf: url) {
            return img
        }
        let devPaths = [
            "Shared/Assets/bluey-mac-1024.png",
            "Mac/Resources/AppIcon.icns",
            "Shared/Assets/bluey-logo-1024.png"
        ]
        for path in devPaths {
            if FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }()

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        refresh()
    }

    func refresh() {
        let coordinator = BlueyCoordinator.shared
        let clock = coordinator.focusClock
        if DockProgressPresentation.celebrates(wasActive: wasActive, isActive: clock.isActive, termination: coordinator.lastTermination) { completedUntil = Date().addingTimeInterval(4) }
        wasActive = clock.isActive
        let completed = completedUntil.map { $0 > Date() } ?? false
        let paused = coordinator.paused
        let elapsed = clock.elapsed()

        if clock.isActive || completed {
            let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { [weak self] rect in
                if let master = self?.masterIcon {
                    master.draw(in: rect)
                } else {
                    NSColor(calibratedRed: 0.26, green: 0.33, blue: 0.84, alpha: 1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 14, y: 14, width: 100, height: 100), xRadius: 22, yRadius: 22).fill()
                }

                // Semi-transparent halo track
                let track = NSBezierPath(ovalIn: NSRect(x: 10, y: 10, width: 108, height: 108))
                track.lineWidth = 4
                NSColor(calibratedWhite: 1.0, alpha: 0.35).setStroke()
                track.stroke()

                // Active count-up progress arc
                let arc = NSBezierPath()
                let canonical = SanctraSync.shared.activeCanonicalSession
                let planned = canonical?.plannedDurationSeconds ?? coordinator.plannedSeconds
                let countUp = canonical?.mode == "stopwatch" || canonical == nil
                let angle = CGFloat(DockProgressPresentation.angle(elapsed: elapsed, planned: planned, countUp: countUp))
                arc.appendArc(withCenter: NSPoint(x: 64, y: 64), radius: 54, startAngle: 90, endAngle: completed ? -270 : 90 - max(12, angle), clockwise: true)
                arc.lineWidth = 4
                arc.lineCapStyle = .round
                (paused ? NSColor.systemOrange : NSColor.systemBlue).setStroke()
                arc.stroke()
                return true
            }
            NSApp.applicationIconImage = image
        } else {
            // Restore default crisp bundle app icon
            if NSApp.applicationIconImage != nil {
                NSApp.applicationIconImage = nil
            }
        }

        NSApp.dockTile.badgeLabel = ExecutionGate.shared.isStopped ? "STOP" : (completed ? "✓" : (clock.isActive ? (paused ? "Ⅱ" : "\(Int(elapsed / 60))m") : nil))
        NSApp.dockTile.display()
    }
}
