import Foundation

enum NotchPresentation: Equatable {
    case warning, task, listening, passive
    static func choose(warning: Bool, busy: Bool, listening: Bool) -> Self {
        if warning { return .warning }
        if busy { return .task }
        if listening { return .listening }
        return .passive
    }
}
