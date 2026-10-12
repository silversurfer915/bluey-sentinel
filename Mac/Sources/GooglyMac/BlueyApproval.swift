import Foundation

/// An actual user decision, separate from model text and scoped to exactly one proposed action.
@MainActor
final class BlueyApproval {
    static let shared = BlueyApproval()
    private var continuation: CheckedContinuation<Bool, Never>?
    func request(_ description: String) async -> Bool {
        guard continuation == nil, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                BlueyState.shared.pendingConfirmation = description
                BlueyState.shared.taskStatus = "Waiting for your confirmation"
                BlueyWorkspace.shared.show()
                NotchController.shared.refreshPresentation()
                if Task.isCancelled { resolve(false) }
            }
        }, onCancel: { Task { @MainActor in self.resolve(false) } })
    }
    func resolve(_ allowed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        BlueyState.shared.pendingConfirmation = nil
        BlueyWorkspace.shared.prepareForTask()
        continuation.resume(returning: allowed)
    }
}

enum ActionPolicy {
    static func requiresConfirmation(name: String, label: String, arguments: [String: Any]) -> Bool {
        let consequential = ["send", "post", "publish", "delete", "trash", "buy", "purchase", "pay", "submit", "confirm", "checkout", "erase", "remove", "save changes", "install", "uninstall", "allow", "grant"]
        let lower = label.lowercased()
        if name == "click" {
            return label == "that spot" || consequential.contains { lower.contains($0) }
        }
        if name == "type_text" { return arguments["press_return"] as? Bool == true || (arguments["text"] as? String ?? "").contains("\n") }
        if name == "press_keys" {
            let keys = (arguments["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "command", with: "cmd")
            return ["return", "enter", "cmd+w", "cmd+q", "cmd+delete", "cmd+backspace", "delete", "backspace"].contains(keys)
        }
        return false
    }
}
