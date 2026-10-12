import SwiftUI
import WidgetKit
import ActivityKit

struct FocusEntry: TimelineEntry {
    let date: Date
    let snapshot: FocusWidgetSnapshot?
}
struct FocusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FocusEntry { FocusEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (FocusEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FocusEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(900))))
    }
    private func read() -> FocusEntry {
        let data = UserDefaults(suiteName: FocusWidgetSnapshot.appGroup)?.data(forKey: FocusWidgetSnapshot.cacheKey)
        return FocusEntry(date: Date(), snapshot: data.flatMap { try? JSONDecoder().decode(FocusWidgetSnapshot.self, from: $0) })
    }
}
struct FocusWidgetView: View {
    let entry: FocusEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Bluey Focus", systemImage: "leaf.fill").font(.caption).foregroundStyle(.secondary)
            if let snapshot = entry.snapshot, snapshot.isActive {
                Text(snapshot.title).font(.headline).lineLimit(1)
                if snapshot.isPaused { Text("Paused · \(snapshot.elapsedSeconds / 60)m").font(.title3.monospacedDigit()) }
                else { Text(snapshot.recordedAt.addingTimeInterval(-Double(snapshot.elapsedSeconds)), style: .timer).font(.title3.monospacedDigit()) }
                Link(snapshot.isPaused ? "Open to resume" : "Open to pause", destination: snapshot.controlURL(snapshot.isPaused ? "resume" : "pause")!)
                    .font(.caption)
                Text("Last Mac sync \(snapshot.recordedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            } else { Text("Open Bluey to focus").font(.headline) }
        }
        .containerBackground(.blue.opacity(0.12), for: .widget)
        .widgetURL(URL(string: "bluey://open"))
    }
}
struct BlueyFocusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BlueyFocusWidget", provider: FocusProvider()) { FocusWidgetView(entry: $0) }
            .configurationDisplayName("Bluey Focus")
            .description("Last confirmed Mac session. Open Bluey on the same network to control it.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
struct BlueyFocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(context.state.title, systemImage: "leaf.fill").font(.headline)
                timer(context.state)
                Link(context.state.isPaused ? "Open to resume" : "Open to pause", destination: controlURL(context))
                    .font(.caption)
                Text("Last foreground Mac sync. Reopen Bluey to refresh.").font(.caption2).foregroundStyle(.secondary)
            }.padding().activityBackgroundTint(Color.blue.opacity(0.15))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "leaf.fill") }
                DynamicIslandExpandedRegion(.center) { Text(context.state.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) { timer(context.state) }
                DynamicIslandExpandedRegion(.bottom) { Link("Open Bluey", destination: controlURL(context)) }
            } compactLeading: { Image(systemName: "leaf.fill") }
              compactTrailing: { timer(context.state) }
              minimal: { Image(systemName: context.state.isPaused ? "pause.fill" : "leaf.fill") }
              .widgetURL(controlURL(context))
        }
    }
    @ViewBuilder private func timer(_ state: FocusActivityAttributes.ContentState) -> some View {
        if state.isPaused { Text("Paused").font(.caption) }
        else { Text(state.recordedAt.addingTimeInterval(-Double(state.elapsedSeconds)), style: .timer).monospacedDigit() }
    }
    private func controlURL(_ context: ActivityViewContext<FocusActivityAttributes>) -> URL {
        var c = URLComponents(); c.scheme = "bluey"; c.host = "session"
        c.path = context.state.isPaused ? "/resume" : "/pause"
        c.queryItems = [URLQueryItem(name: "id", value: context.attributes.sessionId), URLQueryItem(name: "revision", value: String(context.state.revision))]
        return c.url!
    }
}
@main struct BlueyWidgetBundle: WidgetBundle {
    var body: some Widget { BlueyFocusWidget(); BlueyFocusLiveActivity() }
}
