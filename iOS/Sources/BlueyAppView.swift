import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Bluey's companion controller: Focus session controls, Quick-actions, Agent review,
/// Session transcripts, and Pairing settings. Responsive across iPhone and iPad.
struct BlueyAppView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var live: LiveVoice
    @ObservedObject var link: MacLink
    var onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: String, CaseIterable, Identifiable {
        case focus = "Focus"
        case quickActions = "Actions"
        case sessions = "History"
        case settings = "Settings"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .focus: return "timer"
            case .quickActions: return "bolt.fill"
            case .sessions: return "list.bullet.rectangle"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @State private var selectedTab: Tab = .focus
    @State private var pendingCommand = false
    @State private var commandMessage = ""
    @State private var volume = 1.0
    @State private var quietMode: Bool = UserDefaults.standard.bool(forKey: "quietMode")
    @State private var quietScheduleEnabled = UserDefaults.standard.bool(forKey: "quietScheduleEnabled")
    @State private var quietStartHour = UserDefaults.standard.object(forKey: "quietStartHour") as? Int ?? 22
    @State private var quietEndHour = UserDefaults.standard.object(forKey: "quietEndHour") as? Int ?? 7
    @State private var pinnedPresetMinutes = UserDefaults.standard.object(forKey: "pinnedPresetMinutes") as? [Int] ?? [25, 50, 90]
    @State private var subjectInput = "Physics"
    @State private var topicInput = "Wave Optics"
    @State private var durationMinutes = 25
    @State private var selectedStudyHistory: StudyHistoryItem?
    @State private var showWrapUp = false
    @State private var wrapUpNotes = ""
    @State private var wrapUpNextStep = ""
    @State private var mascotOffset: CGFloat = 0
    @State private var mascotScale: CGFloat = 1.0
    @State private var celebrationCheckmark = false
    @State private var lastHandledEventId: String? = UserDefaults.standard.string(forKey: "lastHandledStudyEventId")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let code = link.pairingSASCode, !link.isPaired {
                    VStack(spacing: 10) {
                        Text("Pair with your Mac").font(.headline)
                        Text(code).font(.title.monospaced())
                        Text("Compare this code on both devices. Confirm only if they match.").font(.callout)
                        Button("Codes match — pair") { link.confirmPairing(accepted: true) }.buttonStyle(.borderedProminent)
                        Button("Cancel", role: .cancel) { link.confirmPairing(accepted: false) }
                    }.padding().background(.regularMaterial)
                }
                if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
                    // iPad or wide landscape layout
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 240)
                            .background(Color(hex: Palette.panel).opacity(0.8))
                        Divider().overlay(Color.white.opacity(0.1))
                        tabContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // iPhone compact layout
                    VStack(spacing: 0) {
                        tabHeader
                        tabContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(Color.black)
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(store: store, id: id)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showWrapUp) {
                wrapUpSheet
            }
            .sheet(item: $selectedStudyHistory) { item in
                studyHistoryDetail(item)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color(hex: Palette.berry1))
        .overlay(alignment: .bottom) {
            if pendingCommand || !commandMessage.isEmpty {
                HStack(spacing: 8) {
                    if pendingCommand { ProgressView() }
                    Text(pendingCommand ? "Waiting for Mac…" : commandMessage).font(.callout)
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            }
        }
        .onAppear {
            volume = live.volume
            handleEventAnimation(link.snapshot.lastEventId)
        }
        .onChange(of: link.snapshot.lastEventId) { _, eventId in
            handleEventAnimation(eventId)
        }
    }

    // MARK: - Header / Tabs for iPhone

    private var tabHeader: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    MiniBluey()
                        .frame(width: 34, height: 30)
                        .scaleEffect(mascotScale)
                        .offset(y: mascotOffset)
                    Text("Bluey")
                        .font(.fredoka(22))
                        .foregroundStyle(.white)
                }
                Spacer()
                connectionBadge
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Bluey face")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        selectedTab = tab
                        triggerHaptic(.selection)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12))
                            Text(tab.rawValue)
                                .font(.plexSans(13).weight(.medium))
                        }
                        .foregroundStyle(selectedTab == tab ? .white : Color(hex: Palette.inkSoft))
                        .frame(minWidth: 76, minHeight: 44)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 10).fill(Color(hex: Palette.berry1).opacity(0.7))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            }
            .padding(4)
            .background(Color(hex: Palette.panel).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .background(Color(hex: Palette.panel).opacity(0.3))
    }

    // MARK: - Sidebar for iPad

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    MiniBluey()
                        .frame(width: 50, height: 44)
                        .scaleEffect(mascotScale)
                        .offset(y: mascotOffset)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bluey")
                            .font(.fredoka(26))
                            .foregroundStyle(.white)
                        connectionBadge
                    }
                }

                VStack(spacing: 6) {
                    ForEach(Tab.allCases) { tab in
                        Button {
                            selectedTab = tab
                            triggerHaptic(.selection)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 16))
                                Text(tab.rawValue)
                                    .font(.fredoka(16))
                                Spacer()
                            }
                            .foregroundStyle(selectedTab == tab ? .white : Color(hex: Palette.inkSoft))
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: Palette.berry1).opacity(0.8))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    }
                }

                Divider().overlay(Color.white.opacity(0.1))

                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Image(systemName: "face.smiling")
                        Text("Back to face")
                    }
                    .font(.plexSans(14).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!link.connected || !link.isPaired || pendingCommand)
                if pendingCommand { ProgressView("Waiting for Mac…") }
                if !commandMessage.isEmpty { Text(commandMessage).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(20)
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(link.connected ? Color(hex: 0x5BE49B) : Color(hex: Palette.inkSoft).opacity(0.5))
                .frame(width: 8, height: 8)
            Text(link.connected ? (link.macName ?? link.currentMac ?? "Mac") : "Offline")
                .font(.plexSans(12))
                .foregroundStyle(Color(hex: Palette.inkSoft))
                .lineLimit(1)
        }
    }

    // MARK: - Tab Content Switcher

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .focus:
            focusControllerView
        case .quickActions:
            quickActionsView
        case .sessions:
            sessionList
        case .settings:
            settingsView
        }
    }

    // MARK: - 1. Focus Controller View

    private var focusControllerView: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let notice = link.controllerNotice {
                    Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 12))
                }
                // Pending Agent Approval Card (if any)
                if let approval = link.snapshot.pendingApproval {
                    agentApprovalCard(approval)
                }

                // Latched Emergency Stop Banner
                if link.snapshot.isStopped {
                    emergencyStopBanner
                }

                // Focus Timer Ring & Session Info
                timerCard

                // Controls
                focusActionsBar

                // Wrap-up button
                Button {
                    showWrapUp = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                        Text("Session Wrap-Up & Notes")
                    }
                    .font(.plexSans(14).weight(.semibold))
                    .foregroundStyle(Color(hex: Palette.berry2))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
    }

    private var timerCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.snapshot.subjectLabel ?? subjectInput)
                        .font(.fredoka(20))
                        .foregroundStyle(.white)
                    Text(link.snapshot.topicLabel ?? topicInput)
                        .font(.plexSans(14))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                }
                Spacer()
                Text(link.snapshot.isPaused ? "PAUSED" : (link.snapshot.isActive ? "FOCUSING" : "IDLE"))
                    .font(.plexMono(11).weight(.bold))
                    .foregroundStyle(link.snapshot.isActive ? (link.snapshot.isPaused ? Color.orange : Color(hex: 0x5BE49B)) : Color(hex: Palette.inkSoft))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            // Circular progress or badge
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 10)
                    .frame(width: 140, height: 140)

                let progress = link.snapshot.plannedSeconds > 0
                    ? min(Double(link.snapshot.elapsedSeconds) / Double(link.snapshot.plannedSeconds), 1.0)
                    : 0.0

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(BlobShape.linear, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text(formatSeconds(link.snapshot.elapsedSeconds))
                        .font(.plexMono(24).weight(.bold))
                        .foregroundStyle(.white)
                    Text("/ \(link.snapshot.plannedSeconds / 60)m")
                        .font(.plexMono(12))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                }

                if celebrationCheckmark {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color(hex: 0x5BE49B))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                Label(link.snapshot.syncStatus.capitalized, systemImage: "arrow.triangle.2.circlepath")
                    .font(.plexMono(11))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                Spacer()
                Label(link.snapshot.autonomyMode, systemImage: "shield.lefthalf.filled")
                    .font(.plexMono(11))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
            }
        }
        .padding(18)
        .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 18))
    }

    private var focusActionsBar: some View {
        VStack(spacing: 10) {
            Group {
            if !link.snapshot.isActive {
                // Config inputs
                adaptiveControlLayout {
                    TextField("Subject", text: $subjectInput)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)

                    TextField("Topic", text: $topicInput)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 8) {
                    ForEach([15, 25, 45, 60], id: \.self) { mins in
                        Button {
                            durationMinutes = mins
                            triggerHaptic(.selection)
                        } label: {
                            Text("\(mins)m")
                                .font(.plexMono(13).weight(.medium))
                                .foregroundStyle(durationMinutes == mins ? .white : Color(hex: Palette.inkSoft))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(durationMinutes == mins ? Color(hex: Palette.berry2) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    runCommand { done in link.startFocus(subjectLabel: subjectInput, topicLabel: topicInput, durationMinutes: durationMinutes, completion: done) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Start Focus Session")
                    }
                    .font(.fredoka(18))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(BlobShape.linear, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(!link.connected || !link.isPaired || pendingCommand)
                .opacity(link.connected ? 1.0 : 0.5)

            } else {
                // Active session controls: Pause / Resume / Finish / Abandon
                adaptiveControlLayout {
                    if link.snapshot.isPaused {
                        Button {
                                    runCommand { done in link.resumeFocus(completion: done) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Resume")
                            }
                            .font(.fredoka(16))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color(hex: 0x5BE49B), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                                    runCommand { done in link.pauseFocus(completion: done) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "pause.fill")
                                Text("Pause")
                            }
                            .font(.fredoka(16))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                            runCommand { done in link.finishFocus(completion: done) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text("Finish")
                        }
                        .font(.fredoka(16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color(hex: Palette.berry1), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    triggerHaptic(.warning)
                    runCommand { done in link.abandonFocus(completion: done) }
                } label: {
                    Text("Abandon Session")
                        .font(.plexSans(13))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            }
            .disabled(!link.connected || !link.isPaired || pendingCommand)

            // Latched Emergency Stop Trigger
            Button {
                triggerHaptic(.stop)
                if link.snapshot.isStopped {
                    runCommand(cue: .resume) { done in link.resumeExecution(completion: done) }
                } else {
                    runCommand(cue: .stop) { done in link.emergencyStop(completion: done) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: link.snapshot.isStopped ? "play.circle.fill" : "hand.raised.fill")
                    Text(link.snapshot.isStopped ? "Resume Execution" : "Emergency Stop (Mac)")
                }
                .font(.plexSans(14).weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(link.snapshot.isStopped ? Color.orange : Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .disabled(!link.connected || !link.isPaired || pendingCommand)
        }
    }

    private var emergencyStopBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text("Emergency Stop Active")
                    .font(.plexSans(14).weight(.bold))
                    .foregroundStyle(.white)
                Text("All Mac input and agent actions are latched off.")
                    .font(.plexSans(12))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
            }
            Spacer()
            Button {
                runCommand(cue: .resume) { done in link.resumeExecution(completion: done) }
            } label: {
                Text("Resume")
                    .font(.plexSans(12).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.red.opacity(0.4), lineWidth: 1))
    }

    private func agentApprovalCard(_ approval: AgentApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(Color(hex: Palette.berry2))
                Text("Action Review Requested")
                    .font(.fredoka(16))
                    .foregroundStyle(.white)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(approval.actionName)
                    .font(.plexMono(13).weight(.bold))
                    .foregroundStyle(.white)
                Text(approval.targetDescription)
                    .font(.plexSans(13))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                if let details = approval.details {
                    Text(details)
                        .font(.plexSans(12))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button {
                    triggerHaptic(.warning)
                    runCommand { done in link.respondToApproval(id: approval.id, approve: false, completion: done) }
                } label: {
                    Text("Decline")
                        .font(.plexSans(14).weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button {
                    runCommand { done in link.respondToApproval(id: approval.id, approve: true, completion: done) }
                } label: {
                    Text("Approve")
                        .font(.plexSans(14).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color(hex: 0x5BE49B), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: Palette.berry2), lineWidth: 1.5))
    }

    // MARK: - 2. Quick Actions View

    private var quickActionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Quick Study Actions")
                    .font(.fredoka(22))
                    .foregroundStyle(.white)

                Text("Trigger common focus shortcuts and Mac commands directly.")
                    .font(.plexSans(13))
                    .foregroundStyle(Color(hex: Palette.inkSoft))

                VStack(spacing: 12) {
                    quickActionRow(
                        title: "Check Focus Now",
                        subtitle: "Inspect front window and test study continuity",
                        icon: "eye.fill",
                        color: Color(hex: Palette.berry2)
                    ) {
                        triggerHaptic(.selection)
                        runCommand { done in link.quickAction(.checkFocus, completion: done) }
                    }

                    quickActionRow(
                        title: "Lock Current Window",
                        subtitle: "Keep current document or browser tab locked as goal",
                        icon: "lock.fill",
                        color: Color(hex: 0x5BE49B)
                    ) {
                        triggerHaptic(.selection)
                        runCommand { done in link.quickAction(.lockWindow, completion: done) }
                    }

                    quickActionRow(
                        title: "Open Session Notes",
                        subtitle: "Reveal today's Markdown transcript folder on Mac",
                        icon: "doc.text.fill",
                        color: Color.orange
                    ) {
                        triggerHaptic(.selection)
                        runCommand { done in link.quickAction(.openNotes, completion: done) }
                    }

                    quickActionRow(
                        title: "Plan My Day",
                        subtitle: "Ask Bluey to review syllabus and create study plan",
                        icon: "calendar.badge.clock",
                        color: Color(hex: Palette.berry1)
                    ) {
                        triggerHaptic(.selection)
                        runCommand { done in link.quickAction(.requestDayPlan, completion: done) }
                    }
                }

                Text("Focus Presets")
                    .font(.fredoka(18))
                    .foregroundStyle(.white)
                    .padding(.top, 10)

                if pinnedPresetMinutes.isEmpty {
                    Text("Pin your study presets in Settings.").font(.callout).foregroundStyle(.secondary)
                }
                adaptiveControlLayout {
                    ForEach(pinnedPresetMinutes.sorted(), id: \.self) { minutes in
                        presetCard(title: presetTitle(minutes), mins: minutes, icon: minutes == 25 ? "bolt.fill" : "book.fill")
                    }
                }
            }
            .padding(18)
        }
    }

    private func quickActionRow(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.plexSans(15).weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.plexSans(12))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.2))
            }
            .padding(14)
            .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!link.connected || !link.isPaired || pendingCommand)
    }

    private func presetCard(title: String, mins: Int, icon: String) -> some View {
        Button {
            triggerHaptic(.start)
            durationMinutes = mins
            runCommand { done in link.startFocus(subjectLabel: subjectInput, topicLabel: topicInput, durationMinutes: mins, completion: done) }
            selectedTab = .focus
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: Palette.berry1))
                Text(title)
                    .font(.fredoka(16))
                    .foregroundStyle(.white)
                Text("\(mins) mins")
                    .font(.plexMono(12))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!link.connected || !link.isPaired || pendingCommand)
    }

    // MARK: - 3. Settings & Pairing View

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings & Companion")
                    .font(.fredoka(22))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 12) {
                    label("Quiet Mode & Haptics")
                    Toggle("Quiet Mode", isOn: Binding(
                        get: { quietMode },
                        set: {
                            quietMode = $0
                            UserDefaults.standard.set($0, forKey: "quietMode")
                        }
                    ))
                    .font(.plexSans(15))
                    .foregroundStyle(.white)

                    Text("Silence study and action haptics. Voice volume is controlled separately.")
                        .font(.plexSans(12))
                        .foregroundStyle(Color(hex: Palette.inkSoft))

                    Divider().overlay(Color.white.opacity(0.1))

                    Toggle("Scheduled quiet hours", isOn: $quietScheduleEnabled)
                        .onChange(of: quietScheduleEnabled) { _, value in UserDefaults.standard.set(value, forKey: "quietScheduleEnabled") }
                    if quietScheduleEnabled {
                        Picker("Quiet from", selection: $quietStartHour) {
                            ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
                        }.onChange(of: quietStartHour) { _, value in UserDefaults.standard.set(value, forKey: "quietStartHour") }
                        Picker("Until", selection: $quietEndHour) {
                            ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
                        }.onChange(of: quietEndHour) { _, value in UserDefaults.standard.set(value, forKey: "quietEndHour") }
                        Text("Uses this device's local time. Matching start and end means quiet all day.").font(.caption).foregroundStyle(.secondary)
                    }
                    label("Chirp Volume")
                    Slider(value: Binding(get: { volume }, set: { volume = $0; live.volume = $0 }), in: 0...1)
                }
                .padding(16)
                .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    label("Pinned Focus Presets")
                    ForEach([15, 25, 50, 90], id: \.self) { minutes in
                        Toggle("\(presetTitle(minutes)) · \(minutes) min", isOn: Binding(
                            get: { pinnedPresetMinutes.contains(minutes) },
                            set: { selected in
                                if selected { pinnedPresetMinutes.append(minutes) } else { pinnedPresetMinutes.removeAll { $0 == minutes } }
                                UserDefaults.standard.set(pinnedPresetMinutes, forKey: "pinnedPresetMinutes")
                            }))
                    }
                }.padding(16).background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    label("Trusted Pairing")
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.isPaired ? (link.connected ? "Paired & Encrypted" : "Paired · Mac offline") : (link.pairingSASCode != nil ? "Confirm pairing code" : "Looking for Mac"))
                                .font(.plexSans(15).weight(.semibold))
                                .foregroundStyle(link.isPaired ? Color(hex: 0x5BE49B) : Color.orange)
                            if let sas = link.pairingSASCode {
                                Text("Verification Code: \(sas)")
                                    .font(.plexMono(13))
                                    .foregroundStyle(.white)
                            }
                        }
                        Spacer()
                        Image(systemName: link.isPaired ? "lock.shield.fill" : "lock.open")
                            .font(.system(size: 24))
                            .foregroundStyle(link.isPaired ? Color(hex: 0x5BE49B) : Color.orange)
                    }

                    if let code = link.pairingSASCode, !link.isPaired {
                        Text("Compare this code with Bluey on your Mac: \(code). Confirm only when both codes match.").font(.callout).foregroundStyle(.white)
                        Button("Codes match — pair") { link.confirmPairing(accepted: true) }.buttonStyle(.borderedProminent)
                        Button("Cancel pairing", role: .cancel) { link.confirmPairing(accepted: false) }
                    }
                    if link.macs.count > 1 {
                        Divider().overlay(Color.white.opacity(0.1))
                        label("Available Macs")
                        ForEach(link.macs, id: \.self) { name in
                            Button { link.choose(name) } label: {
                                HStack {
                                    Text(name).font(.plexSans(14)).foregroundStyle(.white)
                                    Spacer()
                                    if name == link.currentMac {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color(hex: Palette.berry2))
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
                .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(18)
        }
    }

    // MARK: - 4. Wrap-Up Sheet

    private var wrapUpSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session Wrap-Up")
                    .font(.fredoka(22))
                    .foregroundStyle(.white)

                Text("Record what you accomplished and what to tackle next.")
                    .font(.plexSans(13))
                    .foregroundStyle(Color(hex: Palette.inkSoft))

                VStack(alignment: .leading, spacing: 6) {
                    label("What did I learn / complete?")
                    TextEditor(text: $wrapUpNotes)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                        .frame(minHeight: 90)
                }

                VStack(alignment: .leading, spacing: 6) {
                    label("Next step for next session")
                    TextField("e.g. Solve HC Verma Chapter 3 problems 1-10", text: $wrapUpNextStep)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }

                Spacer()

                Button {
                    runCommand { done in
                        link.saveWrapUpNotes(notes: wrapUpNotes, nextStep: wrapUpNextStep) { acknowledgement in
                            done(acknowledgement)
                            if acknowledgement?.success == true { showWrapUp = false }
                        }
                    }
                } label: {
                    Text("Save to Sanctra Session")
                        .font(.fredoka(16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(BlobShape.linear, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Dismiss") { showWrapUp = false }
                        .foregroundStyle(Color(hex: Palette.berry2))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Event Animations & Mascot Reactions

    private func handleEventAnimation(_ eventId: String?) {
        guard let eventId, eventId != lastHandledEventId else { return }
        lastHandledEventId = eventId
        UserDefaults.standard.set(eventId, forKey: "lastHandledStudyEventId")

        if eventId.hasPrefix("start") {
            triggerHaptic(.start)
            if reduceMotion {
                mascotScale = 1.05
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                    mascotOffset = -12
                    mascotScale = 1.15
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        mascotOffset = 0
                        mascotScale = 1.0
                    }
                }
            }
        } else if eventId.hasPrefix("pause") {
            triggerHaptic(.pause)
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.5)) {
                    mascotScale = 0.95
                    mascotOffset = 2
                }
            }
        } else if eventId.hasPrefix("resume") {
            triggerHaptic(.resume)
            mascotScale = 1.0
            mascotOffset = 0
        } else if eventId.hasPrefix("finish") {
            triggerHaptic(.complete)
            celebrationCheckmark = true
            if reduceMotion {
                mascotScale = 1.0
            } else {
                withAnimation(.bouncy(duration: 0.5)) {
                    mascotOffset = -16
                    mascotScale = 1.2
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        mascotOffset = 0
                        mascotScale = 1.0
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(reduceMotion ? nil : .default) { celebrationCheckmark = false }
            }
        }
    }

    private func presetTitle(_ minutes: Int) -> String {
        switch minutes { case 15: return "Warm-up"; case 25: return "Sprint"; case 50: return "Deep Work"; default: return "Exam Prep" }
    }

    private var adaptiveControlLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
    }

    private func runCommand(cue: HapticType? = nil, _ operation: (@escaping (CommandAcknowledgement?) -> Void) -> Void) {
        guard !pendingCommand else { return }
        pendingCommand = true
        commandMessage = ""
        operation { acknowledgement in
            DispatchQueue.main.async {
                pendingCommand = false
                if let acknowledgement, acknowledgement.success {
                    commandMessage = "Confirmed by Mac"
                    if let cue { triggerHaptic(cue) }
                } else {
                    commandMessage = acknowledgement?.errorMessage ?? "Mac did not confirm. Check the connection and try again."
                }
            }
        }
    }

    // MARK: - Haptic Feedback Helpers

    enum HapticType {
        case selection, start, pause, resume, complete, stop, warning
    }

    private func triggerHaptic(_ type: HapticType) {
        let hour = Calendar.current.component(.hour, from: Date())
        let scheduledQuiet = quietScheduleEnabled && (quietStartHour == quietEndHour || (quietStartHour < quietEndHour ? (quietStartHour..<quietEndHour).contains(hour) : hour >= quietStartHour || hour < quietEndHour))
        guard !quietMode, !scheduledQuiet else { return }
        #if canImport(UIKit)
        switch type {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .start, .resume:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .pause:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .complete:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .stop, .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        #endif
    }

    private func formatSeconds(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.plexMono(11))
            .textCase(.uppercase)
            .foregroundStyle(Color(hex: Palette.inkSoft))
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            Section {
                if !link.connected {
                    Text("Connect to your paired Mac to refresh Sanctra history.").font(.callout)
                }
                if let error = link.historyError { Text(error).foregroundStyle(.red).font(.callout) }
                if link.historyLoading { ProgressView("Loading study sessions…") }
                if link.studyHistory.isEmpty && !link.historyLoading {
                    Text("No synced study sessions loaded.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(link.studyHistory) { item in
                    Button { selectedStudyHistory = item } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.subjectName ?? "Study session").font(.headline).foregroundStyle(.white)
                            if let topic = item.topicTitle, !topic.isEmpty { Text(topic).font(.callout).foregroundStyle(.secondary) }
                            Text("\(historyDate(item)) · \(formatSeconds(item.durationSeconds ?? 0)) focused")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                    }.listRowBackground(Color(hex: Palette.panel))
                }
                if link.historyNextCursor != nil {
                    Button("Load more study sessions") { link.refreshHistory(loadMore: true) }
                        .disabled(link.historyLoading || !link.connected || !link.isPaired)
                }
                Button("Refresh study history") { link.refreshHistory() }
                    .disabled(link.historyLoading || !link.connected || !link.isPaired)
            } header: { Text("Sanctra Study History") }

            Section {
                if store.sessions.isEmpty {
                    Text("No local voice recordings yet. Transcripts appear here after a conversation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session, live: session.id == store.currentID)
                    }.listRowBackground(Color(hex: Palette.panel))
                }
                .onDelete { offsets in offsets.map { store.sessions[$0].id }.forEach(store.delete) }
            } header: { Text("Local Voice Transcripts") }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .task { if link.connected && link.isPaired { link.refreshHistory() } }
        .onChange(of: link.isPaired) { _, paired in if paired { link.refreshHistory() } }
    }

    private func historyDate(_ item: StudyHistoryItem) -> String {
        if let timestamp = item.startTime {
            return Date(timeIntervalSince1970: timestamp / 1000).formatted(date: .abbreviated, time: .shortened)
        }
        return item.date ?? "Date unavailable"
    }

    private func studyHistoryDetail(_ item: StudyHistoryItem) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.subjectName ?? "Study session").font(.title2.weight(.semibold))
                    if let topic = item.topicTitle { Text(topic).font(.headline) }
                    Text(historyDate(item)).foregroundStyle(.secondary)
                    Label("\(formatSeconds(item.durationSeconds ?? 0)) focused", systemImage: "timer")
                    if let source = item.source { Text("Recorded by \(source)").font(.callout).foregroundStyle(.secondary) }
                    Divider()
                    Text(item.notes?.isEmpty == false ? item.notes! : "No session notes.").textSelection(.enabled)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Study Session")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { selectedStudyHistory = nil } } }
        }
    }

}

// MARK: - Helper Views & MiniBluey

private struct SessionRow: View {
    let session: BlueySession
    let live: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.started.formatted(date: .abbreviated, time: .shortened))
                        .font(.plexSans(15).weight(.semibold))
                        .foregroundStyle(.white)
                    if live {
                        Text("LIVE")
                            .font(.plexMono(10).weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: 0x5BE49B), in: Capsule())
                    }
                }
                Text(session.summary)
                    .font(.plexSans(13))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.duration(session.duration))
                    .font(.plexMono(12))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                Text("\(session.questionCount) asked")
                    .font(.plexMono(11))
                    .foregroundStyle(Color(hex: Palette.berry1))
            }
        }
        .padding(.vertical, 4)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct SessionDetailView: View {
    @ObservedObject var store: SessionStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private func copyPrompt(_ session: BlueySession) {
        let root = "~/Documents/Bluey Notes"
        let path = session.notesPath.map { p -> String in
            if let range = p.range(of: "/Documents/Bluey Notes") { return "~" + p[range.lowerBound...] }
            return p
        } ?? "\(root)/ (the folder starting \(session.started.formatted(.iso8601.year().month().day())))"
        let prompt = """
        I recorded a meeting with my Bluey app on \(session.started.formatted(date: .complete, time: .shortened)). \
        The notes are on my Mac in \(path)

        - notes.md: the full transcript with timestamps and speaker labels (A, B, … per five-minute chunk), plus \
        my questions to Bluey, its replies and research reports. Start here.
        - session.json: the same data, structured.
        - audio/: the original recording in five-minute chunks.

        All my sessions are in \(root)/, one folder per session (see README.md there). Read the notes, then help me \
        with: 
        """
        #if canImport(UIKit)
        UIPasteboard.general.string = prompt
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private var session: BlueySession? { store.sessions.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to history")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session?.started.formatted(date: .abbreviated, time: .shortened) ?? "Session")
                            .font(.fredoka(20))
                        if let session {
                            Text("\(SessionRow.duration(session.duration)) · \(session.questionCount) asked"
                                + (session.transcribing > 0 ? " · transcribing…" : ""))
                                .font(.plexMono(11)).foregroundStyle(Color(hex: Palette.inkSoft))
                        }
                    }
                    Spacer(minLength: 0)
                    if let session {
                        ShareLink(item: session.exportText) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }.accessibilityLabel("Share session transcript")
                    }
                }
                if let session {
                    Button { copyPrompt(session) } label: {
                        Label(copied ? "Copied" : "Copy prompt for agent", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.plexSans(13).weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color(hex: Palette.berry3), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session?.displayEntries ?? []) { entry in
                            EntryView(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                }
                .onAppear { if let last = session?.entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: session?.entries.count) { _, _ in
                    if let last = session?.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct EntryView: View {
    static func speakerColor(_ speaker: String?) -> Color {
        let colors: [UInt32] = [0x8FB3FF, 0x5BE49B, 0xFFB86B, 0xFF9AD0, 0xC79BFF, 0x6BE3E0]
        guard let first = speaker?.unicodeScalars.first?.value, speaker != "?" else { return Color(hex: Palette.inkSoft) }
        return Color(hex: colors[Int(first) % colors.count])
    }

    let entry: TranscriptEntry
    @State private var open = false

    var body: some View {
        switch entry.kind {
        case .transcript:
            HStack(alignment: .top, spacing: 10) {
                Text(entry.speaker.map { "Speaker \($0)" } ?? "Speaker")
                    .font(.plexMono(11).weight(.medium))
                    .foregroundStyle(Self.speakerColor(entry.speaker))
                    .frame(width: 78, alignment: .leading)
                    .padding(.top, 2)
                Text(entry.text)
                    .font(.plexSans(15))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.time.formatted(date: .omitted, time: .shortened))
                    .font(.plexMono(10))
                    .foregroundStyle(Color(hex: Palette.inkSoft).opacity(0.7))
                    .padding(.top, 3)
            }
        case .heard:
            Text(entry.text)
                .font(.plexSans(14))
                .foregroundStyle(Color(hex: Palette.inkSoft))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        case .asked:
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("You asked")
                        .font(.plexMono(10))
                        .foregroundStyle(Color(hex: Palette.berry1))
                    Text(entry.text)
                        .font(.plexSans(15).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(BlobShape.linear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        case .reply:
            HStack(alignment: .bottom, spacing: 8) {
                MiniBluey().frame(width: 28, height: 25)
                Text(entry.text)
                    .font(.fredoka(16))
                    .foregroundStyle(Color(hex: Palette.ink))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 120)
            }
        case .report:
            let lines = entry.text.components(separatedBy: "\n\n")
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.spring(duration: 0.3)) { open.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Color(hex: Palette.berry2))
                        Text(lines.first ?? "Research")
                            .font(.fredoka(16))
                            .foregroundStyle(Color(hex: Palette.ink))
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: open ? "minus" : "plus")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color(hex: Palette.berry2)))
                    }
                }
                .buttonStyle(.plain)
                Text(lines.dropFirst().joined(separator: "\n\n"))
                    .font(.plexSans(14))
                    .foregroundStyle(Color(hex: Palette.ink))
                    .lineLimit(open ? nil : 3)
            }
            .padding(14)
            .background(Color(hex: 0xEEF0FF), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: Palette.berry2), lineWidth: 2))
            .padding(.leading, 36)
            .padding(.trailing, 80)
        }
    }
}

/// A tiny Bluey: the blueberry blob with two googly eyes.
struct MiniBluey: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                BlobShape().fill(BlobShape.linear)
                HStack(spacing: w * 0.1) {
                    ForEach(0..<2, id: \.self) { _ in
                        Circle()
                            .fill(.white)
                            .frame(width: w * 0.26, height: w * 0.26)
                            .overlay(Circle().fill(Color(hex: Palette.ink)).frame(width: w * 0.12).offset(x: w * 0.02, y: w * 0.03))
                    }
                }
                .offset(y: -w * 0.04)
            }
        }
    }
}
