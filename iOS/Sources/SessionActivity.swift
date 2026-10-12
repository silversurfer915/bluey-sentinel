import Foundation
import ActivityKit
import WidgetKit
#if canImport(GooglyShared)
import GooglyShared
#endif

@MainActor
final class SessionActivity {
    static let shared = SessionActivity()
    private var pendingURL: (url: URL, expires: Date)?
    private var previous: PhoneSessionSnapshot?
    private var lastUpdate = Date.distantPast
    private var updateTask: Task<Void, Never>?

    func update(_ snapshot: PhoneSessionSnapshot) {
        let changed = previous?.sessionId != snapshot.sessionId || previous?.isPaused != snapshot.isPaused || previous?.isActive != snapshot.isActive || previous?.revision != snapshot.revision
        guard changed || Date().timeIntervalSince(lastUpdate) >= 30 else { return }
        previous = snapshot; lastUpdate = Date()
        let cached = FocusWidgetSnapshot(snapshot)
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults(suiteName: FocusWidgetSnapshot.appGroup)?.set(data, forKey: FocusWidgetSnapshot.cacheKey)
            WidgetCenter.shared.reloadTimelines(ofKind: "BlueyFocusWidget")
        }
        updateTask?.cancel()
        updateTask = Task {
            for activity in Activity<FocusActivityAttributes>.activities where activity.attributes.sessionId != snapshot.sessionId || !snapshot.isActive {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            guard snapshot.isActive, let sid = snapshot.sessionId, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let content = ActivityContent(state: FocusActivityAttributes.ContentState(cached), staleDate: Date().addingTimeInterval(90))
            if let current = Activity<FocusActivityAttributes>.activities.first(where: { $0.attributes.sessionId == sid }) {
                await current.update(content)
            } else {
                _ = try? Activity.request(attributes: FocusActivityAttributes(sessionId: sid), content: content, pushType: nil)
            }
        }
    }

    func resumePending(link: MacLink) {
        guard let pending = pendingURL else { return }
        pendingURL = nil
        guard pending.expires > Date() else { link.controllerNotice = "Widget action expired. Open the current session controls."; return }
        handle(url: pending.url, link: link)
    }
    func handle(url: URL, link: MacLink) {
        guard url.scheme == "bluey", url.host == "session", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sid = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let revision = components.queryItems?.first(where: { $0.name == "revision" })?.value.flatMap(Int.init),
              let action = PhoneSessionCommand.Action(rawValue: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              [.pause, .resume, .finish].contains(action) else { return }
        // Links are bound to the displayed session. Mac validates again before applying.
        guard link.connected, link.isPaired else {
            pendingURL = (url, Date().addingTimeInterval(20))
            link.controllerNotice = "Waiting for the paired Mac before applying the widget action."
            return
        }
        guard link.snapshot.sessionId == sid, link.snapshot.revision == revision else {
            link.controllerNotice = "The session changed since this widget update. Use the current session controls."
            return
        }
        link.sendCommand(PhoneSessionCommand(action: action, sessionId: sid, expectedRevision: revision)) { ack in
            link.controllerNotice = ack?.success == true ? "Widget action confirmed by Mac." : (ack?.errorMessage ?? "The Mac did not confirm the widget action.")
        }
    }
}
