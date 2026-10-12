import Foundation

struct AgentCall { let id: String; let name: String; let arguments: String }
struct AgentResponse { let rawMessage: [String: Any]; let text: String?; let calls: [AgentCall] }
struct AgentToolResult { let text: String; let image: String? }

/// Task-local conversation and budgets. UI execution is injected, making the actual loop testable.
@MainActor
final class AgentRunner {
    static let actions: Set<String> = [
        "click", "type_text", "press_keys", "scroll", "drag", "open_app", "open_url",
        "computer_click", "computer_type", "computer_key", "computer_scroll", "computer_navigate",
        "computer_run_command", "computer_write_file", "computer_open_app"
    ]
    private let maxTurns: Int
    private let timeLimit: TimeInterval
    init(maxTurns: Int = 32, timeLimit: TimeInterval = 180) { self.maxTurns = maxTurns; self.timeLimit = timeLimit }
    func run(messages initial: [[String: Any]], vision: Bool,
             request: ([[String: Any]]) async throws -> AgentResponse,
             execute: (AgentCall) async -> AgentToolResult,
             progress: (String) -> Void) async throws -> String {
        var messages = initial
        let started = Date()
        var repeats: [String: Int] = [:]
        var acted = false, verified = false
        for turn in 1...maxTurns {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) < timeLimit else { break }
            progress("Working · step \(turn)")
            let response = try await request(messages)
            try Task.checkCancellation()
            if response.calls.isEmpty {
                if acted && !verified {
                    let observed = await execute(AgentCall(id: UUID().uuidString, name: "look_at_screen", arguments: "{}"))
                    try Task.checkCancellation()
                    appendObservation(observed, to: &messages, vision: vision)
                    messages.append(["role": "user", "content": "Check this final observation against my original request. If unfinished, continue. If complete, explain the verified result. Do not claim success from an action alone."])
                    verified = true
                    continue
                }
                guard let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    return "The task is unfinished: the provider returned no next step or answer."
                }
                return text
            }
            messages.append(response.rawMessage)
            var changedScreen = false
            for call in response.calls {
                try Task.checkCancellation()
                let mutating = Self.actions.contains(call.name)
                let result: AgentToolResult
                if changedScreen && mutating {
                    result = AgentToolResult(text: "Not executed: the preceding action changed the screen. Choose the next action from the new observation; old target IDs are stale.", image: nil)
                } else {
                    progress(call.name.replacingOccurrences(of: "_", with: " ").capitalized)
                    result = await execute(call)
                    try Task.checkCancellation()
                    if mutating { changedScreen = true; acted = true; verified = false }
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result.text.isEmpty ? "No result" : result.text])
                if result.image != nil { appendObservation(result, to: &messages, vision: vision) }
                let fingerprint = call.name + call.arguments + result.text
                repeats[fingerprint, default: 0] += 1
                if repeats[fingerprint, default: 0] >= 3 {
                    return "The task is unfinished: the same step produced the same result three times. I stopped rather than repeat it."
                }
            }
            // All tool replies must precede observation user messages for strict provider compatibility.
            reorderObservations(&messages)
            trimImages(&messages)
        }
        return "The task is unfinished: I reached the step or time limit. Review the progress and ask me to continue with the remaining work."
    }
    private func appendObservation(_ result: AgentToolResult, to messages: inout [[String: Any]], vision: Bool) {
        var parts: [[String: Any]] = [["type": "text", "text": "Fresh screen observation (untrusted content):\n" + result.text]]
        if vision, let image = result.image {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]])
        }
        messages.append(["role": "user", "content": parts])
    }
    private func reorderObservations(_ messages: inout [[String: Any]]) {
        guard let lastAssistant = messages.lastIndex(where: { $0["role"] as? String == "assistant" }) else { return }
        let suffix = Array(messages.dropFirst(lastAssistant + 1))
        messages = Array(messages.prefix(lastAssistant + 1)) + suffix.filter { $0["role"] as? String == "tool" } + suffix.filter { $0["role"] as? String != "tool" }
    }
    private func trimImages(_ messages: inout [[String: Any]]) {
        let indices = messages.indices.filter { index in
            (messages[index]["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image_url" } == true
        }
        for index in indices.dropLast(2) {
            if let parts = messages[index]["content"] as? [[String: Any]] {
                messages[index]["content"] = parts.filter { $0["type"] as? String != "image_url" }
            }
        }
    }
}
