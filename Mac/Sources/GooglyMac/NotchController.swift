import AppKit
import Foundation
import GooglyShared

/// Coordinates the Virtual Notch Nest window, Bluey character lifecycle, idle play, and music island.
@MainActor
final class NotchController {
    static let shared = NotchController()

    private var window: NSWindow?
    private var notchView: NotchView?
    private var idleCheckTimer: Timer?
    private var bungeeTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    private var isBungeeDropping = false
    private var bungeeY: CGFloat = 0
    private var bungeeDir: CGFloat = 1

    private(set) var isRunning = false

    func start() {
        guard Settings.shared.notchEnabled else { return }
        guard window == nil else { return }

        isRunning = true

        let view = NotchView(frame: NSRect(origin: .zero, size: NotchState.compact.size))
        let win = makeWindow(contentView: view)
        self.notchView = view
        self.window = win

        // Hook up interactions
        view.onBlueyTapped = { [weak self] in
            self?.handleBlueyTapped()
        }
        view.onPlayPauseTapped = {
            NowPlayingService.shared.togglePlayPause()
        }
        view.onNextTapped = {
            NowPlayingService.shared.nextTrack()
        }
        view.onPreviousTapped = {
            NowPlayingService.shared.previousTrack()
        }
        view.onStudyTapped = { [weak self] in
            self?.handleStudyTapped()
        }
        view.onHoverStateChanged = { [weak self] hovered in
            self?.handleHoverChanged(hovered)
        }

        // Start subsystems. The callback must be wired BEFORE start(): start() kicks off an
        // immediate query, and assigning onChange afterwards threw its result away, so the music
        // island only appeared on the following 1.5s poll.
        NowPlayingService.shared.onChange = { [weak self] track in
            self?.handleTrackChanged(track)
        }
        NowPlayingService.shared.start()
        LockScreenObserver.shared.onLockStateChanged = { [weak self] locked in
            self?.handleLockChanged(locked)
        }
        LockScreenObserver.shared.onDisplaySleep = { [weak self] asleep in
            self?.handleDisplaySleep(asleep)
        }
        LockScreenObserver.shared.start()

        // Screen change listener (resolution, safe area, external displays)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let notchView = self.notchView else { return }
                self.updatePosition(size: notchView.state.size, animated: false)
                notchView.needsDisplay = true
                notchView.updateTrackingAreas()
                self.window?.orderFrontRegardless()
            }
        }

        // Idle check loop
        idleCheckTimer?.invalidate()
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdlePlay() }
        }

        updatePosition(size: NotchState.compact.size, animated: false)
        win.orderFrontRegardless()
    }

    func stop() {
        isRunning = false
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        bungeeTimer?.invalidate()
        bungeeTimer = nil

        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }

        NowPlayingService.shared.stop()
        LockScreenObserver.shared.stop()

        window?.orderOut(nil)
        window = nil
        notchView = nil
    }

    func refreshPresentation() {
        let state = BlueyState.shared
        let desired: NotchState
        switch NotchPresentation.choose(warning: state.warning != nil, busy: state.busy, listening: state.listening) {
        case .warning: desired = .listening(caption: "Focus warning · click to review")
        case .task: desired = .listening(caption: state.taskStatus)
        case .listening: desired = .listening(caption: state.transcript.isEmpty ? "Listening…" : state.transcript)
        case .passive:
            desired = Settings.shared.notchMusicEnabled && !Settings.shared.notchCoexistence && NowPlayingService.shared.currentTrack != nil ? .music : .compact
        }
        setState(desired)
        refreshLayout()
    }

    // MARK: - Window Configuration

    private var targetScreen: NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    private func makeWindow(contentView: NSView) -> NSWindow {
        let screen = targetScreen
        let initialSize = NotchState.compact.size
        let geometry = NotchGeometry(
            screen: screen,
            preference: Settings.shared.notchCoexistence ? .floating : Settings.shared.notchSilhouette,
            floatingGap: Settings.shared.notchCoexistence ? max(40, screen.safeAreaInsets.top + 12) : Settings.shared.notchFloatingGap
        )
        let frame = geometry.windowFrame(for: initialSize)

        let win = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isFloatingPanel = true
        win.hidesOnDeactivate = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = false
        win.contentView = contentView
        return win
    }

    private func updatePosition(size: CGSize, animated: Bool = true) {
        guard let window else { return }
        let screen = targetScreen

        let geometry = NotchGeometry(
            screen: screen,
            preference: Settings.shared.notchCoexistence ? .floating : Settings.shared.notchSilhouette,
            floatingGap: Settings.shared.notchCoexistence ? max(40, screen.safeAreaInsets.top + 12) : Settings.shared.notchFloatingGap
        )
        let targetFrame = geometry.windowFrame(for: size)

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                // Smooth spring-like easeOutQuart curve matching Vorssaint
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.0, 0.5, 1.0)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }

    // MARK: - State Management

    private func setState(_ candidate: NotchState, animated: Bool = true) {
        guard let notchView else { return }
        let shared = BlueyState.shared
        let newState: NotchState
        if LockScreenObserver.shared.isLocked { newState = .locked }
        else {
            switch NotchPresentation.choose(warning: shared.warning != nil, busy: shared.busy, listening: shared.listening) {
            case .warning: newState = .listening(caption: "Focus warning · click to review")
            case .task: newState = .listening(caption: shared.taskStatus)
            case .listening: newState = .listening(caption: shared.transcript.isEmpty ? "Listening…" : shared.transcript)
            case .passive: newState = candidate
            }
        }
        guard notchView.state != newState else { return }
        notchView.state = newState
        updatePosition(size: newState.size, animated: animated)
    }

    private func handleTrackChanged(_ track: NowPlayingService.TrackInfo?) {
        guard Settings.shared.notchMusicEnabled, !Settings.shared.notchCoexistence else { return }
        guard !LockScreenObserver.shared.isLocked else { return }

        // Don't interrupt study insights, and don't collapse the island while the user has it
        // expanded to use the controls. Collapsing on a pause shrank the window out from under the
        // cursor: the expanded tracking area was replaced, mouseExited fired, and mouseEntered never
        // did — so the hover controls stayed dead until the pointer left and came back.
        if case .studyInsight = notchView?.state { return }
        if case .musicExpanded = notchView?.state { return }

        // A track that is merely paused still deserves an island, so the play button stays reachable.
        if track != nil {
            setState(.music)
        } else {
            setState(.compact)
        }
    }

    private func handleLockChanged(_ locked: Bool) {
        guard Settings.shared.notchOnLockScreen else {
            // The notch window lives at .screenSaver level on every space, so it draws over the lock
            // screen whatever this setting says. Hiding it is the only way "show on lock screen"
            // (off) can actually mean anything — and it also prevents a stale island, such as an
            // expanded music player, being left displayed on a locked screen.
            if locked {
                window?.orderOut(nil)
            } else {
                window?.orderFrontRegardless()
                if NowPlayingService.shared.currentTrack != nil, Settings.shared.notchMusicEnabled {
                    setState(.music)
                } else {
                    setState(.compact)
                }
            }
            return
        }
        if locked {
            stopBungee()
            setState(.locked)
        } else {
            if let _ = NowPlayingService.shared.currentTrack, Settings.shared.notchMusicEnabled {
                setState(.music)
            } else {
                setState(.compact)
            }
        }
    }

    /// Display sleep is not a lock event, so this only pauses the character's animation while the
    /// screen is off; lock state is driven separately by handleLockChanged.
    private func handleDisplaySleep(_ asleep: Bool) {
        guard Settings.shared.notchOnLockScreen == false else { return }
        if asleep {
            window?.orderOut(nil)
        } else if !LockScreenObserver.shared.isLocked {
            window?.orderFrontRegardless()
        }
    }

    private func handleHoverChanged(_ hovered: Bool) {
        guard !LockScreenObserver.shared.isLocked else { return }

        if case .music = notchView?.state, hovered {
            setState(.musicExpanded)
        } else if case .musicExpanded = notchView?.state, !hovered {
            setState(.music)
        }
    }

    private func handleStudyTapped() { BlueyWorkspace.shared.show() }

    func showStudyInsights() {
        BlueyWorkspace.shared.show()
        BlueyState.shared.workspacePage = "Study memory"
    }

    /// Dynamically recalculates and animates notch frame when focus goal, locked target, or settings update
    func refreshLayout() {
        guard isRunning, let notchView else { return }
        updatePosition(size: notchView.state.size, animated: true)
        notchView.needsDisplay = true
    }

    func setListening(caption: String) {
        guard isRunning else { return }
        stopBungee()
        setState(.listening(caption: caption))
    }

    func finishListening() {
        guard isRunning else { return }
        refreshPresentation()
        return
    }

    private func handleBlueyTapped() {
        if BlueyState.shared.busy || BlueyState.shared.warning != nil { BlueyWorkspace.shared.show(); return }
        if Settings.shared.macMicEnabled {
            MacVoiceInput.shared.toggleListening()
            if MacVoiceInput.shared.isListening {
                return
            }
        }
        BlueyWorkspace.shared.show()
    }

    // MARK: - Idle Playfulness & Funny Activities

    private func checkIdlePlay() {
        guard Settings.shared.notchIdlePlayEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !BlueyState.shared.busy, !BlueyState.shared.listening, BlueyState.shared.warning == nil else { return }
        guard !LockScreenObserver.shared.isLocked else { return }
        guard NowPlayingService.shared.currentTrack == nil else { return }
        if case .studyInsight = notchView?.state { return }

        let idle = ScreenContext.idleSeconds

        // User returned to keyboard / mouse: immediately end idle play
        if idle < 2.0 {
            if case .idlePlay = notchView?.state {
                stopBungee()
                setState(.compact)
            }
            return
        }

        // Idle for >= 45s: Bluey falls sound asleep!
        if idle >= 45.0 {
            stopBungee()
            setState(.idlePlay(phase: .sleeping))
            return
        }

        // Idle for >= 18s: Bluey does cute Bungee drop or Peeks
        if idle >= 18.0 && notchView?.state == .compact && !isBungeeDropping {
            startBungeeDrop()
        }
    }

    private func startBungeeDrop() {
        guard !isBungeeDropping else { return }
        isBungeeDropping = true
        bungeeY = 0
        bungeeDir = 1

        setState(.idlePlay(phase: .bungee(dropY: 0)))

        bungeeTimer?.invalidate()
        bungeeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.bungeeY += self.bungeeDir * 1.5
                if self.bungeeY >= 28 {
                    self.bungeeDir = -1
                } else if self.bungeeY <= 0 && self.bungeeDir == -1 {
                    self.stopBungee()
                    self.setState(.compact)
                } else {
                    self.notchView?.state = .idlePlay(phase: .bungee(dropY: self.bungeeY))
                    self.notchView?.needsDisplay = true
                }
            }
        }
    }

    private func stopBungee() {
        bungeeTimer?.invalidate()
        bungeeTimer = nil
        isBungeeDropping = false
        bungeeY = 0
    }
}
