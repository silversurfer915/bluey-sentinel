import AppKit
import Foundation

/// Observes macOS lock screen and sleep/wake events to let Bluey guard the screen while locked.
@MainActor
final class LockScreenObserver {
    static let shared = LockScreenObserver()

    private(set) var isLocked = false
    var onLockStateChanged: ((Bool) -> Void)?
    /// Fires when the *displays* sleep or wake. This is not the same thing as locking, so it is
    /// reported separately rather than being folded into `isLocked`.
    var onDisplaySleep: ((Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }

        let dist = DistributedNotificationCenter.default()

        // 1. Screen Locked
        let lockObs = dist.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setLocked(true) }
        }
        observers.append(lockObs)

        // 2. Screen Unlocked
        let unlockObs = dist.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setLocked(false) }
        }
        observers.append(unlockObs)

        // 3. Display sleep / wake — deliberately NOT treated as lock/unlock.
        //    Waking the display on a locked Mac fires screensDidWake while the user is still at the
        //    lock screen, and displays can sleep without the Mac ever locking. Treating these as lock
        //    events made Bluey jump out of the lock-screen state while the machine was still locked
        //    (and created phantom "locked" states). Lock state now comes only from the two
        //    authenticated notifications above; this is reported as a separate display signal.
        let wsCenter = NSWorkspace.shared.notificationCenter
        let sleepObs = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onDisplaySleep?(true) }
        }
        observers.append(sleepObs)

        let wakeObs = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onDisplaySleep?(false) }
        }
        observers.append(wakeObs)
    }

    func stop() {
        for obs in observers {
            DistributedNotificationCenter.default().removeObserver(obs)
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        observers.removeAll()
    }

    private func setLocked(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
        onLockStateChanged?(locked)
    }
}
