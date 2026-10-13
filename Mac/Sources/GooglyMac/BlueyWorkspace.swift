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
        guard let view = window?.contentView else { return }
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width),
                                         pixelsHigh: Int(bounds.height),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Debug-only helper that fixes the workspace window to an exact size for capture.
    public func setPreviewSize(width: CGFloat, height: CGFloat) {
        window?.setContentSize(NSSize(width: width, height: height))
        window?.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)
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

    private var motionDisabled: Bool {
        #if DEBUG
        return reduceMotion || UIPreviewFixtures.reduceMotion
        #else
        return reduceMotion
        #endif
    }
    @State private var prompt = ""
    @State private var goal = Settings.shared.focusGoal
    @State private var focusSubjectID = ""
    @State private var focusTopicID = ""
    @State private var focusMinutes = 30
    @State private var focusPending = false
    @State private var focusMessage = ""
    @State private var confirmAbandonFocus = false

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

    // Live Detection Events
    @State private var sentinelEvents: [SentinelEvent] = SentinelEventLog.shared.recentEvents()

    @State private var revision = 0
    @State private var copiedReply = false

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 208, ideal: 216, max: 224)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                headerBar
                pageContent
            }
            .background(BlueyTheme.canvas)
        }
        .tint(BlueyTheme.accent)
        .onAppear {
            refreshAll()
            SentinelEventLog.shared.onChange = { refreshSentinelEvents() }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .top, spacing: BlueyTheme.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pageTitle)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(BlueyTheme.textPrimary)
                Text(pageSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(BlueyTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: BlueyTheme.space3)

            StatusBadge(headerStatusKind, label: headerStatusLabel)

            Button(ExecutionGate.shared.isStopped ? "Resume Bluey" : "Emergency Stop",
                   role: ExecutionGate.shared.isStopped ? nil : .destructive) {
                NSApp.sendAction(NSSelectorFromString(ExecutionGate.shared.isStopped ? "resumeBluey" : "stopActions"), to: NSApp.delegate, from: nil)
                revision += 1
            }
            .buttonStyle(.bordered)
            .help("Emergency Stop halts computer actions and voice input. It does not stop your study timer. Resume is explicit.")

            if state.busy {
                HStack(spacing: BlueyTheme.space2) {
                    ProgressView().controlSize(.small)
                    Button("Stop task", role: .destructive) {
                        BlueyCoordinator.shared.onCancelTask?()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel only the current task. This is not the global Emergency Stop.")
                }
            }
        }
        .padding(.horizontal, BlueyTheme.space5)
        .padding(.top, BlueyTheme.space5)
        .padding(.bottom, BlueyTheme.space4)
    }

    private var headerStatusKind: StatusBadge.Kind {
        if ExecutionGate.shared.isStopped { return .stopped }
        if state.busy { return .working }
        if state.listening { return .listening }
        if state.warning != nil { return .needsPermission }
        return .ready
    }

    private var headerStatusLabel: String {
        if ExecutionGate.shared.isStopped { return "Stopped" }
        if state.busy { return "Working" }
        if state.listening { return "Listening" }
        if state.warning != nil { return "Attention needed" }
        return "Ready"
    }

    // MARK: - Page content

    @ViewBuilder
    private var pageContent: some View {
        Group {
            switch normalizedPage {
            case "Focus": focus
            case "Memory & Skills": MemorySkillsView()
            case "Token Caching": CacheDashboardView()
            case "Settings": settingsView
            case "Popover Preview":
                #if DEBUG
                MenuBarPopoverView(actions: MenuBarActions(ask: {}, openFocus: {}, startFocus: {}, openWorkspace: {}, openSettings: {}, emergencyStop: {}, resume: {}, quit: {}))
                    .frame(width: 360)
                #else
                assistant
                #endif
            default: assistant
            }
        }
        .padding(.horizontal, BlueyTheme.space5)
        .padding(.bottom, BlueyTheme.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Normalizes legacy page identifiers (Memory, Study memory, Workflows).
    private var normalizedPage: String {
        switch state.workspacePage {
        case "Memory", "Study memory", "Workflows": return "Memory & Skills"
        default: return state.workspacePage
        }
    }

    // MARK: - Sidebar

    private static let destinations = ["Assistant", "Focus", "Memory & Skills", "Token Caching", "Settings"]

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
            List(selection: pageSelection) {
                ForEach(Self.destinations, id: \.self) { page in
                    Label(sidebarTitle(page), systemImage: sidebarIcon(page))
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            if BlueyCoordinator.shared.focusClock.isActive {
                focusSummary
            }
            sidebarFooter
        }
        .background(BlueyTheme.canvas)
    }

    private var pageSelection: Binding<String?> {
        Binding(
            get: { normalizedPage },
            set: { value in
                guard let value else { return }
                withAnimation(motionDisabled ? nil : BlueyTheme.motionStandard) {
                    state.workspacePage = value
                }
                if value == "Focus" { refreshSentinelEvents() }
            }
        )
    }

    private var brandRow: some View {
        HStack(spacing: BlueyTheme.space3) {
            BlueyMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bluey").font(.system(size: 17, weight: .semibold, design: .rounded))
                StatusBadge(headerStatusKind, label: headerStatusLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BlueyTheme.space4)
        .padding(.top, BlueyTheme.space5)
        .padding(.bottom, BlueyTheme.space3)
    }

    private var focusSummary: some View {
        Button {
            pageSelection.wrappedValue = "Focus"
        } label: {
            VStack(alignment: .leading, spacing: BlueyTheme.space1) {
                Text(settingsFocusSubject).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: BlueyTheme.space2) {
                    Text(focusClockText).font(.system(size: 11, design: .monospaced)).foregroundStyle(BlueyTheme.textSecondary)
                    Text(BlueyCoordinator.shared.paused ? "Paused" : "Active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BlueyCoordinator.shared.paused ? BlueyTheme.attention : BlueyTheme.success)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(BlueyTheme.space3)
            .background(BlueyTheme.accentSubtle, in: RoundedRectangle(cornerRadius: BlueyTheme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, BlueyTheme.space3)
        .padding(.bottom, BlueyTheme.space2)
        .accessibilityLabel("Open Focus")
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: BlueyTheme.space1) {
            Text(state.activeProvider.isEmpty ? "Configured in Settings" : state.activeProvider)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BlueyTheme.textSecondary)
                .lineLimit(1)
            Text("⌥ Space to talk")
                .font(.system(size: 11))
                .foregroundStyle(BlueyTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BlueyTheme.space3)
    }

    private var settingsFocusSubject: String {
        Settings.shared.focusGoal.isEmpty ? "Focus session" : Settings.shared.focusGoal
    }

    private var focusClockText: String {
        let elapsed = BlueyCoordinator.shared.focusClock.elapsed()
        let planned = Double(BlueyCoordinator.shared.plannedSeconds)
        let e = String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
        guard planned > 0 else { return e }
        return "\(e) / \(String(format: "%02d:%02d", Int(planned) / 60, Int(planned) % 60))"
    }

    private func sidebarTitle(_ page: String) -> String { page }

    private func sidebarIcon(_ page: String) -> String {
        switch page {
        case "Assistant": return "sparkles"
        case "Focus": return "shield.lefthalf.filled"
        case "Memory & Skills": return "brain.head.profile"
        case "Token Caching": return "bolt.horizontal.circle.fill"
        case "Settings": return "slider.horizontal.3"
        default: return "circle"
        }
    }

    // MARK: - Page Titles & Subtitles

    private var pageTitle: String {
        switch normalizedPage {
        case "Focus": return "Focus"
        case "Memory & Skills": return "Memory & Skills"
        case "Token Caching": return "Token Caching"
        case "Settings": return "Settings"
        default: return "Assistant"
        }
    }

    private var pageSubtitle: String {
        switch normalizedPage {
        case "Focus": return "Your session and Sentinel controls"
        case "Memory & Skills": return "Review what Bluey remembers and the skills it has learned"
        case "Token Caching": return "Only provider-reported cache usage is counted as confirmed"
        case "Settings": return "Providers, voice, access, Sentinel, and connections"
        default: return "Ask a question or give Bluey a task"
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
                        Text("Approval needed")
                            .font(.system(size: 13, weight: .semibold))
                        Text(confirmation)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button("Allow this action") {
                                BlueyApproval.shared.resolve(true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Cancel task", role: .destructive) {
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
                    if state.transcript.isEmpty && state.taskSteps.isEmpty && !state.busy {
                        // Welcoming Empty State Card (conversation is empty)
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

            // Quick Prompt Chips — at most three, only when the conversation is empty.
            HStack(spacing: 8) {
                PromptSuggestionChip(title: "Explain this screen", icon: "macwindow") {
                    onAsk("Explain what is currently on my screen and summarize the active window.")
                }
                PromptSuggestionChip(title: "Plan a study session", icon: "scope") {
                    state.workspacePage = "Focus"
                }
                PromptSuggestionChip(title: "Research a question", icon: "magnifyingglass") {
                    onAsk("Research a question for me and give me the sources.")
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
                GlassCard(padding: BlueyTheme.space4) {
                    VStack(alignment: .leading, spacing: BlueyTheme.space3) {
                        let active = coordinator.focusClock.isActive
                        let paused = coordinator.paused
                        let plannedSeconds = session?.plannedDurationSeconds ?? coordinator.plannedSeconds
                        let elapsed = coordinator.focusClock.elapsed()
                        let progress: Double? = plannedSeconds > 0 ? min(1, elapsed / Double(plannedSeconds)) : nil
                        let subject = session?.subjectName ?? (Settings.shared.focusGoal.isEmpty ? "Focus session" : Settings.shared.focusGoal)

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subject).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                if let topic = session?.topicTitle, !topic.isEmpty {
                                    Text(topic).font(.system(size: 12)).foregroundStyle(BlueyTheme.textSecondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: BlueyTheme.space3)
                            StatusBadge(active ? (paused ? .paused : .active) : .neutral,
                                        label: active ? (paused ? "Paused" : "Active") : "No session")
                        }

                        HStack(alignment: .firstTextBaseline, spacing: BlueyTheme.space3) {
                            Text(Self.focusTime(elapsed))
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .accessibilityLabel("Elapsed \(Int(elapsed / 60)) minutes")
                            Text("elapsed").font(.system(size: 12)).foregroundStyle(BlueyTheme.textSecondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(plannedSeconds > 0 ? "Planned \(plannedSeconds / 60) min" : "No planned duration")
                                    .font(.system(size: 12)).foregroundStyle(BlueyTheme.textSecondary)
                                if let started = coordinator.focusClock.startedAt {
                                    Text("Started \(started.formatted(date: .omitted, time: .shortened))")
                                        .font(.system(size: 11)).foregroundStyle(BlueyTheme.textTertiary)
                                }
                            }
                        }

                        FocusThread(progress: progress, paused: paused)

                        HStack(spacing: BlueyTheme.space2) {
                            if active {
                                Button(paused ? "Resume" : "Pause") {
                                    perform(paused ? .resumeFocus : .pauseFocus(0))
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Finish session") { perform(.stopFocus) }
                                Button("Abandon session…", role: .destructive) { confirmAbandonFocus = true }
                                    .buttonStyle(.bordered)
                            } else {
                                Text("Start a session below. Bluey checks your active target against the goal while focus is active.")
                                    .font(.system(size: 12)).foregroundStyle(BlueyTheme.textSecondary)
                            }
                            Spacer()
                        }
                        .disabled(focusPending)

                        Label(sanctra.isConnected ? (sanctra.syncError == nil ? "Synced" : "Waiting to sync") : "Local session · Sanctra disconnected",
                              systemImage: sanctra.isConnected ? "icloud" : "icloud.slash")
                            .font(.system(size: 11)).foregroundStyle(BlueyTheme.textSecondary)
                        if sanctra.pendingOutboxCount > 0 { Text("\(sanctra.pendingOutboxCount) changes waiting to sync").font(.system(size: 11)) }
                        if let error = sanctra.syncError { Text(error).font(.system(size: 11)).foregroundStyle(BlueyTheme.destructive) }
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
        .confirmationDialog("Abandon this focus session?", isPresented: $confirmAbandonFocus) {
            Button("Abandon session", role: .destructive) { Task { await BlueyCoordinator.shared.abandonFocus() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The session is recorded as abandoned, not completed. Your study record is not deleted.")
        }
    }

    // MARK: - Persistent Memory Viewer

    private var memoryViewer: some View {
        MemoryDashboardView()
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

                    HStack(spacing: 8) {
                        Picker("Bluey's voice", selection: Binding(
                            get: { Settings.shared.voiceIdentifier ?? "system:daniel" },
                            set: { Settings.shared.voiceIdentifier = $0 }
                        )) {
                            ForEach(Voice.availableVoices(), id: \.identifier) { choice in
                                Text(choice.name).tag(choice.identifier)
                            }
                        }
                        .font(.system(size: 12.5))
                        Button("Preview") { Voice.shared.say("This is how I'll sound.") }
                            .controlSize(.small)
                            .accessibilityLabel("Preview Bluey's voice")
                    }
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
        refreshSentinelEvents()
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
