import AppKit
import SwiftUI

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
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Bluey"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 540)
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
        NSApp.activate(ignoringOtherApps: true)
    }

    public func prepareForTask() {
        window?.orderOut(nil)
        previousApp?.activate(options: [.activateIgnoringOtherApps])
    }

    public func snapshot(to path: String) {
        guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

private struct BlueyWorkspaceView: View {
    @ObservedObject private var state = BlueyState.shared
    @ObservedObject private var microphones = MicrophoneStore.shared
    @ObservedObject private var sanctra = SanctraSync.shared
    let onAsk: (String) -> Void

    // Chat & Focus
    @State private var prompt = ""
    @State private var goal = Settings.shared.focusGoal

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

    // Cache Stats
    @State private var cacheStats = CacheTracker.shared.snapshot().stats
    @State private var cacheLogs = CacheTracker.shared.snapshot().recentLogs

    // Live Detection Events
    @State private var sentinelEvents: [SentinelEvent] = SentinelEventLog.shared.recentEvents()

    @State private var revision = 0
    private let accent = Color(red: 0.40, green: 0.43, blue: 0.77)

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar Navigation
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle").font(.system(size: 24)).foregroundStyle(accent)
                    Text("Bluey").font(.system(size: 22, weight: .semibold, design: .rounded))
                }
                VStack(spacing: 6) {
                    navigation("Assistant", symbol: "bubble.left.and.bubble.right")
                    navigation("Focus", symbol: "scope")
                    navigation("Memory", symbol: "brain.head.profile")
                    navigation("Token Caching", symbol: "bolt.horizontal.circle")
                    navigation("Settings", symbol: "slider.horizontal.3")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label(state.listening ? "Listening" : state.busy ? "Working" : "Ready",
                          systemImage: state.listening ? "waveform" : "circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    Text(state.activeProvider.isEmpty ? "Configured in Settings" : state.activeProvider)
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if state.listening {
                        Button("Stop Listening") { MacVoiceInput.shared.stopListening(processCommand: false) }
                    }
                    Text("Option + Space to talk").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(20).frame(width: 200).frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Main Content Area
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(pageTitle).font(.system(size: 24, weight: .semibold, design: .rounded))
                    Spacer()
                    if state.busy {
                        Button("Stop", role: .destructive) { BlueyCoordinator.shared.onCancelTask?() }
                            .keyboardShortcut(.cancelAction)
                    }
                }.padding(.bottom, 18)

                switch state.workspacePage {
                case "Focus": focus
                case "Memory", "Study memory": memoryViewer
                case "Token Caching": cacheDebugView
                case "Settings": settingsView
                default: assistant
                }
            }
            .padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .onAppear {
            refreshAll()
            MemoryStore.shared.onChange = { refreshMemories() }
            CacheTracker.shared.onChange = { refreshCache() }
            SentinelEventLog.shared.onChange = { refreshSentinelEvents() }
        }
    }

    private var pageTitle: String {
        switch state.workspacePage {
        case "Focus": return "Focus Sentinel"
        case "Memory", "Study memory": return "Memory & Learning"
        case "Token Caching": return "Token & Context Caching"
        case "Settings": return "Settings & AI Brain"
        default: return "Assistant"
        }
    }

    private func navigation(_ name: String, symbol: String) -> some View {
        let isSelected = state.workspacePage == name || (name == "Memory" && state.workspacePage == "Study memory")
        return Button {
            state.workspacePage = name
            if name == "Focus" { refreshSentinelEvents() }
            if name == "Memory" { refreshMemories() }
            if name == "Token Caching" { refreshCache() }
        } label: {
            Label(name, systemImage: symbol)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                .background(isSelected ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    // MARK: - Assistant View

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                VStack(alignment: .leading, spacing: 16) {
                    if !state.transcript.isEmpty {
                        Text(state.transcript).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).textSelection(.enabled)
                        Divider()
                    }

                    // Model Attribution Badge
                    if !Settings.shared.lastAttributedModel.isEmpty {
                        HStack(spacing: 6) {
                            Text(Settings.shared.lastAttributedModel)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(accent)
                            Spacer()
                        }
                    }

                    Text(state.answer.isEmpty ? "Hi! Ask about your screen, give me a computer task, or start a focus session." : state.answer)
                        .font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)

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
                TextField("Ask about your screen or task (say 'use big brain for this' to force flagship)…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).onSubmit(send)
                    .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                Button(action: send) { Image(systemName: "arrow.up").frame(width: 22, height: 24) }
                    .buttonStyle(.borderedProminent).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy)
                    .accessibilityLabel("Send request")
                Button {
                    if state.listening { MacVoiceInput.shared.stopListening(processCommand: true) }
                    else if !ExecutionGate.shared.isStopped { MacVoiceInput.shared.toggleListening() }
                } label: {
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
        }
    }

    // MARK: - Focus View

    private var focus: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status and Watcher Liveness Indicator
            HStack(alignment: .center, spacing: 10) {
                Text(state.focusStatus).font(.system(size: 16, weight: .medium))
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(FocusWatcher.shared.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(FocusWatcher.shared.isRunning ? "Event Watcher Live" : "Watcher Inactive")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FocusWatcher.shared.isRunning ? .green : .secondary)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 1))
            }

            Text("Tell Bluey what you want to work on. macOS Accessibility observers, application activation events, and safety-net probing monitor your active context in real time without polling delays.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary).lineSpacing(3)

            TextField("Your focus goal", text: $goal).textFieldStyle(.roundedBorder).onSubmit { perform(.startFocus(goal)) }

            HStack {
                Button("Start focus") { perform(.startFocus(goal)) }.buttonStyle(.borderedProminent).disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Lock current window") { perform(.lockTarget) }
                Button(Settings.shared.sentinelEnabled ? "Pause" : "Resume") { perform(Settings.shared.sentinelEnabled ? .pauseFocus(0) : .resumeFocus) }
                Button("Stop session") { perform(.stopFocus) }
                Button("Check now") { perform(.checkFocus) }.disabled(!Settings.shared.sentinelEnabled)
            }

            if let target = Settings.shared.sentinelLockedTarget {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(accent)
                    Text("Locked Target:").font(.system(size: 12, weight: .semibold))
                    Text(target.displayName).font(.system(size: 12))
                    Spacer()
                    Button("Unlock") { perform(.unlockTarget) }.controlSize(.small)
                }
                .padding(10)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Toggle("Intervene after a warning", isOn: setting(\.sentinelAct))
                Spacer()
                Text("Warning: \(Int(Settings.shared.warnSeconds))s · Cooldown: \(Int(Settings.shared.cooldownSeconds))s")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let warning = state.warning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).foregroundStyle(.orange).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Dismiss warning") { perform(.dismissWarning) }.controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // Real-Time Detection Events (Debug Log)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Real-Time Detection Event Log").font(.system(size: 14, weight: .semibold))
                    Text("Every front app switch, window focus, tab switch, and URL navigation is timestamped and evaluated instantly.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Log") {
                    SentinelEventLog.shared.clear()
                    refreshSentinelEvents()
                }.controlSize(.small)
            }

            // Scrollable Event Table
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if sentinelEvents.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "waveform.path.ecg").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("No detection events recorded yet.").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            Text("Switch apps, change browser tabs, or click 'Check now' to observe real-time triggers.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        HStack {
                            Text("Time").frame(width: 85, alignment: .leading)
                            Text("Trigger").frame(width: 110, alignment: .leading)
                            Text("Target Context").frame(width: 180, alignment: .leading)
                            Text("Outcome").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Status").frame(width: 65, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Divider()

                        ForEach(sentinelEvents) { evt in
                            HStack(alignment: .top) {
                                Text(evt.timeString)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 85, alignment: .leading)
                                    .foregroundStyle(.secondary)

                                Text(evt.trigger)
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 110, alignment: .leading)
                                    .lineLimit(1)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(evt.app)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                    if !evt.windowTitle.isEmpty {
                                        Text(evt.windowTitle)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    } else if let d = evt.domain {
                                        Text(d)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 180, alignment: .leading)

                                Text(evt.outcome)
                                    .font(.system(size: 10))
                                    .foregroundStyle(evt.isDrift ? .orange : .primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(evt.isDrift ? "DRIFT" : "ON TASK")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(evt.isDrift ? .orange : .green)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background((evt.isDrift ? Color.orange : Color.green).opacity(0.12), in: Capsule())
                                    .frame(width: 65, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
        }
    }

    // MARK: - Persistent Memory Viewer

    private var memoryViewer: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Study Rhythm Metrics
            let profile = StudyLearner.shared.profile
            HStack(spacing: 24) {
                metricCard("Focus Time", value: "\(Int(profile.totalFocusMinutes)) min", icon: "clock")
                metricCard("Sessions", value: "\(profile.sessionsCompleted)", icon: "checkmark.circle")
                metricCard("Streak", value: "\(profile.streakDays) days", icon: "flame")
                metricCard("Memories Saved", value: "\(memoriesList.count)", icon: "internaldrive")
            }

            Divider()

            // Filter & Search Controls
            HStack {
                Picker("Type", selection: $memoryFilter) {
                    Text("All Types").tag(MemoryType?.none)
                    ForEach(MemoryType.allCases, id: \.self) { type in
                        Text(type.title).tag(MemoryType?.some(type))
                    }
                }.pickerStyle(.segmented).frame(maxWidth: 420)

                Spacer()

                Button {
                    showAddMemory.toggle()
                } label: {
                    Label(showAddMemory ? "Cancel" : "Add Memory", systemImage: showAddMemory ? "xmark" : "plus")
                }

                Button(role: .destructive) {
                    isConfirmingForget = true
                } label: {
                    Label("Forget Everything", systemImage: "trash")
                }.buttonStyle(.bordered)
            }

            if showAddMemory {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Category", selection: $newMemoryType) {
                            ForEach(MemoryType.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu).frame(width: 200)
                        TextField("Context (e.g. When searching lecture notes)", text: $newMemoryContext)
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
                        }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search memories, profile facts, preferences, lessons…", text: $memoryQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: memoryQuery) { _ in refreshMemories() }
                if !memoryQuery.isEmpty {
                    Button(action: { memoryQuery = ""; refreshMemories() }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            // Memory List
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if filteredMemories.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "brain").font(.system(size: 32)).foregroundStyle(.secondary)
                            Text("No memories found.").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                            Text("Bluey automatically extracts your preferences, facts, and corrections from conversation. You can also add them manually above.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ForEach(filteredMemories) { item in
                            memoryCard(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("🔒 100% Private · Stored in local SQLite database on your Mac (`~/Library/Application Support/Googly/memory.sqlite`). Never sent to external analytics.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .confirmationDialog("Forget Everything?", isPresented: $isConfirmingForget) {
            Button("Forget Everything (Delete All Memories)", role: .destructive) {
                MemoryStore.shared.forgetEverything()
                refreshMemories()
            }
        } message: {
            Text("This will permanently erase all learned profile facts, preferences, past task outcomes, and corrections stored on this Mac.")
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.type == .lesson ? .orange : accent)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background((item.type == .lesson ? Color.orange : accent).opacity(0.12), in: Capsule())

                if let ctx = item.triggerContext, !ctx.isEmpty {
                    Text("When \(ctx)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                Text(item.updatedAt, style: .date).font(.system(size: 10)).foregroundStyle(.secondary)

                Button {
                    editingMemory = item
                    editingContent = item.content
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }.buttonStyle(.plain)

                Button(role: .destructive) {
                    MemoryStore.shared.delete(id: item.id)
                    refreshMemories()
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red.opacity(0.8))
                }.buttonStyle(.plain)
            }

            if editingMemory?.id == item.id {
                HStack {
                    TextField("Content", text: $editingContent).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        MemoryStore.shared.update(id: item.id, content: editingContent)
                        editingMemory = nil
                        refreshMemories()
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { editingMemory = nil }.controlSize(.small)
                }
            } else {
                Text(item.content).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Token & Context Caching View

    private var cacheDebugView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Gemini & DeepSeek Context Caching Savings").font(.system(size: 16, weight: .medium))
            Text("Automatic prefix context caching reuses system prompt, tool definitions, and screen guidelines across turns at ~75% lower cost.")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            // Cumulative Cards
            HStack(spacing: 20) {
                metricCard("Cache Hit Rate", value: String(format: "%.1f%%", cacheStats.overallHitRate * 100), icon: "bolt.fill")
                metricCard("Cached Tokens", value: "\(cacheStats.totalCachedTokens)", icon: "arrow.triangle.2.circlepath")
                metricCard("Total Prompt Tokens", value: "\(cacheStats.totalPromptTokens + cacheStats.totalCachedTokens)", icon: "tray.full")
                metricCard("Est. Savings", value: String(format: "$%.4f", cacheStats.totalSavingsUSD), icon: "dollarsign.circle")
            }

            HStack {
                Text("Recent Requests Log").font(.system(size: 14, weight: .medium))
                Spacer()
                Button("Reset Stats") {
                    CacheTracker.shared.reset()
                    refreshCache()
                }.controlSize(.small)
            }

            // Table of recent requests
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if cacheLogs.isEmpty {
                        Text("No requests recorded yet. Talk to Bluey to see real-time context cache statistics.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    } else {
                        HStack {
                            Text("Time").frame(width: 80, alignment: .leading)
                            Text("Model").frame(width: 140, alignment: .leading)
                            Text("Tier").frame(width: 80, alignment: .leading)
                            Text("Cached").frame(width: 70, alignment: .trailing)
                            Text("Prompt").frame(width: 70, alignment: .trailing)
                            Text("Hit %").frame(width: 60, alignment: .trailing)
                            Text("Latency").frame(width: 70, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Divider()

                        ForEach(cacheLogs) { log in
                            HStack {
                                Text(log.timestamp, style: .time).frame(width: 80, alignment: .leading)
                                Text(log.model).frame(width: 140, alignment: .leading).lineLimit(1)
                                Text(log.tierName).frame(width: 80, alignment: .leading)
                                Text("\(log.cachedTokens)").frame(width: 70, alignment: .trailing).foregroundStyle(log.cachedTokens > 0 ? .green : .secondary)
                                Text("\(log.promptTokens)").frame(width: 70, alignment: .trailing)
                                Text(String(format: "%.0f%%", log.cacheHitRate * 100)).frame(width: 60, alignment: .trailing)
                                Text("\(log.latencyMs)ms").frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func metricCard(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(accent).font(.system(size: 13))
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
    }

    // MARK: - Settings & AI Brain View

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: AI Brain & Dual-Model Routing
                Text("AI Brain & Dual-Model Routing").font(.system(size: 17, weight: .semibold))

                Picker("Routing Mode", selection: $routingMode) {
                    ForEach(ModelRoutingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: routingMode) { Settings.shared.modelRoutingMode = $0 }

                // Explanatory card
                VStack(alignment: .leading, spacing: 6) {
                    Text("💡 **How Dual-Model Routing Works:**").font(.system(size: 12))
                    Text("• **⚡ Fast Model:** Handles casual conversation, greetings, jokes, and quick timer questions.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("• **🧠 Flagship Model:** Handles computer-use (clicks, types, shortcuts), screen understanding, planning, and multi-step tasks.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("• **Per-message Override:** Say *\"use big brain for this\"* or *\"use fast model\"* on any request to override the classifier.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(12).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                // Fast Model Configuration
                VStack(alignment: .leading, spacing: 8) {
                    Label("Fast Model (Lite / Quick Tier)", systemImage: "bolt.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    HStack {
                        Picker("Provider", selection: $fastProvider) {
                            Text("Gemini 3.1 Flash Lite").tag(AIProvider.gemini)
                            Text("Token Harbor").tag(AIProvider.tokenHarbor)
                            Text("DeepSeek").tag(AIProvider.deepseek)
                            Text("Custom").tag(AIProvider.custom)
                        }
                        .frame(width: 240)
                        .onChange(of: fastProvider) { Settings.shared.fastProvider = $0 }

                        TextField("Model Name", text: $fastModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: fastModel) { Settings.shared.fastCustomModel = $0 }
                    }
                }
                .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

                // Flagship Model Configuration
                VStack(alignment: .leading, spacing: 8) {
                    Label("Flagship Model (Big Brain / Computer-Use Tier)", systemImage: "brain")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    HStack {
                        Picker("Provider", selection: $flagshipProvider) {
                            Text("DeepSeek").tag(AIProvider.deepseek)
                            Text("Gemini Pro / Flash").tag(AIProvider.gemini)
                            Text("Token Harbor").tag(AIProvider.tokenHarbor)
                            Text("Custom").tag(AIProvider.custom)
                        }
                        .frame(width: 240)
                        .onChange(of: flagshipProvider) { Settings.shared.flagshipProvider = $0 }

                        TextField("Model Name", text: $flagshipModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: flagshipModel) { Settings.shared.flagshipCustomModel = $0 }
                    }
                }
                .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

                Toggle("Allow fallback to another provider if preferred key is unavailable", isOn: $fallback)
                    .onChange(of: fallback) { Settings.shared.providerFallback = $0 }

                Divider()

                // Section 2: API Keys Configuration (Unbugged, Dedicated inputs)
                Text("API Keys & Providers").font(.system(size: 17, weight: .semibold))
                Text("Keys are stored securely in macOS Keychain. Each provider can be configured individually.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                // Gemini Key
                keyRow(name: "Gemini API Key", placeholder: "AIzaSy…", key: .gemini, input: $geminiKeyInput)
                // Token Harbor Key
                keyRow(name: "Token Harbor API Key", placeholder: "thk_live_…", key: .tokenHarbor, input: $tokenHarborKeyInput)
                // DeepSeek Key
                keyRow(name: "DeepSeek API Key", placeholder: "sk-…", key: .deepseek, input: $deepseekKeyInput)

                // Custom Endpoint Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom OpenAI-Compatible Provider").font(.system(size: 13, weight: .medium))
                    TextField("Endpoint (e.g. https://api.together.xyz/v1)", text: $customEndpoint)
                        .textFieldStyle(.roundedBorder).onChange(of: customEndpoint) { Settings.shared.customEndpoint = $0 }
                    HStack {
                        TextField("Custom Model Name", text: $customModel)
                            .textFieldStyle(.roundedBorder).onChange(of: customModel) { Settings.shared.customModel = $0 }
                        Toggle("Vision support", isOn: $customVision)
                            .onChange(of: customVision) { Settings.shared.customVision = $0 }
                    }
                    keyRow(name: "Custom API Key", placeholder: "Bearer token…", key: .custom, input: $customKeyInput)
                }
                .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button(testingConnection ? "Testing Connection…" : "Test Active AI Connection") {
                        testingConnection = true
                        Task {
                            defer { testingConnection = false }
                            do { connectionResult = try await AIClient.testConnection() }
                            catch { connectionResult = "Error: \(error.localizedDescription)" }
                        }
                    }.disabled(testingConnection)

                    if !keyStatusMessage.isEmpty {
                        Text(keyStatusMessage).font(.system(size: 12)).foregroundStyle(.green)
                    }
                }
                if !connectionResult.isEmpty {
                    Text(connectionResult).font(.system(size: 12)).textSelection(.enabled)
                }

                Divider()

                // Section 3: Assistant & Permissions
                Text("Assistant & Actions").font(.system(size: 17, weight: .semibold))
                Toggle("Allow computer actions (clicks, keyboard, apps)", isOn: setting(\.computerControl))
                Picker("Action permissions", selection: Binding(get: { Settings.shared.autonomyMode }, set: { Settings.shared.autonomyMode = $0; revision += 1 })) {
                    ForEach(AutonomyMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Text("Full access runs requested actions without Bluey's confirmation prompts. macOS permissions still apply.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                if ExecutionGate.shared.isStopped {
                    Button("Resume Bluey") {
                        ExecutionGate.shared.resume()
                        state.taskStatus = "Ready when you are"
                        revision += 1
                        DockCompanion.shared.refresh()
                    }
                } else {
                    Button("Emergency Stop Bluey") { perform(.cancelTask); revision += 1 }
                }

                Toggle("Speak replies and focus nudges", isOn: setting(\.voiceEnabled))
                Toggle("Learn from focus sessions (Hermes Study Engine)", isOn: setting(\.aiLearningEnabled))

                HStack {
                    Label(ComputerControl.isTrusted ? "Accessibility allowed" : "Accessibility needed for computer actions",
                          systemImage: ComputerControl.isTrusted ? "checkmark.circle" : "hand.raised")
                    Spacer()
                    Button("Open System Settings") { ComputerControl.openAccessibilitySettings() }
                }.font(.system(size: 12))

                Divider()

                // Section 4: Sanctra Integration
                Text("Sanctra Study Account").font(.system(size: 17, weight: .semibold))
                if sanctra.isConnected, let acc = sanctra.account {
                    HStack {
                        Label("Connected as \(acc.displayName)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Disconnect") {
                            Keychain.set(.sanctraPersonalToken, nil)
                            sanctra.refreshConnection()
                        }.buttonStyle(.bordered)
                    }
                    if let streaks = sanctra.studyContext?.streaks, let days = streaks.streakDays {
                        Text("Current study streak: \(days) days · Timezone: \(acc.timezone)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Generate a personal token in Sanctra Settings > Integrations > Bluey and paste it below.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    SecureField("Personal token · sanctra_personal_…", text: $sanctraToken).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Connect Sanctra") {
                            let clean = sanctraToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !clean.isEmpty else { return }
                            Keychain.set(.sanctraPersonalToken, clean)
                            sanctraToken = ""
                            sanctra.refreshConnection()
                        }.disabled(sanctraToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(testingSanctra ? "Testing…" : "Test connection") {
                            testingSanctra = true
                            Task {
                                defer { testingSanctra = false }
                                do {
                                    let acc = try await sanctra.client.fetchAccount()
                                    sanctraMessage = "Connected to \(acc.displayName) (\(acc.timezone))"
                                } catch {
                                    sanctraMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                    if !sanctraMessage.isEmpty {
                        Text(sanctraMessage).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(.bottom, 20)
        }.id(revision)
    }

    private func keyRow(name: String, placeholder: String, key: Keychain.Key, input: Binding<String>) -> some View {
        let isConfigured = Keychain.get(key) != nil
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    if isConfigured {
                        Text("✓ Saved in Keychain").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
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
            }.disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Helpers

    private func refreshAll() {
        refreshMemories()
        refreshCache()
        refreshSentinelEvents()
        BlueyCoordinator.shared.refresh()
    }

    private func refreshMemories() {
        memoriesList = MemoryStore.shared.allMemories()
    }

    private func refreshCache() {
        let snap = CacheTracker.shared.snapshot()
        cacheStats = snap.stats
        cacheLogs = snap.recentLogs
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
