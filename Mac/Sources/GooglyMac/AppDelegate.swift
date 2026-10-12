import AppKit
import Carbon.HIToolbox
import GooglyShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let overlay = CursorOverlay()
    private let server = PhoneServer()
    private var sentinel: Sentinel { BlueyCoordinator.shared.sentinel }
    private var statusItem: NSStatusItem!
    /// Pending "close the listening caption" timer, kept so a new voice command can cancel it.
    private var finishListeningWorkItem: DispatchWorkItem?
    /// Writes the permission status file; stops itself once permissions are settled.
    private var statusTimer: Timer?
    private lazy var host = RealtimeHost(overlay: overlay)


    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        BlueyWorkspace.shared.show()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Proves the Sentinel's guard rails and quits. Never runs in normal use.
        if ProcessInfo.processInfo.environment["GOOGLY_DEMO_SENTINEL"] != nil {
            SentinelGuardTests.run()
        }
        BlueyCoordinator.shared.configure(overlay: overlay)
        BlueyCoordinator.shared.onCancelTask = { [weak self] in self?.host.cancelCurrentTask() }
        BlueyCoordinator.shared.onChange = { [weak self] in self?.refreshSentinelIcon() }
        SanctraSync.shared.start()
        BlueyWorkspace.shared.onAsk = { [weak self] question in
            BlueyWorkspace.shared.prepareForTask()
            let ticket = ExecutionGate.shared.ticket
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard ExecutionGate.shared.accepts(ticket) else { return }
                await self?.host.ask(question: question) { _ in }
            }
        }
        MacVoiceInput.shared.onError = { BlueyState.shared.answer = $0; BlueyWorkspace.shared.show() }
        installEditMenu()
        if ProcessInfo.processInfo.environment["BLUEY_INTEGRATION_CHECKS"] != nil {
            Task { await IntegrationChecks.run() }
            return
        }
        Fonts.registerBundled()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuIcon.make()
        statusItem.button?.toolTip = "Bluey"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.onFace = { [weak self] face in self?.server.send(face) }
        overlay.start()
        showDemoBubbleIfAsked()
        checkPermissions()
        if let path = ProcessInfo.processInfo.environment["GOOGLY_DEMO_TRANSCRIBE"], let audio = FileManager.default.contents(atPath: path) {
            // Transcribes an audio file into a throwaway notes folder, prints the lines and quits.
            Task {
                do {
                    let result = try await MeetingNotes.transcribe(audio: audio, session: "demo0000", index: 1, sessionStarted: Date())
                    for s in result.segments { print("[\(s.start)] \(s.speaker): \(s.text)") }
                    try? FileManager.default.removeItem(at: result.folder)
                } catch { print("failed:", error) }
                exit(0)
            }
        }
        if let question = ProcessInfo.processInfo.environment["GOOGLY_DEMO_RESEARCH"] {
            host.demoResearch(question, out: ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] ?? "/tmp/googly-report")
        }
        server.onPhonesChanged = { [weak self] names in
            self?.refreshIcon()
            if names.isEmpty, self?.host.awake == true { self?.host.setAwake(false) }
            // A phone just took over the conversation: stop the Mac microphone. Otherwise the local
            // recogniser kept capturing and could fire a command in the middle of a phone-driven
            // conversation — two conversations at once, and the mic indicator left on.
            if !names.isEmpty, MacVoiceInput.shared.isListening {
                MacVoiceInput.shared.stopListening(processCommand: false)
            }
        }
        server.onRequest = { [weak self] packet, reply in self?.host.handle(packet, reply: reply) }
        PhoneSessionManager.shared.onSnapshotChanged = { [weak self] snapshot in
            self?.server.broadcast(Packet(sessionSnapshot: snapshot))
        }
        server.start()
        host.onChange = { [weak self] in self?.refreshIcon() }
        host.onBroadcast = { [weak self] packet in self?.server.broadcast(packet) }
        Voice.shared.onSpeechFinished = { [weak self] in
            self?.server.broadcast(Packet(command: "speechDone"))
        }

        // ⌥Space wakes him up or puts him back to sleep (same as double tapping him on the phone).
        HotKeys.shared.register(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.toggleAwake() }
        // ⌃⌥P point here, ⌃⌥F follow mouse, ⌃⌥D stop pointing, ⌃⌥H hide, ⌃⌥T talk test.
        HotKeys.shared.register(keyCode: kVK_ANSI_P) { [weak self] in self?.pointHere() }

        HotKeys.shared.register(keyCode: kVK_ANSI_D) { [weak self] in self?.overlay.goHome() }
        HotKeys.shared.register(keyCode: kVK_ANSI_H) { [weak self] in self?.toggleShow() }
        // Native Mac Voice Input (direct voice commands when phone is not connected)
        MacVoiceInput.shared.onListeningChanged = { [weak self] isListening in
            BlueyState.shared.listening = isListening
            if isListening {
                self?.overlay.view.caption = "Listening… 🎙️ Speak now"
                self?.overlay.view.engine.awake = true
                NotchController.shared.setListening(caption: "Listening… Speak now 🎙️")
            } else {
                // Put him back to sleep too. Only `awake` was ever set, never cleared, so after any
                // voice command the character stayed visibly awake with no conversation running.
                self?.overlay.view.engine.awake = false
                NotchController.shared.finishListening()
            }
        }
        MacVoiceInput.shared.onPartialTranscript = { [weak self] partial in
            BlueyState.shared.transcript = partial
            self?.overlay.view.caption = "“\(partial)” 🎙️"
            NotchController.shared.setListening(caption: "“\(partial)”")
        }
        MacVoiceInput.shared.onCommandRecognized = { [weak self] question in
            guard let self else { return }
            self.overlay.view.caption = "“\(question)”"
            NotchController.shared.setListening(caption: "“\(question)” 🤔")
            // Cancellable, so starting a new voice command within 3 seconds doesn't have the stale
            // timer kill the new session's caption while it is still listening.
            self.finishListeningWorkItem?.cancel()
            Task { @MainActor in
                await self.host.ask(question: question) { _ in }
                let work = DispatchWorkItem { NotchController.shared.finishListening() }
                self.finishListeningWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
            }
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_V) { [weak self] in
            self?.triggerMacVoiceCommand()
        }
        // The menu has always advertised these three, but only the menu-open case worked because
        // they were never registered as global hotkeys. ⌃⌥L in particular is the headline action
        // for locking a focus target.
        HotKeys.shared.register(keyCode: kVK_ANSI_L) { [weak self] in
            Task { @MainActor in await BlueyCoordinator.shared.execute(.lockTarget) }
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_C) { [weak self] in
            self?.checkFocusNow()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_S) { [weak self] in self?.stopActions() }

        if !AIConfig.hasAnyKey
            && !UserDefaults.standard.bool(forKey: "keyPromptDismissed") {
            UserDefaults.standard.set(true, forKey: "keyPromptDismissed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.editGeminiKey() }
        }

        NotchController.shared.stop()
        DockCompanion.shared.start()

        // The Sentinel is only wired up when it is actually switched on. Starting it unconditionally
        // meant a 1-second timer and a workspace observer ran for the app's whole lifetime even for
        // people who never used the feature — and, because nothing ever called stop(), switching it
        // off in the menu left that timer running and could leave a countdown card on screen.
        sentinel.configure(overlay: overlay)
        sentinel.onChange = { BlueyCoordinator.shared.refresh() }
        if settings.sentinelEnabled {
            sentinel.start(overlay: overlay)
        }
        if !UserDefaults.standard.bool(forKey: "blueyWorkspaceSeen") {
            UserDefaults.standard.set(true, forKey: "blueyWorkspaceSeen")
            BlueyWorkspace.shared.show()
        }
        if settings.sentinelEnabled, settings.focusGoal.isEmpty, settings.sentinelLockedTarget == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.editGoal() }
        }
    }

    private func refreshSentinelIcon() {
        // A small dot in the tooltip is enough; the menu carries the detail.
        statusItem.button?.toolTip = sentinel.isRunning ? "Bluey — watching (\(settings.focusGoal))" : "Bluey"
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = server.phoneNames.isEmpty
    }

    // MARK: Actions

    @objc private func pointHere() {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return }
        overlay.mode = .pinned(CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y))
    }

    @objc private func toggleFollow() {
        settings.followMouse.toggle()
        overlay.goHome()
    }

    @objc private func dock() { overlay.goHome() }

    /// For checking the speech bubble's look: GOOGLY_DEMO_BUBBLE=top|middle|home shows a sample reply.
    private func showDemoBubbleIfAsked() {
        guard let where_ = ProcessInfo.processInfo.environment["GOOGLY_DEMO_BUBBLE"],
              let size = NSScreen.screens.first?.frame.size else { return }
        let y: CGFloat = where_ == "top" ? 40 : size.height * 0.55
        let thing = CGRect(x: size.width * 0.3, y: y, width: 90, height: 22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if where_ != "home" {
                self.overlay.mode = .pinned(CGPoint(x: thing.midX, y: thing.maxY + 3))
                self.overlay.view.speechTarget = thing
            }
            self.overlay.view.caption = ProcessInfo.processInfo.environment["GOOGLY_DEMO_TEXT"]
                ?? "That's the prompt box, where you type to Claude. Cheeky little thing."
        }
        // GOOGLY_DEMO_OUT=path.png saves a picture of the overlay (on dark grey) and quits.
        if let out = ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let view = self.overlay.view
                let scale: CGFloat = 1
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
                ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
                ctx.fill(CGRect(x: thing.minX, y: view.bounds.height - thing.maxY, width: thing.width, height: thing.height))
                ctx.scaleBy(x: scale, y: scale)
                view.layer?.presentation()?.render(in: ctx) ?? view.layer?.render(in: ctx)
                if let image = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
        }
    }
    @objc private func toggleShow() { settings.showCursor.toggle() }
    @objc private func toggleGlow() { settings.glow.toggle() }
    @objc private func setTrail(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let trail = PointerTrail(rawValue: raw) { settings.trail = trail }
    }
    @objc private func talkTest() { overlay.talkTest() }

    @objc private func setSize(_ item: NSMenuItem) { settings.cursorSize = Double(item.tag) }
    @objc private func setPhonePosition(_ item: NSMenuItem) { settings.phonePosition = Double(item.tag) / 100.0 }
    @objc private func toggleAwake() {
        let phones = server.phoneNames
        if !phones.isEmpty {
            server.broadcast(Packet(command: host.awake ? "sleep" : "wake"))
        } else {
            triggerMacVoiceCommand()
        }
    }

    @objc private func triggerMacVoiceCommand() {
        guard settings.macMicEnabled, !ExecutionGate.shared.isStopped else { return }
        MacVoiceInput.shared.toggleListening()
    }

    @objc private func stopListening() { MacVoiceInput.shared.stopListening(processCommand: false) }

    @objc private func toggleMacMic() {
        settings.macMicEnabled.toggle()
    }

    /// On launch, asks for whatever he still needs (so Bluey shows up in those Settings lists),
    /// and keeps a small status file so it's easy to check what's allowed.
    private func checkPermissions() {
        guard ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] == nil else { return }
        if settings.computerControl && !ComputerControl.isTrusted { ComputerControl.askForPermission() }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly", isDirectory: true)
        // Make sure the directory exists before the first write, otherwise every tick failed
        // silently until some other component happened to create it.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let status = dir.appendingPathComponent("status.txt")

        // The status file is only useful until both permissions are settled, at which point this
        // timer is redundant. It used to run every 3 seconds for the entire app lifetime.
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            let text = "accessibility=\(ComputerControl.isTrusted) "
                + "screenRecording=\(CGPreflightScreenCaptureAccess()) "
                + "computerControl=\(Settings.shared.computerControl)\n"
            try? text.write(to: status, atomically: true, encoding: .utf8)
            // Once both are granted there is nothing left to report; stop ticking.
            if ComputerControl.isTrusted, CGPreflightScreenCaptureAccess() {
                timer.invalidate()
                Task { @MainActor in
                    self?.statusTimer = nil
                }
            }
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Tears down everything that holds a system resource, so quitting leaves no audio tap, no
    /// timer, and no orphaned speech-server process behind.
    @objc func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        finishListeningWorkItem?.cancel()
        finishListeningWorkItem = nil
        MacVoiceInput.shared.stopListening(processCommand: false)
        sentinel.stop()
        StudyLearner.shared.save()
        NotchController.shared.stop()
        Voice.shared.shutdown()
    }

    @objc private func openNotes() {
        try? FileManager.default.createDirectory(at: MeetingNotes.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingNotes.root)
    }

    @objc private func stopActions() {
        host.stopActions()
        DockCompanion.shared.refresh()
    }
    @objc private func resumeBluey() {
        ExecutionGate.shared.resume()
        BlueyState.shared.taskStatus = "Ready when you are"
        DockCompanion.shared.refresh()
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item(BlueyState.shared.focusStatus, #selector(openWorkspace)))
        menu.addItem(item("Open Bluey", #selector(openWorkspace)))
        menu.addItem(item("Set focus goal…", #selector(editGoal)))
        menu.addItem(item(settings.sentinelEnabled ? "Pause focus" : "Resume focus", #selector(toggleSentinel)))
        menu.addItem(item("Finish focus", #selector(finishDockFocus)))
        menu.addItem(.separator())
        menu.addItem(item("Emergency Stop Bluey", #selector(stopActions)))
        if ExecutionGate.shared.isStopped { menu.addItem(item("Resume Bluey", #selector(resumeBluey))) }
        return menu
    }
    @objc private func finishDockFocus() { Task { await BlueyCoordinator.shared.execute(.stopFocus) } }

    @objc private func toggleComputerControl() {
        settings.computerControl.toggle()
        if settings.computerControl && !ComputerControl.isTrusted { ComputerControl.askForPermission() }
        restartIfAwake()  // his tools change with this switch
    }

    @objc private func allowComputerControl() {
        ComputerControl.askForPermission()
        ComputerControl.openAccessibilitySettings()
    }

    /// Wakes him again so a new personality or set of tools takes effect right away.
    private func restartIfAwake() {
        guard host.awake else { return }
        server.broadcast(Packet(command: "sleep"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.server.broadcast(Packet(command: "wake")) }
    }

    @objc private func editPersonality() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "His Personality"
        alert.informativeText = "Describe who he is and how he talks. How he looks at and points at your screen stays built in."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 13)
        text.string = RealtimeHost.personality
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset to Default")
        alert.window.initialFirstResponder = text
        switch alert.runModal() {
        case .alertFirstButtonReturn: RealtimeHost.personality = text.string
        case .alertThirdButtonReturn: RealtimeHost.personality = ""
        default: return
        }
        restartIfAwake()
    }

    @objc private func editKeys() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Saved privately on this Mac (not in the project files). The phone only ever gets short-lived keys."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = Keychain.get(.openai) == nil ? "sk-…" : "Key saved. Paste a new one to replace it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(.openai, key) }
    }

    @objc private func setMood(_ item: NSMenuItem) {
        if let mood = item.representedObject as? String, let m = Mood(rawValue: mood) { settings.mood = m }
    }

    // MARK: Focus Sentinel

    @objc private func toggleSentinel() {
        Task { await BlueyCoordinator.shared.execute(settings.sentinelEnabled ? .pauseFocus(0) : .resumeFocus) }
    }

    @objc private func editGoal() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "What are you working on?"
        alert.informativeText = "Bluey watches for anything clearly unrelated to this and nudges you back. "
            + "Leave it empty to switch the Sentinel off without losing your settings."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "e.g. Finish the physics problem set 4"
        field.stringValue = settings.focusGoal
        alert.accessoryView = field
        alert.addButton(withTitle: "Start Watching")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear Goal")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await BlueyCoordinator.shared.execute(.startFocus(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))) }
        case .alertThirdButtonReturn:
            settings.focusGoal = ""
            Task { await BlueyCoordinator.shared.execute(.stopFocus) }
        default: break
        }
    }

    @objc private func editExempt() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Never judge or close these"
        alert.informativeText = "One app name or domain per line. Anything listed here is ignored completely."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = settings.exemptApps.joined(separator: "\n")
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset to Defaults")
        alert.window.initialFirstResponder = text
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            settings.exemptApps = text.string
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case .alertThirdButtonReturn:
            settings.exemptApps = Settings.defaultExempt
        default:
            break
        }
    }

    @objc private func setAIProvider(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let p = AIProvider(rawValue: raw) {
            settings.aiProvider = p
        }
    }

    @objc private func editGeminiKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Google Gemini API Key"
        alert.informativeText = "Saved privately on this Mac (not in the project files). Used for AI reasoning with gemini-3.1-flash-lite: cheapest, fast, multimodal vision support."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = Keychain.get(.gemini) == nil ? "AIza..." : "Key saved. Paste a new one to replace it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(.gemini, key) }
    }

    @objc private func editDeepSeekKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "DeepSeek API Key"
        alert.informativeText = "Saved privately on this Mac (not in the project files). This is what lets Bluey "
            + "judge your screen. deepseek-flash can read screenshots and costs a fraction of a cent per check."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = Keychain.get(.deepseek) == nil ? "sk-..." : "Key saved. Paste a new one to replace it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(.deepseek, key) }
    }

    @objc private func editTokenHarborKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Token Harbor API Key"
        alert.informativeText = "Saved privately on this Mac (not in the project files). This is what lets Bluey "
            + "judge your screen, using DeepSeek V4.1 Flash — measured 6/6 on real drift cases at about "
            + "2 seconds and a fraction of a cent per check."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = Keychain.get(.tokenHarbor) == nil
            ? "Paste your Token Harbor key"
            : "Key saved. Paste a new one to replace it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(.tokenHarbor, key) }
    }

    @objc private func editVoice() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Bluey's Voice"
        alert.informativeText = "Choose Bluey's voice: local Kokoro neural AI voices (100% offline, natural AI sound, zero credits) or Google Gemini neural cloud voices (gemini-3.8-flash-lite-tts)."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        let choices = Voice.availableVoices()
        for choice in choices {
            popup.addItem(withTitle: choice.name)
            popup.lastItem?.representedObject = choice.identifier
        }
        if let current = settings.voiceIdentifier,
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: index)
        }
        let preview = NSButton(title: "Preview", target: nil, action: nil)
        let row = NSStackView(views: [popup, preview])
        row.orientation = .horizontal
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 440, height: 30)
        alert.accessoryView = row
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // Preview is wired through a tiny target so the popup's current pick is what you hear.
        let previewer = VoicePreviewButton(popup: popup)
        preview.target = previewer
        preview.action = #selector(VoicePreviewButton.speak)
        objc_setAssociatedObject(alert, Unmanaged.passUnretained(previewer).toOpaque(), previewer, .OBJC_ASSOCIATION_RETAIN)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.voiceIdentifier = popup.selectedItem?.representedObject as? String
        Voice.shared.say("This is how I'll sound.")
    }

    @objc private func lockCurrentTarget() {
        Task { @MainActor in await BlueyCoordinator.shared.execute(.lockTarget) }
    }

    @objc private func unlockTarget() {
        Task { await BlueyCoordinator.shared.execute(.unlockTarget) }
    }

    @objc private func checkFocusNow() {
        Task { @MainActor in _ = await sentinel.checkNow() }
    }

    @objc private func toggleSentinelAct() { settings.sentinelAct.toggle() }
    @objc private func toggleSentinelPoints() { settings.sentinelPoints.toggle() }
    @objc private func toggleVoice() { settings.voiceEnabled.toggle() }
    @objc private func toggleThinking() { settings.deepseekThinking.toggle() }
    @objc private func setWarnSeconds(_ item: NSMenuItem) { settings.warnSeconds = Double(item.tag) }

    @objc private func openSentinelLog() {
        if !FileManager.default.fileExists(atPath: Sentinel.logURL.path) {
            FileManager.default.createFile(atPath: Sentinel.logURL.path, contents: Data())
        }
        NSWorkspace.shared.open(Sentinel.logURL)
    }

    @objc private func toggleNotch() {
        settings.notchEnabled.toggle()
        if settings.notchEnabled {
            NotchController.shared.start()
        } else {
            NotchController.shared.stop()
        }
    }
    @objc private func toggleNotchMusic() { settings.notchMusicEnabled.toggle() }
    @objc private func toggleNotchIdlePlay() { settings.notchIdlePlayEnabled.toggle() }
    @objc private func toggleNotchLockScreen() { settings.notchOnLockScreen.toggle() }

    @objc private func toggleAILearning() {
        settings.aiLearningEnabled.toggle()
    }

    @objc private func showNotchStudyInsights() {
        if !settings.notchEnabled {
            settings.notchEnabled = true
            NotchController.shared.start()
        }
        NotchController.shared.showStudyInsights()
    }

    @objc private func setNotchSilhouette(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let sil = NotchSilhouette(rawValue: raw) {
            settings.notchSilhouette = sil
            if settings.notchEnabled {
                NotchController.shared.stop()
                NotchController.shared.start()
            }
        }
    }

    private func installEditMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Bluey")
        appMenu.addItem(NSMenuItem(title: "About Bluey", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Bluey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem(title: "Bluey", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu; main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit; main.addItem(item); NSApp.mainMenu = main
    }

    // MARK: Menu

    @objc private func openWorkspace() { BlueyWorkspace.shared.show() }
    @objc private func openSettings() { BlueyWorkspace.shared.show(settings: true) }

    func menuNeedsUpdate(_ mainMenu: NSMenu) {
        mainMenu.removeAllItems()
        let menu = NSMenu()

        let phones = server.phoneNames
        let status = NSMenuItem(title: phones.isEmpty ? "No phone connected (Standalone Mac Mode)" : "Phone connected: \(phones.joined(separator: ", "))",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let wakeTitle: String
        if !phones.isEmpty {
            wakeTitle = host.awake ? "Go to Sleep (Follow Mode)" : "Wake Up and Talk (Phone - ⌥Space)"
        } else if MacVoiceInput.shared.isListening {
            wakeTitle = "🔴 Listening… (Press ⌥Space or ⌃⌥V to Send)"
        } else {
            wakeTitle = "🎙️ Talk to Bluey (Mac Mic - ⌥Space)"
        }

        let wake = NSMenuItem(title: wakeTitle, action: #selector(toggleAwake), keyEquivalent: " ")
        wake.keyEquivalentModifierMask = [.option]
        wake.target = self
        wake.isEnabled = !phones.isEmpty || settings.macMicEnabled
        menu.addItem(wake)

        if phones.isEmpty {
            let voiceItem = item("Voice Command (Mac Mic)", #selector(triggerMacVoiceCommand), key: "v")
            voiceItem.isEnabled = settings.macMicEnabled
            menu.addItem(voiceItem)
        }

        let macMic = item("Use Mac Mic When Phone Disconnected", #selector(toggleMacMic))
        macMic.state = settings.macMicEnabled ? .on : .off
        menu.addItem(macMic)

        menu.addItem(.separator())

        let control = item("Let Him Use the Computer", #selector(toggleComputerControl))
        control.state = settings.computerControl ? .on : .off
        menu.addItem(control)
        if settings.computerControl && !ComputerControl.isTrusted {
            menu.addItem(item("Allow Clicking and Typing (Accessibility)…", #selector(allowComputerControl)))
        }
        menu.addItem(item("Stop Him", #selector(stopActions), key: "s"))
        menu.addItem(.separator())

        // The Focus Sentinel.
        let watch = item("Focus Sentinel", #selector(toggleSentinel))
        watch.state = settings.sentinelEnabled ? .on : .off
        menu.addItem(watch)

        // Lock onto current target (Window or Browser Tab)
        let lockItem = item("🎯 Lock Current Window/Tab", #selector(lockCurrentTarget), key: "l")
        menu.addItem(lockItem)

        if let target = sentinel.lockedTarget {
            let unlockItem = item("🔓 Unlock Target (\(target.displayName))", #selector(unlockTarget))
            menu.addItem(unlockItem)
        }

        let goalTitle = settings.focusGoal.isEmpty ? "Set Focus Goal..." : "Focus Goal: \(settings.focusGoal)"
        menu.addItem(item(goalTitle, #selector(editGoal)))
        let act = item("Close Distractions After Warning", #selector(toggleSentinelAct))
        act.state = settings.sentinelAct ? .on : .off
        act.isEnabled = settings.sentinelEnabled
        menu.addItem(act)

        let now = item("Check What I'm Doing Now", #selector(checkFocusNow), key: "c")
        now.isEnabled = settings.sentinelEnabled && Brain.shared.hasKey
        menu.addItem(now)

        let summary = NSMenuItem(title: sentinel.menuSummary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        let sentinelSettings = NSMenu()
        let monitoring = NSMenuItem(title: "Continuous monitoring while focus is active", action: nil, keyEquivalent: "")
        monitoring.isEnabled = false
        sentinelSettings.addItem(monitoring)

        let aiLearn = item("AI Learns How I Study (Hermes Engine)", #selector(toggleAILearning))
        aiLearn.state = settings.aiLearningEnabled ? .on : .off
        sentinelSettings.addItem(aiLearn)

        sentinelSettings.addItem(item("Never Judge or Close...", #selector(editExempt)))
        let flyOver = item("Fly Over and Point at It", #selector(toggleSentinelPoints))
        flyOver.state = settings.sentinelPoints ? .on : .off
        sentinelSettings.addItem(flyOver)
        let speak = item("Speak Nudges Out Loud", #selector(toggleVoice))
        speak.state = settings.voiceEnabled ? .on : .off
        sentinelSettings.addItem(speak)
        sentinelSettings.addItem(item("Voice...", #selector(editVoice)))
        let thinking = item("Think Harder (slower, costs more)", #selector(toggleThinking))
        thinking.state = settings.deepseekThinking ? .on : .off
        sentinelSettings.addItem(thinking)
        let warnMenu = NSMenu()
        for (name, seconds) in [("5 seconds", 5.0), ("10 seconds", 10.0), ("20 seconds", 20.0), ("30 seconds", 30.0)] {
            let w = item(name, #selector(setWarnSeconds(_:)))
            w.tag = Int(seconds)
            w.state = Int(settings.warnSeconds) == Int(seconds) ? .on : .off
            warnMenu.addItem(w)
        }
        sentinelSettings.addItem(submenu("Warning Countdown", warnMenu))
        sentinelSettings.addItem(item("Show Watch Log", #selector(openSentinelLog)))
        sentinelSettings.addItem(item("Token Harbor Key...", #selector(editTokenHarborKey)))
        sentinelSettings.addItem(item("Gemini Key...", #selector(editGeminiKey)))
        sentinelSettings.addItem(item("DeepSeek Key...", #selector(editDeepSeekKey)))
        menu.addItem(submenu("Sentinel Settings", sentinelSettings))
        menu.addItem(.separator())

        let point = item("Point Here", #selector(pointHere), key: "p")
        menu.addItem(point)
        let follow = item("Eyes Follow My Mouse", #selector(toggleFollow), key: "f")
        follow.state = settings.followMouse ? .on : .off
        // Dock companion has no passive cursor overlay.
        menu.addItem(item("Stop Pointing", #selector(dock), key: "d"))
        menu.addItem(item("Talk Test", #selector(talkTest), key: "t"))
        menu.addItem(.separator())

        let moodMenu = NSMenu()
        for mood in Mood.allCases where mood != .talking && mood != .pointing && mood != .sleepy {
            let m = item(mood.title, #selector(setMood(_:)))
            m.representedObject = mood.rawValue
            m.state = settings.mood == mood ? .on : .off
            moodMenu.addItem(m)
        }
        menu.addItem(submenu("Mood", moodMenu))

        let sizeMenu = NSMenu()
        for (name, size) in [("Small", 48), ("Medium", 72), ("Large", 96), ("Huge", 120)] {
            let s = item("\(name) (\(size) pt)", #selector(setSize(_:)))
            s.tag = size
            s.state = Int(settings.cursorSize) == size ? .on : .off
            sizeMenu.addItem(s)
        }
        menu.addItem(submenu("Cursor Size", sizeMenu))

        let phoneMenu = NSMenu()
        for (name, pos) in [("Left", 20), ("Center", 50), ("Right", 80)] {
            let p = item(name, #selector(setPhonePosition(_:)))
            p.tag = pos
            p.state = Int((settings.phonePosition * 100).rounded()) == pos ? .on : .off
            phoneMenu.addItem(p)
        }
        menu.addItem(submenu("Phone Sits Under", phoneMenu))

        menu.addItem(item("Open Meeting Notes", #selector(openNotes)))
        menu.addItem(item("Personality…", #selector(editPersonality)))

        let aiMenu = NSMenu()
        for provider in AIProvider.allCases {
            let pItem = item(provider.title, #selector(setAIProvider(_:)))
            pItem.representedObject = provider.rawValue
            pItem.state = settings.aiProvider == provider ? .on : .off
            aiMenu.addItem(pItem)
        }
        aiMenu.addItem(.separator())
        aiMenu.addItem(item("Gemini Key…", #selector(editGeminiKey)))
        aiMenu.addItem(item("DeepSeek Key…", #selector(editDeepSeekKey)))
        let activeAIName = AIConfig.resolve()?.name ?? "No Key"
        menu.addItem(submenu("AI Brain (\(activeAIName))", aiMenu))
        menu.addItem(.separator())

        let trailMenu = NSMenu()
        for trail in PointerTrail.allCases {
            let t = item(trail.title, #selector(setTrail(_:)))
            t.representedObject = trail.rawValue
            t.state = settings.trail == trail ? .on : .off
            trailMenu.addItem(t)
        }
        menu.addItem(submenu("Pointer Trail", trailMenu))

        let glow = item("Cursor Glow", #selector(toggleGlow))
        glow.state = settings.glow ? .on : .off
        menu.addItem(glow)
        let show = item("Show Cursor", #selector(toggleShow), key: "h")
        show.state = settings.showCursor ? .on : .off
        menu.addItem(show)

        menu.addItem(.separator())
        mainMenu.addItem(item("Open Bluey", #selector(openWorkspace)))
        mainMenu.addItem(item("Talk to Bluey", #selector(toggleAwake)))
        if MacVoiceInput.shared.isListening { mainMenu.addItem(item("Stop Listening", #selector(stopListening))) }
        MicrophoneStore.shared.refresh()
        let micMenu = NSMenu()
        for (uid, name) in [("", "System default")] + MicrophoneStore.shared.devices.map({ ($0.uid, $0.name) }) {
            let mic = item(name, #selector(selectMicrophone(_:)))
            mic.representedObject = uid
            mic.state = MicrophoneStore.shared.selectedUID == uid ? .on : .off
            micMenu.addItem(mic)
        }
        mainMenu.addItem(submenu("Microphone · " + MicrophoneStore.shared.activeName, micMenu))
        mainMenu.addItem(item("Emergency Stop Bluey", #selector(stopActions), key: "s"))
        if ExecutionGate.shared.isStopped { mainMenu.addItem(item("Resume Bluey", #selector(resumeBluey))) }
        mainMenu.addItem(.separator())
        let focusStatus = NSMenuItem(title: BlueyState.shared.focusStatus, action: nil, keyEquivalent: "")
        focusStatus.isEnabled = false
        mainMenu.addItem(focusStatus)
        mainMenu.addItem(item("Set focus goal…", #selector(editGoal)))
        mainMenu.addItem(item("Lock current window / tab", #selector(lockCurrentTarget), key: "l"))
        mainMenu.addItem(item(settings.sentinelEnabled ? "Pause focus" : "Resume focus", #selector(toggleSentinel)))
        mainMenu.addItem(.separator())
        mainMenu.addItem(item("Settings…", #selector(openSettings)))
        mainMenu.addItem(item("Meeting notes", #selector(openNotes)))
        mainMenu.addItem(submenu("More controls", menu))
        mainMenu.addItem(.separator())
        mainMenu.addItem(NSMenuItem(title: "Quit Bluey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectMicrophone(_ item: NSMenuItem) {
        if let uid = item.representedObject as? String { MicrophoneStore.shared.select(uid) }
    }

    /// Menu item that shows its global shortcut (⌃⌥ + key) when given one.
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .option]
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Tiny helper so the Voice dialog's Preview button can read the popup it sits next to.
@MainActor
final class VoicePreviewButton: NSObject {
    private let popup: NSPopUpButton

    init(popup: NSPopUpButton) {
        self.popup = popup
    }

    @objc func speak() {
        let chosen = popup.selectedItem?.representedObject as? String
        let previous = Settings.shared.voiceIdentifier
        Settings.shared.voiceIdentifier = chosen
        Voice.shared.say("Hey, back to it. You've got this.")
        Settings.shared.voiceIdentifier = previous
    }
}

/// The little blueberry blob with eyes for the menu bar.
enum MenuIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { rect in
            let body = NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 20, height: 16))
            NSGradient(colors: Palette.gradient.map { NSColor(hex: $0) })?.draw(in: body, angle: -60)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: 6, width: 5.5, height: 5.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.5, y: 6, width: 5.5, height: 5.5)).fill()
            NSColor(hex: Palette.ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.3, y: 6.8, width: 3, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.8, y: 6.8, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
