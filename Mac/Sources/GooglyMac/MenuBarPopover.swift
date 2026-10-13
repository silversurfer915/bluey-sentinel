import AppKit
import SwiftUI

/// Actions the popover needs from the app. Implemented by `AppDelegate` so the
/// view stays declarative and the lifecycle logic stays in one place.
@MainActor
struct MenuBarActions {
    var ask: () -> Void
    var openFocus: () -> Void
    var startFocus: () -> Void
    var openWorkspace: () -> Void
    var openSettings: () -> Void
    var emergencyStop: () -> Void
    var resume: () -> Void
    var quit: () -> Void
}

/// Compact menu-bar control surface. Content-driven, 360 pt wide, scrolls on
/// short displays. Mirrors the canonical session state; never infers state.
struct MenuBarPopoverView: View {
    let actions: MenuBarActions

    @ObservedObject private var state = BlueyState.shared
    @ObservedObject private var microphones = MicrophoneStore.shared
    private let settings = Settings.shared
    private let coordinator = BlueyCoordinator.shared

    private var stopped: Bool { ExecutionGate.shared.isStopped }

    private var statusKind: StatusBadge.Kind {
        if stopped { return .stopped }
        if state.busy { return .working }
        if state.listening { return .listening }
        if coordinator.focusClock.isActive { return coordinator.paused ? .paused : .active }
        if state.warning != nil { return .needsPermission }
        return .ready
    }

    private var statusLabel: String {
        if stopped { return "Stopped" }
        if state.busy { return "Working" }
        if state.listening { return "Listening" }
        if coordinator.focusClock.isActive { return coordinator.paused ? "Paused" : "Focus active" }
        if state.warning != nil { return "Attention needed" }
        return "Ready"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BlueyTheme.space4) {
                identityRow
                Divider().overlay(BlueyTheme.separator)
                focusBlock
                Divider().overlay(BlueyTheme.separator)
                askRow
                quickActions
                Divider().overlay(BlueyTheme.separator)
                safetyRow
                footerRow
            }
            .padding(BlueyTheme.space4)
        }
        .frame(width: 360)
        .frame(maxHeight: 520)
        .background(BlueyTheme.surface)
    }

    // MARK: Rows

    private var identityRow: some View {
        HStack(spacing: BlueyTheme.space3) {
            BlueyMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bluey").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(BlueyTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: BlueyTheme.space2)
            StatusBadge(statusKind, label: statusLabel)
        }
    }

    private var subtitle: String {
        let provider = state.activeProvider.isEmpty ? "No provider" : state.activeProvider
        return "\(provider) · \(microphones.activeName)"
    }

    @ViewBuilder
    private var focusBlock: some View {
        if coordinator.focusClock.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                activeFocus(now: context.date)
            }
        } else {
            VStack(alignment: .leading, spacing: BlueyTheme.space2) {
                Text("No focus session active").font(.system(size: 13)).foregroundStyle(BlueyTheme.textSecondary)
                Button("Start focus", action: actions.startFocus).buttonStyle(.borderedProminent)
            }
        }
    }

    private func activeFocus(now: Date) -> some View {
        let elapsed = coordinator.focusClock.elapsed(at: now)
        let planned = Double(coordinator.plannedSeconds)
        let progress = planned > 0 ? min(1, elapsed / planned) : nil
        let subject = settings.focusGoal.isEmpty ? "Focus session" : settings.focusGoal
        return VStack(alignment: .leading, spacing: BlueyTheme.space2) {
            Text("ACTIVE FOCUS").font(.system(size: 10, weight: .bold)).foregroundStyle(BlueyTheme.textTertiary)
            HStack(alignment: .firstTextBaseline) {
                Text(subject).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(Self.clock(elapsed))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("Elapsed \(Int(elapsed / 60)) minutes")
            }
            FocusThread(progress: progress, paused: coordinator.paused)
            HStack {
                Text(planned > 0 ? "of \(Self.clock(planned))" : "No planned duration")
                    .font(.system(size: 11)).foregroundStyle(BlueyTheme.textSecondary)
                Spacer()
                if coordinator.paused {
                    Button("Resume") { Task { await coordinator.execute(.resumeFocus) } }.controlSize(.small)
                } else {
                    Button("Pause") { Task { await coordinator.execute(.pauseFocus(0)) } }.controlSize(.small)
                }
                Button("Open Focus", action: actions.openFocus).controlSize(.small)
            }
        }
    }

    private var askRow: some View {
        Button(action: actions.ask) {
            HStack {
                Image(systemName: "text.bubble").foregroundStyle(BlueyTheme.textSecondary)
                Text("Ask Bluey…").foregroundStyle(BlueyTheme.textSecondary)
                Spacer()
                Text("⌥ Space").font(.system(size: 11, design: .monospaced)).foregroundStyle(BlueyTheme.textTertiary)
            }
            .padding(.horizontal, BlueyTheme.space3)
            .frame(height: BlueyTheme.controlHeightMac)
            .background(BlueyTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: BlueyTheme.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BlueyTheme.radiusControl, style: .continuous).strokeBorder(BlueyTheme.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Bluey")
    }

    private var quickActions: some View {
        HStack(spacing: BlueyTheme.space2) {
            Button("Start focus", action: actions.startFocus).buttonStyle(.borderedProminent)
            microphoneMenu
            Spacer()
        }
    }

    private var microphoneMenu: some View {
        Picker("Microphone", selection: Binding(
            get: { microphones.selectedUID },
            set: { microphones.select($0) }
        )) {
            Text("System default").tag("")
            ForEach(microphones.devices) { device in
                Text(device.name).tag(device.uid)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 190)
        .accessibilityLabel("Choose microphone")
    }

    private var safetyRow: some View {
        HStack(spacing: BlueyTheme.space2) {
            if stopped {
                Button("Resume Bluey", action: actions.resume).buttonStyle(.borderedProminent)
            } else {
                Button(role: .destructive, action: actions.emergencyStop) {
                    Label("Emergency Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button("Open Bluey workspace", action: actions.openWorkspace).controlSize(.small)
        }
    }

    private var footerRow: some View {
        HStack {
            Button("Settings", action: actions.openSettings).controlSize(.small)
            Spacer()
            Button("Quit", action: actions.quit).controlSize(.small)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Owns the popover presentation and keeps one instance across opens.
@MainActor
final class MenuBarPopoverController {
    private let popover = NSPopover()

    init(actions: MenuBarActions) {
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: MenuBarPopoverView(actions: actions))
        if #available(macOS 13.0, *) { controller.sizingOptions = [.preferredContentSize] }
        popover.contentViewController = controller
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func close() { popover.performClose(nil) }
}
