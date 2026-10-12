import AppKit
import SwiftUI

@MainActor
final class BlueyWorkspace {
    static let shared = BlueyWorkspace()
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?
    var onAsk: ((String) -> Void)?
    func show(settings: Bool = false) {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 610),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Bluey"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 700, height: 520)
            window.contentView = NSHostingView(rootView: BlueyWorkspaceView(onAsk: { [weak self] in self?.onAsk?($0) }))
            window.center()
            self.window = window
        }
        BlueyState.shared.workspacePage = settings ? "Settings" : "Assistant"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func prepareForTask() {
        window?.orderOut(nil)
        previousApp?.activate(options: [.activateIgnoringOtherApps])
    }
    func snapshot(to path: String) {
        guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

private struct BlueyWorkspaceView: View {
    @ObservedObject private var state = BlueyState.shared
    @ObservedObject private var microphones = MicrophoneStore.shared
    let onAsk: (String) -> Void
    @State private var prompt = ""
    @State private var goal = Settings.shared.focusGoal
    @State private var provider = Settings.shared.aiProvider
    @State private var endpoint = Settings.shared.customEndpoint
    @State private var model = Settings.shared.customModel
    @State private var vision = Settings.shared.customVision
    @State private var fallback = Settings.shared.providerFallback
    @State private var key = ""
    @State private var connection = ""
    @State private var testingConnection = false
    @State private var revision = 0
    private let accent = Color(red: 0.40, green: 0.43, blue: 0.77)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle").font(.system(size: 26)).foregroundStyle(accent)
                    Text("Bluey").font(.system(size: 23, weight: .semibold, design: .rounded))
                }
                VStack(spacing: 6) {
                    navigation("Assistant", symbol: "bubble.left.and.bubble.right")
                    navigation("Focus", symbol: "scope")
                    navigation("Study memory", symbol: "book.closed")
                    navigation("Settings", symbol: "slider.horizontal.3")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label(state.listening ? "Listening" : state.busy ? "Working" : "Ready", systemImage: state.listening ? "waveform" : "circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    Text(state.activeProvider.isEmpty ? "Choose a provider in Settings" : state.activeProvider)
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if state.listening {
                        Button("Stop Listening") { MacVoiceInput.shared.stopListening(processCommand: false) }
                    }
                    Text("Option + Space to talk").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(22).frame(width: 195).frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(state.workspacePage).font(.system(size: 26, weight: .semibold, design: .rounded))
                    Spacer()
                    if state.busy { Button("Stop", role: .destructive) { BlueyCoordinator.shared.onCancelTask?() }.keyboardShortcut(.cancelAction) }
                }.padding(.bottom, 22)
                switch state.workspacePage {
                case "Focus": focus
                case "Study memory": memory
                case "Settings": settings
                default: assistant
                }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .onAppear { BlueyCoordinator.shared.refresh() }
    }
    private func navigation(_ name: String, symbol: String) -> some View {
        Button { state.workspacePage = name } label: {
            Label(name, systemImage: symbol).font(.system(size: 13, weight: state.workspacePage == name ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(state.workspacePage == name ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private var assistant: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(state.focusStatus, systemImage: "scope").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
            }
            if let confirmation = state.pendingConfirmation {
                VStack(alignment: .leading, spacing: 10) {
                    Text(confirmation).font(.system(size: 14, weight: .medium))
                    HStack {
                        Button("Confirm action") { BlueyApproval.shared.resolve(true) }.buttonStyle(.borderedProminent)
                        Button("Cancel action") { BlueyApproval.shared.resolve(false) }
                    }
                }.padding(14).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let warning = state.warning {
                HStack {
                    Text(warning).font(.system(size: 13))
                    Spacer()
                    Button("I'm back") { perform(.dismissWarning) }
                }.padding(12).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !state.transcript.isEmpty {
                        Text(state.transcript).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).textSelection(.enabled)
                        Divider()
                    }
                    Text(state.answer).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !state.taskSteps.isEmpty {
                        Divider()
                        ForEach(Array(state.taskSteps.enumerated()), id: \.offset) { _, step in
                            Text(step).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            Spacer(minLength: 0)
            if state.busy { Text(state.taskStatus).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your screen or give Bluey a task…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).onSubmit(send)
                    .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                Button(action: send) { Image(systemName: "arrow.up").frame(width: 22, height: 24) }
                    .buttonStyle(.borderedProminent).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy)
                    .accessibilityLabel("Send request")
                Button { if state.listening { MacVoiceInput.shared.stopListening(processCommand: true) } else if !ExecutionGate.shared.isStopped { MacVoiceInput.shared.toggleListening() } } label: {
                    Image(systemName: state.listening ? "stop.fill" : "mic").frame(width: 22, height: 24)
                }.accessibilityLabel(state.listening ? "Finish voice command" : "Start voice command")
            }
            HStack {
                Picker("Microphone", selection: Binding(get: { microphones.selectedUID }, set: { microphones.select($0) })) {
                    Text("System default").tag("")
                    ForEach(microphones.devices) { device in Text(device.name).tag(device.uid) }
                    if !microphones.selectedUID.isEmpty, !microphones.devices.contains(where: { $0.uid == microphones.selectedUID }) {
                        Text("Preferred mic · disconnected").tag(microphones.selectedUID)
                    }
                }.pickerStyle(.menu).fixedSize().onAppear { microphones.refresh() }
                Spacer()
            }
            Text(microphones.status).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Try “focus on wave optics”, “explain this”, or “lock this window”.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var focus: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(state.focusStatus).font(.system(size: 16, weight: .medium))
            Text("Tell Bluey what you want to work on. Relevant lectures, notes, and research can stay part of your session.")
                .foregroundStyle(.secondary).lineSpacing(3)
            TextField("Your focus goal", text: $goal).textFieldStyle(.roundedBorder).onSubmit { perform(.startFocus(goal)) }
            HStack {
                Button("Start focus") { perform(.startFocus(goal)) }.buttonStyle(.borderedProminent).disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Lock current window") { perform(.lockTarget) }
            }
            HStack {
                Button(Settings.shared.sentinelEnabled ? "Pause" : "Resume") { perform(Settings.shared.sentinelEnabled ? .pauseFocus(0) : .resumeFocus) }
                Button("Stop session") { perform(.stopFocus) }
                Button("Check now") { perform(.checkFocus) }.disabled(!Settings.shared.sentinelEnabled)
            }
            Divider()
            Toggle("Intervene after a warning", isOn: setting(\.sentinelAct))
            Text("Off by default for new setups. When enabled, Bluey can close the observed browser tab or hide the observed app. Returning to work cancels the warning.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            if let warning = state.warning {
                Text(warning).foregroundStyle(.orange)
                Button("Dismiss warning") { perform(.dismissWarning) }
            }
            Spacer()
            Text("Voice controls: start focus, pause focus for ten minutes, resume focus, stop watching, and I'm back.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var memory: some View {
        let profile = StudyLearner.shared.profile
        return VStack(alignment: .leading, spacing: 20) {
            Text("Your study rhythm").font(.system(size: 18, weight: .medium))
            HStack(spacing: 34) {
                metric("Focus time", value: "\(Int(profile.totalFocusMinutes)) min")
                metric("Sessions", value: "\(profile.sessionsCompleted)")
                metric("Streak", value: "\(profile.streakDays) days")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if profile.subjects.isEmpty { Text("Start a focus session to begin building your study history.").foregroundStyle(.secondary) }
                    ForEach(profile.subjects.values.sorted { $0.minutesSpent > $1.minutesSpent }, id: \.name) { subject in
                        HStack { Text(subject.name); Spacer(); Text("\(Int(subject.minutesSpent)) min").foregroundStyle(.secondary) }
                    }
                    if !profile.userNotes.isEmpty {
                        Divider()
                        ForEach(profile.userNotes, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Open meeting notes") { perform(.openNotes) }
        }
    }
    private func metric(_ name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(.system(size: 21, weight: .medium, design: .rounded)); Text(name).font(.system(size: 12)).foregroundStyle(.secondary) }
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("AI provider").font(.system(size: 17, weight: .medium))
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }.onChange(of: provider) { value in Settings.shared.aiProvider = value; key = ""; connection = ""; BlueyCoordinator.shared.refresh() }
                if provider == .custom {
                    TextField("Endpoint · https://example.com/v1", text: $endpoint).textFieldStyle(.roundedBorder)
                        .onChange(of: endpoint) { Settings.shared.customEndpoint = $0 }
                    TextField("Model name", text: $model).textFieldStyle(.roundedBorder).onChange(of: model) { Settings.shared.customModel = $0 }
                    Toggle("This model accepts images", isOn: $vision).onChange(of: vision) { Settings.shared.customVision = $0 }
                    Text("OpenAI-compatible chat completions and tool calling are required. Use HTTPS, or localhost for a local gateway.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                SecureField(provider == .auto ? "Gemini API key" : "API key", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") { saveKey() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(testingConnection ? "Testing…" : "Test connection") {
                        testingConnection = true
                        Task {
                            defer { testingConnection = false }
                            do { connection = try await AIClient.testConnection() } catch { connection = error.localizedDescription }
                        }
                    }.disabled(testingConnection)
                }
                if !connection.isEmpty { Text(connection).font(.system(size: 12)).textSelection(.enabled) }
                Toggle("Allow another configured provider when the selected key is unavailable", isOn: $fallback)
                    .onChange(of: fallback) { Settings.shared.providerFallback = $0 }
                Text("Keys are saved in macOS Keychain. Gemini gets screenshots; text-only providers get visible text and controls.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                Text("Assistant").font(.system(size: 17, weight: .medium))
                Toggle("Allow computer actions", isOn: setting(\.computerControl))
                Picker("Action permissions", selection: Binding(get: { Settings.shared.autonomyMode }, set: { Settings.shared.autonomyMode = $0; revision += 1 })) {
                    ForEach(AutonomyMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Text("Full access runs requested actions without Bluey's confirmation prompts. macOS permissions still apply.").font(.system(size: 12)).foregroundStyle(.secondary)
                if ExecutionGate.shared.isStopped {
                    Button("Resume Bluey") { ExecutionGate.shared.resume(); state.taskStatus = "Ready when you are"; revision += 1; DockCompanion.shared.refresh() }
                } else {
                    Button("Emergency Stop Bluey") { perform(.cancelTask); revision += 1 }
                }
                Toggle("Speak replies and focus nudges", isOn: setting(\.voiceEnabled))
                Toggle("Learn from focus sessions", isOn: setting(\.aiLearningEnabled))
                HStack {
                    Label(ComputerControl.isTrusted ? "Accessibility allowed" : "Accessibility needed for actions", systemImage: ComputerControl.isTrusted ? "checkmark.circle" : "hand.raised")
                    Spacer()
                    Button("Open permissions") { ComputerControl.openAccessibilitySettings() }
                }.font(.system(size: 12))
                Divider()
                Text("Bluey surface").font(.system(size: 17, weight: .medium))
                Text("Dock companion · elapsed time and activity ring, with pause and finish controls in the Dock menu.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Vorssaint's notch remains unchanged. Bluey has no notch or idle overlay.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
        }.id(revision)
    }
    private func setting(_ path: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { Settings.shared[keyPath: path] }, set: { value in
            Settings.shared[keyPath: path] = value
            revision += 1
            if path == \.notchEnabled {
                if value { NotchController.shared.start() } else { NotchController.shared.stop() }
            }
            NotchController.shared.refreshPresentation()
        })
    }
    private func perform(_ command: BlueyCommand) {
        if command == .lockTarget || command == .checkFocus { BlueyWorkspace.shared.prepareForTask() }
        Task {
            if command == .lockTarget || command == .checkFocus { try? await Task.sleep(for: .milliseconds(200)) }
            state.answer = await BlueyCoordinator.shared.execute(command)
        }
    }
    private func send() {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !state.busy else { return }
        prompt = ""; onAsk(input)
    }
    private func saveKey() {
        let mapping: [AIProvider: Keychain.Key] = [.auto: .gemini, .gemini: .gemini, .tokenHarbor: .tokenHarbor, .deepseek: .deepseek, .custom: .custom]
        guard let slot = mapping[provider] else { return }
        if Keychain.set(slot, key.trimmingCharacters(in: .whitespacesAndNewlines)) { key = ""; connection = "Key saved." } else { connection = "Keychain could not save the key. Unlock it and try again." }
        BlueyCoordinator.shared.refresh()
    }
}
