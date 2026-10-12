import Foundation

/// A foreground-confirmed snapshot; extensions never claim to have a live Mac connection.
public struct FocusWidgetSnapshot: Codable, Equatable, Sendable {
    public static let appGroup = "group.co.visionairy.googly"
    public static let cacheKey = "focusWidgetSnapshot"
    public var sessionId: String?
    public var revision: Int
    public var title: String
    public var topic: String?
    public var elapsedSeconds: Int
    public var isPaused: Bool
    public var isActive: Bool
    public var recordedAt: Date

    public init(_ snapshot: PhoneSessionSnapshot, at date: Date = Date()) {
        sessionId = snapshot.sessionId; revision = snapshot.revision
        title = snapshot.subjectLabel ?? "Bluey Focus"; topic = snapshot.topicLabel
        elapsedSeconds = snapshot.elapsedSeconds; isPaused = snapshot.isPaused
        isActive = snapshot.isActive; recordedAt = date
    }
    public func elapsed(at date: Date = Date()) -> Int {
        elapsedSeconds + (isActive && !isPaused ? max(0, Int(date.timeIntervalSince(recordedAt))) : 0)
    }
    public func controlURL(_ action: String) -> URL? {
        guard let sessionId else { return URL(string: "bluey://open") }
        var components = URLComponents()
        components.scheme = "bluey"; components.host = "session"; components.path = "/" + action
        components.queryItems = [URLQueryItem(name: "id", value: sessionId), URLQueryItem(name: "revision", value: String(revision))]
        return components.url
    }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
public struct FocusActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var elapsedSeconds: Int
        public var isPaused: Bool
        public var recordedAt: Date
        public var revision: Int
        public init(_ snapshot: FocusWidgetSnapshot) {
            title = snapshot.title; elapsedSeconds = snapshot.elapsedSeconds
            isPaused = snapshot.isPaused; recordedAt = snapshot.recordedAt; revision = snapshot.revision
        }
    }
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}
#endif
