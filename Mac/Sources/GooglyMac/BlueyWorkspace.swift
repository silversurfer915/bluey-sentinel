import AppKit
import SwiftUI
import GooglyShared

@MainActor
public final class BlueyWorkspace {
    public static let shared = BlueyWorkspace()
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?
    public var onAsk: ((String) -> Void)?

    public func show(page: String? = nil, settings: Bool = false) {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Bluey"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 580)
            window.contentView = NSHostingView(rootView: BlueyWorkspaceView(onAsk: { [weak self] in self?.onAsk?($0) }))
            window.center()
            self.window = window
        }

        if settings {
            BlueyState.shared.workspacePage = "Settings"
        } else if let page = page {
            BlueyState.shared.workspacePage = page
        }
        // If neither settings nor explicit page is passed, preserve existing workspacePage

        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func prepareForTask() {
        window?.orderOut(nil)
        previousApp?.activate()
    }

    public func snapshot(to path: String) {
        guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Main Workspace Root View

private struct BlueyWorkspaceView: View {
    @ObservedObject private var state = BlueyState.shared
    @ObservedObject private var microphones = MicrophoneStore.shared
    @ObservedObject private var sanctra = SanctraSync.shared
    let onAsk: (String) -> Void

    // Chat & Focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var prompt = ""
    @State private var goal = Settings.shared.focusGoal
    @State private var focusSubjectID = ""
    @State private var focusTopicID = ""
    @State private var focusMinutes = 30
    @State private var focusPending = false
    @State private var focusMessage = ""

    // Dual-Model Brain Settings
    @State private var routingMode = Settings.shared.modelRoutingMode
    @State private var fastProvider = Settings.shared.fastProvider
    @State private var fastModel = Settings.shared.fastCustomModel
    @State private var flagshipProvider = Settings.shared.flagshipProvider
    @State private var flagshipModel = Settings.shared.flagshipCustomModel
    @State private var fallback = Settings.shared.providerFallback

    // Keys
    @State private var geminiKeyInput = ""
    @State private var tokenHarborKeyInput = ""
    @State private var deepseekKeyInput = ""
    @State private var customEndpoint = Settings.shared.customEndpoint
    @State private var customModel = Settings.shared.customModel
    @State private var customVision = Settings.shared.customVision
    @State private var customKeyInput = ""
    @State private var keyStatusMessage = ""
    @State private var testingConnection = false
    @State private var connectionResult = ""

    // Sanctra
    @State private var sanctraToken = ""
    @State private var testingSanctra = false
    @State private var sanctraMessage = ""

    // Memory Store Browser
    @State private var memoryFilter: MemoryType? = nil
    @State private var memoryQuery = ""
    @State private var memoriesList: [MemoryItem] = []
    @State private var isConfirmingForget = false
    @State private var editingMemory: MemoryItem? = nil
    @State private var editingContent = ""
    @State private var showAddMemory = false
    @State private var newMemoryType: MemoryType = .profile
    @State private var newMemoryContent = ""
    @State private var newMemoryContext = ""

    // Cache telemetry
    @State private var cacheSnapshot = CacheTracker.shared.snapshot()

    // Live Detection Events
    @State private var sentinelEvents: [SentinelEvent] = SentinelEventLog.shared.recentEvents()

    @State private var revision = 0
    @State private var copiedReply = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar Navigation Rail
            sidebarView
                .frame(width: 216)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1)

            // Main Content Canvas
            VStack(alignment: .leading, spacing: 0) {
                // Header Bar
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pageTitle)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(pageSubtitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(ExecutionGate.shared.isStopped ? "Resume Bluey" : "Emergency Stop", role: ExecutionGate.shared.isStopped ? nil : .destructive) {
                        NSApp.sendAction(NSSelectorFromString(ExecutionGate.shared.isStopped ? "resumeBluey" : "stopActions"), to: NSApp.delegate, from: nil)
                        revision += 1
                    }
                    .buttonStyle(.bordered)
                    .help("Stop computer actions and voice input. Your study timer remains available.")

                    // Right header controls
                    if state.busy {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Button("Stop Task", role: .destructive) {
                                BlueyCoordinator.shared.onCancelTask?()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 18)

                // Page Switcher
                Group {
                    switch state.workspacePage {
                    case "Focus": focus
                    case "Memory", "Study memory": memoryViewer
                    case "Token Caching": cacheDebugView
                    case "Settings": settingsView
                    default: assistant
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(BlueyTheme.primary)
        .onAppear {
            refreshAll()
            MemoryStore.shared.onChange = { refreshMemories() }
            CacheTracker.shared.onChange = { refreshCache() }
            SentinelEventLog.shared.onChange = { refreshSentinelEvents() }
        }
    }

    // MARK: - Sidebar View

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand Logo & Status
            HStack(spacing: 11) {
                BlueyLogoBadge(size: 32)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Bluey")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.listening ? Color.purple : (state.busy ? Color.orange : BlueyTheme.success))
                            .frame(width: 6, height: 6)
                        Text(ExecutionGate.shared.isStopped ? "Execution stopped" : (state.listening ? "Listening" : (state.busy ? "Working" : "Ready")))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)

            // Navigation Links
            VStack(spacing: 4) {
                navigation("Assistant", symbol: "sparkles")
                navigation("Focus", symbol: "shield.lefthalf.filled")
                navigation("Memory", symbol: "brain.head.profile")
                navigation("Token Caching", symbol: "bolt.horizontal.circle.fill")
                navigation("Settings", symbol: "slider.horizontal.3")
            }
            .padding(.horizontal, 12)

            Spacer()

            // Bottom Assistant Status Card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BlueyTheme.primary)
                    Text(state.activeProvider.isEmpty ? "Configured in Settings" : state.activeProvider)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text("Option + Space to talk")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("⌥Space")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }

                if state.listening {
                    Button(action: { MacVoiceInput.shared.stopListening(processCommand: false) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9))
                            Text("Stop Listening")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
    }

    private func navigation(_ name: String, symbol: String) -> some View {
        let isSelected = state.workspacePage == name || (name == "Memory" && state.workspacePage == "Study memory")
        return Button {
            withAnimation(reduceMotion ? nil : BlueyTheme.springQuick) {
                state.workspacePage = name
            }
            if name == "Focus" { refreshSentinelEvents() }
            if name == "Memory" { refreshMemories() }
            if name == "Token Caching" { refreshCache() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? BlueyTheme.primary : .secondary)
                    .frame(width: 18)

                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()

                if isSelected {
                    Circle()
                        .fill(BlueyTheme.primary)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? BlueyTheme.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page Titles & Subtitles

    private var pageTitle: String {
        switch state.workspacePage {
        case "Focus": return "Focus Sentinel"
        case "Memory", "Study memory": return "Memory & Learning"
        case "Token Caching": return "Token & Context Caching"
        case "Settings": return "Settings & AI Brain"
        default: return "Assistant"
        }
    }

    private var pageSubtitle: String {
        switch state.workspacePage {
        case "Focus": return "Stay with your study goal and keep your session in sync"
        case "Memory", "Study memory": return "Review what Bluey remembers about you"
        case "Token Caching": return "Usage and context savings from your AI providers"
        case "Settings": return "Model routing, provider API keys, autonomy controls, and display"
        default: return "Ask a question, work on a task, or begin studying"
        }
    }

    // MARK: - Assistant View

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Live Sentinel Status Strip
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BlueyTheme.primary)

                Text(state.focusStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if state.busy {
                    HStack(spacing: 5) {
                        AnimatedWaveform(barCount: 4, color: BlueyTheme.primary)
                        Text(state.taskStatus.isEmpty ? "Thinking…" : state.taskStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(BlueyTheme.primary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 1))

            // Pending Consequential Action Confirmation Banner
            if let confirmation = state.pendingConfirmation {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(BlueyTheme.warning)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Confirmation Required for Computer Action")
                            .font(.system(size: 13, weight: .semibold))
                        Text(confirmation)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button("Allow Action") {
                                BlueyApproval.shared.resolve(true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Cancel") {
                                BlueyApproval.shared.resolve(false)
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .background(BlueyTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BlueyTheme.warning.opacity(0.25), lineWidth: 1))
            }

            // Sentinel Warning Banner
            if let warning = state.warning {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BlueyTheme.warning)
                    Text(warning)
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Button("I'm back — Dismiss") {
                        perform(.dismissWarning)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(BlueyTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BlueyTheme.warning.opacity(0.2), lineWidth: 1))
            }

            // Scrollable Conversation Area
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if state.transcript.isEmpty && state.answer.isEmpty {
                        // Welcoming Empty State Card
                        welcomeCard
                    } else {
                        // User Prompt Bubble (if spoken or sent)
                        if !state.transcript.isEmpty {
                            HStack {
                                Spacer(minLength: 40)
                                Text(state.transcript)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .lineSpacing(3)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(BlueyTheme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(BlueyTheme.primary.opacity(0.25), lineWidth: 1))
                                    .textSelection(.enabled)
                            }
                        }

                        // Assistant Response Card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                BlueyLogoBadge(size: 22)

                                Text("Bluey")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))

                                // Model Attribution Pill
                                if !Settings.shared.lastAttributedModel.isEmpty {
                                    ModelAttributionChip(text: Settings.shared.lastAttributedModel, isFlagship: Settings.shared.lastAttributedModel.contains("Flagship") || Settings.shared.lastAttributedModel.contains("DeepSeek"))
                                }

                                Spacer()

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(state.answer, forType: .string)
                                    copiedReply = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { copiedReply = false }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedReply ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 10))
                                        Text(copiedReply ? "Copied" : "Copy")
                                            .font(.system(size: 10.5, weight: .medium))
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            Text(state.answer.isEmpty ? "Hi! Ask about your screen, give me a computer task, or start a focus session." : state.answer)
                                .font(.system(size: 14.5))
                                .lineSpacing(5)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // Step-by-step Execution Progress
                            if !state.taskSteps.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Execution Timeline")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)

                                    ForEach(Array(state.taskSteps.enumerated()), id: \.offset) { i, step in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle()
                                                .fill(BlueyTheme.success)
                                                .frame(width: 5, height: 5)
                                                .padding(.top, 5)

                                            Text(step)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(16)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            // Floating Input Dock
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    TextField("Ask Bluey, request a computer task, or say 'use big brain'…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: 13.5))
                        .onSubmit(send)

                    // Quick Tier Override Chip
                    Menu {
                        Button("⚡ Fast Tier (Quick & Lite)") {
                            prompt += " (use fast model)"
                        }
                        Button("🧠 Flagship Tier (Big Brain)") {
                            prompt += " (use big brain for this)"
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                            Text("Tier")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)

                // Voice Dictation Button
                Button {
                    if state.listening {
                        MacVoiceInput.shared.stopListening(processCommand: true)
                    } else if !ExecutionGate.shared.isStopped {
                        MacVoiceInput.shared.toggleListening()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(state.listening ? Color.red : Color(nsColor: .controlBackgroundColor))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))

                        Image(systemName: state.listening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(state.listening ? Color.white : BlueyTheme.primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.listening ? "Finish voice command" : "Start voice command")

                // Send Button
                Button(action: send) {
                    ZStack {
                        Circle()
                            .fill(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy ? Color.secondary.opacity(0.2) : BlueyTheme.primary)
                            .frame(width: 36, height: 36)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy ? Color.secondary : Color.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy)
                .accessibilityLabel("Send request")
            }
            .padding(.top, 4)
        }
    }

    private var welcomeCard: some View {
        VStack(spacing: 16) {
            BlueyLogoBadge(size: 64)

            VStack(spacing: 4) {
                Text("How can I help you today?")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("Your companion for study and everyday tasks")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            // Quick Prompt Chips
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    PromptSuggestionChip(title: "Explain what's on my screen", icon: "macwindow") {
                        onAsk("Explain what is currently on my screen and summarize the active window.")
                    }
                    PromptSuggestionChip(title: "Start a Physics focus session", icon: "scope") {
                        goal = "Physics problem solving"
                        perform(.startFocus("Physics problem solving"))
                    }
                }
                HStack(spacing: 8) {
                    PromptSuggestionChip(title: "Inspect token caching savings", icon: "bolt.fill") {
                        state.workspacePage = "Token Caching"
                    }
                    PromptSuggestionChip(title: "What have you learned about me?", icon: "brain") {
                        onAsk("What have you learned about my habits, study preferences, and profile?")
                    }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Focus View

    private var focus: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let coordinator = BlueyCoordinator.shared
                let session = sanctra.activeCanonicalSession
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(coordinator.focusClock.isActive ? (coordinator.paused ? "Paused" : "Studying") : "No active session", systemImage: coordinator.paused ? "pause.circle" : "timer")
                                .font(.headline)
                            Spacer()
                            Text(Self.focusTime(coordinator.focusClock.elapsed())).font(.title.monospacedDigit())
                        }
                        if coordinator.focusClock.isActive {
                            Text(session?.subjectName ?? Settings.shared.focusGoal).font(.headline)
                            if let topic = session?.topicTitle, !topic.isEmpty { Text(topic).foregroundStyle(.secondary) }
                            Text("Elapsed · planned \((session?.plannedDurationSeconds ?? coordinator.plannedSeconds) / 60) min")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Label(sanctra.isConnected ? (sanctra.syncError == nil ? "Connected to Sanctra" : "Waiting to sync") : "Local session · Sanctra disconnected", systemImage: sanctra.isConnected ? "icloud" : "icloud.slash")
                            .font(.callout).foregroundStyle(.secondary)
                        if sanctra.pendingOutboxCount > 0 { Text("\(sanctra.pendingOutboxCount) changes waiting to sync").font(.callout) }
                        if let error = sanctra.syncError { Text(error).font(.callout).foregroundStyle(.red) }
                    }
                }
            }
            // Target Lock & Status Card
            GlassCard(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.focusStatus)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text("Bluey checks your study goal when you switch windows or tabs.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            Circle()
                                .fill(FocusWatcher.shared.isRunning ? BlueyTheme.success : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(FocusWatcher.shared.isRunning ? "Focus checks active" : "Focus checks paused")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FocusWatcher.shared.isRunning ? BlueyTheme.success : .secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    }

                    if !BlueyCoordinator.shared.focusClock.isActive {
                        if sanctra.isConnected {
                            Picker("Subject", selection: Binding(get: { selectedFocusSubject?.id ?? "" }, set: { focusSubjectID = $0; focusTopicID = "" })) {
                                if focusSubjects.isEmpty { Text("Waiting for subjects…").tag("") }
                                ForEach(focusSubjects) { Text($0.name).tag($0.id) }
                            }
                            Picker("Topic", selection: $focusTopicID) {
                                Text("No specific topic").tag("")
                                ForEach(focusTopics) { Text($0.title).tag($0.id) }
                            }
                        }
                        Stepper("Planned duration: \(focusMinutes) minutes", value: $focusMinutes, in: 1...240, step: 5)
                    }
                    // Goal Input
                    HStack(spacing: 10) {
                        TextField("Enter your active study or work goal (e.g. Wave Optics Physics)…", text: $goal)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { startConfiguredFocus() }

                        Button(focusPending ? "Starting…" : "Start Focus") { startConfiguredFocus() }
                        .buttonStyle(.borderedProminent)
                        .disabled(focusPending || BlueyCoordinator.shared.focusClock.isActive || ExecutionGate.shared.isStopped || (sanctra.isConnected ? selectedFocusSubject == nil : goal.trimmingCharacters(in: .whitespaces).isEmpty))
                    }

                    // Action Shortcuts
                    HStack(spacing: 8) {
                        Button("Lock Front Window") { perform(.lockTarget) }
                        Button(Settings.shared.sentinelEnabled ? "Pause" : "Resume") {
                            perform(Settings.shared.sentinelEnabled ? .pauseFocus(0) : .resumeFocus)
                        }
                        Button("Finish Session") { perform(.stopFocus) }
                        Button("Abandon", role: .destructive) { Task { await BlueyCoordinator.shared.abandonFocus() } }
                        Button("Check Now") { perform(.checkFocus) }
                            .disabled(!Settings.shared.sentinelEnabled)
                    }
                    .controlSize(.small)
                    .disabled(!BlueyCoordinator.shared.focusClock.isActive || focusPending)
                    if !focusMessage.isEmpty { Text(focusMessage).font(.callout).foregroundStyle(.secondary) }

                    // Locked Target Indicator
                    if let target = Settings.shared.sentinelLockedTarget {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(BlueyTheme.primary)
                            Text("Locked Target:")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(target.displayName)
                                .font(.system(size: 11.5))
                            Spacer()
                            Button("Unlock") { perform(.unlockTarget) }
                                .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(BlueyTheme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            // Real-Time Detection Audit Log
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent Focus Checks")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Review recent checks and how Bluey responded.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Log") {
                        SentinelEventLog.shared.clear()
                        refreshSentinelEvents()
                    }
                    .controlSize(.small)
                }

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 4) {
                        if sentinelEvents.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "waveform.path.ecg")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                Text("No detection events recorded yet.")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        } else {
                            HStack {
                                Text("Time").frame(width: 80, alignment: .leading)
                                Text("Trigger").frame(width: 105, alignment: .leading)
                                Text("Active Target").frame(width: 175, alignment: .leading)
                                Text("Outcome").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Verdict").frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)

                            Divider()

                            ForEach(sentinelEvents) { evt in
                                HStack(alignment: .top) {
                                    Text(evt.timeString)
                                        .font(.system(size: 10, design: .monospaced))
                                        .frame(width: 80, alignment: .leading)
                                        .foregroundStyle(.secondary)

                                    Text(evt.trigger)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .frame(width: 105, alignment: .leading)
                                        .lineLimit(1)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(evt.app)
                                            .font(.system(size: 10.5, weight: .medium))
                                            .lineLimit(1)
                                        if !evt.windowTitle.isEmpty {
                                            Text(evt.windowTitle)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        } else if let d = evt.domain {
                                            Text(d)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(width: 175, alignment: .leading)

                                    Text(evt.outcome)
                                        .font(.system(size: 10.5))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(evt.isDrift ? "DRIFT" : "ON-TASK")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background((evt.isDrift ? BlueyTheme.warning : BlueyTheme.success).opacity(0.12), in: Capsule())
                                        .foregroundStyle(evt.isDrift ? BlueyTheme.warning : BlueyTheme.success)
                                        .frame(width: 70, alignment: .trailing)
                                }
                                .padding(.vertical, 2.5)
                                Divider()
                            }
                        }
                    }
                    .frame(minWidth: 650, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        }
    }

    // MARK: - Persistent Memory Viewer

    private var memoryViewer: some View {
        VStack(alignment: .leading, spacing: 18) {
            let profile = StudyLearner.shared.profile

            // Metrics Summary Row
            HStack(spacing: 14) {
                metricCard("Local Focus Time", value: "\(Int(profile.totalFocusMinutes))m", icon: "clock.fill")
                metricCard("Local Sessions", value: "\(profile.sessionsCompleted)", icon: "checkmark.seal.fill")
                metricCard(sanctra.isConnected ? "Sanctra Streak" : "Local Streak", value: sanctra.isConnected ? (sanctra.studyContext?.streaks?.streakDays.map { "\($0)d" } ?? "—") : "\(profile.streakDays)d", icon: "flame.fill")
                metricCard("Total Facts", value: "\(memoriesList.count)", icon: "internaldrive.fill")
            }

            // Filters & Add Controls
            HStack {
                Picker("Category", selection: $memoryFilter) {
                    Text("All Categories").tag(MemoryType?.none)
                    ForEach(MemoryType.allCases, id: \.self) { type in
                        Text(type.title).tag(MemoryType?.some(type))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                Button {
                    showAddMemory.toggle()
                } label: {
                    Label(showAddMemory ? "Cancel" : "Add Memory", systemImage: showAddMemory ? "xmark" : "plus")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    isConfirmingForget = true
                } label: {
                    Label("Forget Everything", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Add Memory Expandable Card
            if showAddMemory {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Category", selection: $newMemoryType) {
                            ForEach(MemoryType.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)

                        TextField("Trigger Context (e.g. When searching lecture notes)", text: $newMemoryContext)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        TextField("Fact, preference, or lesson to remember…", text: $newMemoryContent)
                            .textFieldStyle(.roundedBorder)

                        Button("Save Memory") {
                            guard !newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            MemoryStore.shared.addOrUpdate(type: newMemoryType, content: newMemoryContent, triggerContext: newMemoryContext.isEmpty ? nil : newMemoryContext)
                            newMemoryContent = ""
                            newMemoryContext = ""
                            showAddMemory = false
                            refreshMemories()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .background(BlueyTheme.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BlueyTheme.primary.opacity(0.18), lineWidth: 1))
            }

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search memories, profile facts, preferences, lessons…", text: $memoryQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: memoryQuery) { refreshMemories() }
                if !memoryQuery.isEmpty {
                    Button(action: { memoryQuery = ""; refreshMemories() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))

            // Memory Cards ScrollView
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if filteredMemories.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "brain")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No memories found.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Bluey automatically extracts preferences, facts, and lessons from conversation. You can also add them manually above.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(filteredMemories) { item in
                            memoryCard(item)
                        }
                    }
                }
            }

            HStack {
                Text("🔒 100% Private · Stored in local SQLite database on your Mac (`~/Library/Application Support/Googly/memory.sqlite`).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .confirmationDialog("Forget all stored memories?", isPresented: $isConfirmingForget) {
            Button("Forget Everything", role: .destructive) {
                MemoryStore.shared.forgetEverything()
                refreshMemories()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently wipe all profile facts, learned lessons, and preferences from your Mac.")
        }
    }

    private var filteredMemories: [MemoryItem] {
        var list = memoriesList
        if let filter = memoryFilter {
            list = list.filter { $0.type == filter }
        }
        if !memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = memoryQuery.lowercased()
            list = list.filter { $0.content.lowercased().contains(q) || ($0.triggerContext?.lowercased().contains(q) ?? false) }
        }
        return list
    }

    private func memoryCard(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(item.type.title, systemImage: item.type.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(item.type == .lesson ? BlueyTheme.warning : BlueyTheme.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background((item.type == .lesson ? BlueyTheme.warning : BlueyTheme.primary).opacity(0.12), in: Capsule())

                if let ctx = item.triggerContext, !ctx.isEmpty {
                    Text("When \(ctx)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    editingMemory = item
                    editingContent = item.content
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    MemoryStore.shared.delete(id: item.id)
                    refreshMemories()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            if editingMemory?.id == item.id {
                HStack {
                    TextField("Content", text: $editingContent)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        MemoryStore.shared.update(id: item.id, content: editingContent)
                        editingMemory = nil
                        refreshMemories()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Cancel") { editingMemory = nil }
                        .controlSize(.small)
                }
            } else {
                Text(item.content)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Token & Context Caching View

    private var cacheDebugView: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                metricCard("Confirmed Hit Rate",
                           value: cacheSnapshot.confirmedHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                           icon: "bolt.fill")
                metricCard("Reused Input Tokens", value: "\(cacheSnapshot.reusedInputTokens)", icon: "arrow.triangle.2.circlepath")
                metricCard("Requests w/ Telemetry", value: "\(cacheSnapshot.requestsWithCacheTelemetry)", icon: "tray.full.fill")
                metricCard("Median Latency",
                           value: cacheSnapshot.medianLatencyMs.map { "\($0)ms" } ?? "—",
                           icon: "timer")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(BlueyTheme.primary)
                    Text("Provider-controlled caching")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                Text("Caching is best effort and decided by your provider. Requests with unknown cache telemetry stay visible but are excluded from the hit rate; Bluey never invents a dollar saving.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
            }
            .padding(12)
            .background(BlueyTheme.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BlueyTheme.primary.opacity(0.15), lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Requests")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("Reset Stats") {
                        CacheTracker.shared.reset()
                        refreshCache()
                    }
                    .controlSize(.small)
                }

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 6) {
                        if cacheSnapshot.recentLogs.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "tray")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                Text("No requests recorded yet.")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text("Ask Bluey a question to record real provider usage.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                        } else {
                            HStack {
                                Text("Time").frame(width: 80, alignment: .leading)
                                Text("Provider").frame(width: 110, alignment: .leading)
                                Text("Model").frame(width: 140, alignment: .leading)
                                Text("Input").frame(width: 70, alignment: .trailing)
                                Text("Reused").frame(width: 70, alignment: .trailing)
                                Text("Status").frame(width: 130, alignment: .leading)
                                Text("Latency").frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)

                            Divider()

                            ForEach(cacheSnapshot.recentLogs) { log in
                                HStack {
                                    Text(log.timestamp, style: .time).frame(width: 80, alignment: .leading)
                                    Text(log.provider.title).frame(width: 110, alignment: .leading).lineLimit(1)
                                    Text(log.model).frame(width: 140, alignment: .leading).lineLimit(1)
                                    Text("\(log.usage.totalInputTokens ?? 0)").frame(width: 70, alignment: .trailing)
                                    Text("\(log.usage.cachedInputTokens ?? 0)")
                                        .frame(width: 70, alignment: .trailing)
                                        .foregroundStyle((log.usage.cachedInputTokens ?? 0) > 0 ? BlueyTheme.success : .secondary)
                                    Text(cacheStatusLabel(log.usage.evidence)).frame(width: 130, alignment: .leading)
                                    Text("\(log.latencyMs)ms").frame(width: 70, alignment: .trailing)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                Divider()
                            }
                        }
                    }
                    .frame(minWidth: 720, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        }
    }

    private func cacheStatusLabel(_ evidence: CacheEvidence) -> String {
        switch evidence {
        case .confirmed: return "Confirmed hit"
        case .reportedNoHit: return "Confirmed miss"
        case .usageWithoutCacheField: return "Cache not reported"
        case .usageUnavailable: return "Usage unavailable"
        }
    }

    private func metricCard(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(BlueyTheme.primary)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Settings & AI Brain View

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Section 1: AI Brain & Dual-Model Routing
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI Brain & Dual-Model Routing")
                        .font(.system(size: 15, weight: .bold))

                    Picker("Routing Mode", selection: $routingMode) {
                        ForEach(ModelRoutingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .onChange(of: routingMode) { _, value in Settings.shared.modelRoutingMode = value }

                    HStack(spacing: 12) {
                        // Fast Tier Tile
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(BlueyTheme.primary)
                                Text("Fast Tier (Lite / Quick)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Picker("Provider", selection: $fastProvider) {
                                Text("Gemini 3.1 Flash Lite").tag(AIProvider.gemini)
                                Text("Token Harbor").tag(AIProvider.tokenHarbor)
                                Text("DeepSeek").tag(AIProvider.deepseek)
                                Text("Custom").tag(AIProvider.custom)
                            }
                            .onChange(of: fastProvider) { _, value in Settings.shared.fastProvider = value }

                            TextField("Custom Model Name", text: $fastModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: fastModel) { _, value in Settings.shared.fastCustomModel = value }
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))

                        // Flagship Tier Tile
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "brain")
                                    .foregroundStyle(BlueyTheme.purple)
                                Text("Flagship Tier (Big Brain)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Picker("Provider", selection: $flagshipProvider) {
                                Text("DeepSeek").tag(AIProvider.deepseek)
                                Text("Gemini Pro / Flash").tag(AIProvider.gemini)
                                Text("Token Harbor").tag(AIProvider.tokenHarbor)
                                Text("Custom").tag(AIProvider.custom)
                            }
                            .onChange(of: flagshipProvider) { _, value in Settings.shared.flagshipProvider = value }

                            TextField("Custom Model Name", text: $flagshipModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: flagshipModel) { _, value in Settings.shared.flagshipCustomModel = value }
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    }

                    Toggle("Allow automatic provider fallback if preferred key is unavailable", isOn: $fallback)
                        .onChange(of: fallback) { _, value in Settings.shared.providerFallback = value }
                        .font(.system(size: 12))
                }

                Divider()

                // Section 2: API Keys Configuration
                VStack(alignment: .leading, spacing: 10) {
                    Text("Microphone")
                        .font(.system(size: 15, weight: .bold))
                    Picker("Voice input", selection: Binding(get: { microphones.selectedUID }, set: { microphones.select($0) })) {
                        Text("System default").tag("")
                        ForEach(microphones.devices) { Text($0.name).tag($0.uid) }
                    }
                    Text(microphones.status).font(.callout).foregroundStyle(.secondary)
                    Divider()

                    Text("API Keys & Providers")
                        .font(.system(size: 15, weight: .bold))
                    Text("Keys are stored securely in your macOS Keychain.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    keyRow(name: "Gemini API Key", placeholder: "AIzaSy…", key: .gemini, input: $geminiKeyInput)
                    keyRow(name: "Token Harbor API Key", placeholder: "thk_live_…", key: .tokenHarbor, input: $tokenHarborKeyInput)
                    keyRow(name: "DeepSeek API Key", placeholder: "sk-…", key: .deepseek, input: $deepseekKeyInput)

                    // Custom Endpoint Box
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom OpenAI-Compatible Endpoint")
                            .font(.system(size: 12, weight: .semibold))
                        TextField("Endpoint URL (e.g. https://api.together.xyz/v1)", text: $customEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customEndpoint) { _, value in Settings.shared.customEndpoint = value }
                        HStack {
                            TextField("Custom Model ID", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: customModel) { _, value in Settings.shared.customModel = value }
                            Toggle("Vision support", isOn: $customVision)
                                .onChange(of: customVision) { _, value in Settings.shared.customVision = value }
                                .font(.system(size: 12))
                        }
                        keyRow(name: "Custom API Key", placeholder: "Bearer token…", key: .custom, input: $customKeyInput)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))

                    HStack(spacing: 10) {
                        Button(testingConnection ? "Testing Connection…" : "Test Active AI Connection") {
                            testingConnection = true
                            Task {
                                defer { testingConnection = false }
                                do { connectionResult = try await AIClient.testConnection() }
                                catch { connectionResult = "Error: \(error.localizedDescription)" }
                            }
                        }
                        .disabled(testingConnection)
                        .controlSize(.small)

                        if !keyStatusMessage.isEmpty {
                            Text(keyStatusMessage)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(BlueyTheme.success)
                        }
                    }

                    if !connectionResult.isEmpty {
                        Text(connectionResult)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                // Section 3: Sentinel & Permissions
                VStack(alignment: .leading, spacing: 10) {
                    Text("Focus Sentinel & Autonomy")
                        .font(.system(size: 15, weight: .bold))

                    Toggle("Allow autonomous computer actions (clicks, keyboard, application launch)", isOn: setting(\.computerControl))
                        .font(.system(size: 12.5))

                    Picker("Action permissions", selection: Binding(get: { Settings.shared.autonomyMode }, set: { Settings.shared.autonomyMode = $0; revision += 1 })) {
                        ForEach(AutonomyMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }

                    Toggle("Speak replies and focus nudges", isOn: setting(\.voiceEnabled))
                        .font(.system(size: 12.5))
                    Toggle("Learn study rhythms and preferences", isOn: setting(\.aiLearningEnabled))
                        .font(.system(size: 12.5))

                    HStack {
                        Label(ComputerControl.isTrusted ? "Accessibility permissions granted" : "Accessibility needed for computer control",
                              systemImage: ComputerControl.isTrusted ? "checkmark.circle.fill" : "hand.raised.fill")
                            .foregroundStyle(ComputerControl.isTrusted ? BlueyTheme.success : BlueyTheme.warning)
                            .font(.system(size: 12))
                        Spacer()
                        Button("Open System Settings") { ComputerControl.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }

                Divider()

                // Section 4: Sanctra Cloud Sync
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sanctra Study Integration")
                        .font(.system(size: 15, weight: .bold))

                    if sanctra.isConnected, let acc = sanctra.account {
                        HStack {
                            Label("Connected as \(acc.displayName)", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(BlueyTheme.success)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button("Disconnect") {
                                Keychain.set(.sanctraPersonalToken, nil)
                                sanctra.refreshConnection()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        SecureField("Sanctra personal token · sanctra_personal_…", text: $sanctraToken)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Connect Sanctra") {
                                let clean = sanctraToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !clean.isEmpty else { return }
                                Keychain.set(.sanctraPersonalToken, clean)
                                sanctraToken = ""
                                sanctra.refreshConnection()
                            }
                            .disabled(sanctraToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .controlSize(.small)
                        }
                    }
                    if let error = sanctra.syncError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    }
                    if let lastSync = sanctra.lastSyncDate {
                        Text("Last synced \(lastSync.formatted(date: .omitted, time: .shortened))").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("\(sanctra.pendingOutboxCount) changes waiting to sync").font(.callout).foregroundStyle(.secondary)
                    Button("Refresh connection") { sanctra.refreshConnection() }.controlSize(.small)
                }
            }
            .padding(.bottom, 24)
        }
        .id(revision)
    }

    private func keyRow(name: String, placeholder: String, key: Keychain.Key, input: Binding<String>) -> some View {
        let isConfigured = Keychain.get(key) != nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    if isConfigured {
                        Text("✓ Saved in Keychain")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BlueyTheme.success)
                    }
                }
                SecureField(placeholder, text: input).textFieldStyle(.roundedBorder)
            }
            Button("Save") {
                let clean = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return }
                Keychain.set(key, clean)
                input.wrappedValue = ""
                keyStatusMessage = "Saved \(name)!"
                revision += 1
                BlueyCoordinator.shared.refresh()
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers & State Refresh

    private var focusSubjects: [SanctraSubject] { sanctra.studyContext?.subjects ?? [] }
    private var selectedFocusSubject: SanctraSubject? { focusSubjects.first { $0.id == focusSubjectID } ?? focusSubjects.first }
    private var focusTopics: [SanctraTopic] { (sanctra.studyContext?.topics ?? []).filter { $0.subjectId == selectedFocusSubject?.id } }
    private static func focusTime(_ elapsed: Double) -> String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private func startConfiguredFocus() {
        guard !focusPending, !BlueyCoordinator.shared.focusClock.isActive else { return }
        focusPending = true
        focusMessage = ""
        let subject = selectedFocusSubject
        let topic = focusTopics.first { $0.id == focusTopicID }
        let command = PhoneSessionCommand(action: .start, sessionId: "mac-" + UUID().uuidString,
            subjectId: subject?.id, topicId: topic?.id, subjectLabel: subject?.name ?? goal,
            topicLabel: topic?.title, plannedSeconds: focusMinutes * 60)
        Task {
            defer { focusPending = false }
            focusMessage = await BlueyCoordinator.shared.startPhoneFocus(command) ?? "Session started"
        }
    }

    private func refreshAll() {
        refreshMemories()
        refreshCache()
        refreshSentinelEvents()
    }

    private func refreshMemories() {
        memoriesList = MemoryStore.shared.all()
    }

    private func refreshCache() {
        cacheSnapshot = CacheTracker.shared.snapshot()
    }

    private func refreshSentinelEvents() {
        sentinelEvents = SentinelEventLog.shared.recentEvents()
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
        if command == .lockTarget || command == .checkFocus || command == .unlockTarget { BlueyWorkspace.shared.prepareForTask() }
        Task {
            if command == .lockTarget || command == .checkFocus || command == .unlockTarget { try? await Task.sleep(for: .milliseconds(200)) }
            state.answer = await BlueyCoordinator.shared.execute(command)
            refreshSentinelEvents()
        }
    }

    private func send() {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !state.busy else { return }
        prompt = ""
        onAsk(input)
    }
}

// MARK: - Bluey Logo Badge Component

public struct BlueyLogoBadge: View {
    public var size: CGFloat = 28

    public init(size: CGFloat = 28) {
        self.size = size
    }

    private var image: NSImage? {
        if let url = Bundle.main.url(forResource: "bluey-avatar-256", withExtension: "png") ??
                     Bundle.main.url(forResource: "bluey-mac-1024", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        let devPaths = [
            "Shared/Assets/bluey-avatar-256.png",
            "Shared/Assets/bluey-mac-1024.png",
            "Shared/Assets/bluey-logo-1024.png"
        ]
        for path in devPaths {
            if FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }

    public var body: some View {
        if let nsImg = image {
            Image(nsImage: nsImg)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .shadow(color: Color(red: 0.26, green: 0.33, blue: 0.84).opacity(0.35), radius: 3, x: 0, y: 1.5)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.75))
                .foregroundStyle(BlueyTheme.primary)
        }
    }
}
