import AppKit

@MainActor
final class DockCompanion {
    static let shared = DockCompanion()
    private var timer: Timer?
    private var wasActive = false
    private var completedUntil: Date?
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
        if wasActive && !clock.isActive { completedUntil = Date().addingTimeInterval(4) }
        wasActive = clock.isActive
        let completed = completedUntil.map { $0 > Date() } ?? false
        let paused = coordinator.paused
        let elapsed = clock.elapsed()
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
            NSColor(calibratedRed: 0.92, green: 0.94, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 112, height: 112), xRadius: 28, yRadius: 28).fill()
            NSColor(calibratedRed: 0.35, green: 0.43, blue: 0.79, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 31, y: 31, width: 66, height: 63)).fill()
            NSColor(calibratedRed: 0.43, green: 0.65, blue: 0.47, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 63, y: 89, width: 22, height: 11)).fill()
            for x in [CGFloat(44), CGFloat(70)] {
                NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: 59, width: 15, height: 17)).fill()
                NSColor.darkGray.setFill(); NSBezierPath(ovalIn: NSRect(x: x + 5, y: 63, width: 6, height: 9)).fill()
            }
            if clock.isActive || completed {
                let ring = NSBezierPath(ovalIn: NSRect(x: 14, y: 14, width: 100, height: 100))
                ring.lineWidth = 5
                NSColor(calibratedWhite: 0.65, alpha: 0.25).setStroke(); ring.stroke()
                // Count-up activity rotates once per minute; the badge carries actual elapsed time.
                let arc = NSBezierPath()
                let angle = CGFloat(elapsed.truncatingRemainder(dividingBy: 60) / 60 * 360)
                arc.appendArc(withCenter: NSPoint(x: 64, y: 64), radius: 50, startAngle: 90, endAngle: completed ? -270 : 90 - max(12, angle), clockwise: true)
                arc.lineWidth = 5; arc.lineCapStyle = .round
                (paused ? NSColor.systemOrange : NSColor.systemIndigo).setStroke(); arc.stroke()
            }
            return true
        }
        NSApp.applicationIconImage = image
        NSApp.dockTile.badgeLabel = ExecutionGate.shared.isStopped ? "STOP" : (completed ? "✓" : (clock.isActive ? (paused ? "Ⅱ" : "\(Int(elapsed / 60))m") : nil))
        NSApp.dockTile.display()
    }
}
