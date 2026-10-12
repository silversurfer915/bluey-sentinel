import AppKit
import ApplicationServices
import Foundation

enum FocusChangeTrigger: String {
    case appSwitch = "App Switch"
    case windowChanged = "Window Focus"
    case titleChanged = "Window/Tab Title"
    case tabOrURLChanged = "Tab / URL Change"
    case targetLost = "Locked Target Lost"
    case safetyNetPoll = "Safety Net Poll"
}

/// Real-time, event-driven observer for frontmost application switches, window changes,
/// browser tab switches, and URL navigation across macOS.
@MainActor
final class FocusWatcher {
    static let shared = FocusWatcher()

    private var running = false
    private var activePID: pid_t?
    private var axObserver: AXObserver?
    private var axRunLoopSource: CFRunLoopSource?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var safetyNetTimer: Timer?
    private var lastProbe: FocusProbe?
    private var lastPollAt: Date = .distantPast

    var onContextChange: ((FocusChangeTrigger, FocusProbe) -> Void)?
    var onPermissionLoss: ((String) -> Void)?

    init() {}

    var isRunning: Bool { running }

    // MARK: - Lifecycle

    func start(
        onContextChange: @escaping (FocusChangeTrigger, FocusProbe) -> Void,
        onPermissionLoss: @escaping (String) -> Void
    ) {
        guard !running else { return }
        self.onContextChange = onContextChange
        self.onPermissionLoss = onPermissionLoss
        self.running = true
        self.lastProbe = nil
        self.lastPollAt = Date()

        checkPermissions()
        setupWorkspaceObservers()

        if let front = NSWorkspace.shared.frontmostApplication {
            attachAXObserver(pid: front.processIdentifier)
        }

        // Lightweight poll (every 1.5s) as a safety net in case an event is missed
        safetyNetTimer?.invalidate()
        safetyNetTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollSafetyNet()
            }
        }

        // Initial instant probe
        Task { @MainActor in
            let initial = await ScreenContext.probe()
            self.lastProbe = initial
            onContextChange(.appSwitch, initial)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        safetyNetTimer?.invalidate()
        safetyNetTimer = nil

        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        detachAXObserver()
        activePID = nil
        lastProbe = nil
    }

    // MARK: - Permission Verification

    func checkPermissions() {
        if !AXIsProcessTrusted() {
            let msg = "Focus Sentinel requires Accessibility permission to observe window focus in real time. Please enable Bluey in System Settings > Privacy & Security > Accessibility."
            onPermissionLoss?(msg)
        }
    }

    // MARK: - Workspace Notifications

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let didActivate = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self = self, self.running else { return }
                await self.handleAppSwitch(to: app)
            }
        }
        workspaceObservers.append(didActivate)

        let didUnhide = center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.running else { return }
                await self.forceProbe(trigger: .windowChanged)
            }
        }
        workspaceObservers.append(didUnhide)
    }

    private func handleAppSwitch(to app: NSRunningApplication) async {
        let pid = app.processIdentifier
        if pid != activePID {
            detachAXObserver()
            attachAXObserver(pid: pid)
        }
        await forceProbe(trigger: .appSwitch)
    }

    // MARK: - Accessibility (AXObserver)

    private func attachAXObserver(pid: pid_t) {
        activePID = pid

        var observer: AXObserver?
        let callback: AXObserverCallback = { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let notifName = notification as String
            Task { @MainActor in
                watcher.handleAXEvent(name: notifName)
            }
        }

        let err = AXObserverCreate(pid, callback, &observer)
        guard err == .success, let observer = observer else {
            // Some system dialogs or sandboxed helpers may refuse AXObserverCreate.
            // Safety-net timer provides seamless fallback.
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let notifications: [CFString] = [
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXFocusedUIElementChangedNotification as CFString
        ]

        for notif in notifications {
            AXObserverAddNotification(observer, appElement, notif, refcon)
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.axObserver = observer
        self.axRunLoopSource = source
    }

    private func detachAXObserver() {
        if axObserver != nil, let source = axRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.axObserver = nil
            self.axRunLoopSource = nil
        }
    }

    private func handleAXEvent(name: String) {
        guard running else { return }
        let trigger: FocusChangeTrigger
        switch name {
        case (kAXTitleChangedNotification as String):
            trigger = .titleChanged
        case (kAXFocusedWindowChangedNotification as String), (kAXMainWindowChangedNotification as String):
            trigger = .windowChanged
        default:
            trigger = .windowChanged
        }

        Task { @MainActor in
            await self.forceProbe(trigger: trigger)
        }
    }

    // MARK: - Probing & Event Dispatch

    /// Probes current screen state and immediately notifies Sentinel if changed.
    func forceProbe(trigger: FocusChangeTrigger) async {
        guard running else { return }
        let current = await ScreenContext.probe()

        // Check if anything meaningful changed: app, window title, tab URL, or window ID
        let changed = lastProbe == nil ||
            current.app != lastProbe?.app ||
            current.windowTitle != lastProbe?.windowTitle ||
            current.url != lastProbe?.url ||
            current.windowID != lastProbe?.windowID

        if changed {
            lastProbe = current
            lastPollAt = Date()
            onContextChange?(trigger, current)
        }
    }

    /// Lightweight periodic poll (safety net for background tab changes or dropped events).
    private func pollSafetyNet() async {
        guard running else { return }
        checkPermissions()
        let current = await ScreenContext.probe()

        let changed = lastProbe == nil ||
            current.app != lastProbe?.app ||
            current.windowTitle != lastProbe?.windowTitle ||
            current.url != lastProbe?.url ||
            current.windowID != lastProbe?.windowID

        if changed {
            lastProbe = current
            lastPollAt = Date()
            onContextChange?(.tabOrURLChanged, current)
        } else if Date().timeIntervalSince(lastPollAt) >= 3.0 {
            // Heartbeat poll for sustained drift confirmation
            lastPollAt = Date()
            onContextChange?(.safetyNetPoll, current)
        }
    }
}
