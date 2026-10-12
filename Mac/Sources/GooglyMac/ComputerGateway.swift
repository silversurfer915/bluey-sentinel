//
//  ComputerGateway.swift
//  GooglyMac
//
//  Ported directly from:
//  - CopilotKit/openbot: server/src/computer/gateway.ts (createComputerGateway, govern, SnapshotStore, locateRef, audit)
//  - CopilotKit/OpenDots: src/server/computer-service.ts (ComputerService.action, permissions, audit, StaleSnapshotError)
//  - CopilotKit/openbot: agent-computer/src/index.ts (performAction, snapshotPage, StaleSnapshotError)
//

import AppKit
import Foundation

// MARK: - Gateway Errors
// Upstream: openbot/server/src/computer/gateway.ts & OpenDots/src/server/computer-service.ts

public enum ComputerGatewayError: LocalizedError {
    case disabled(String)
    case staleSnapshot(String)
    case elementNotFound(String)
    case humanHasControl(String)
    case secretRequired(String)
    case executionStopped(String)
    case invalidArguments(String)
    case unknownAction(String)

    public var errorDescription: String? {
        switch self {
        case .disabled(let reason):
            return "Computer permission disabled: \(reason)"
        case .staleSnapshot(let msg):
            return "Computer action returned StaleSnapshot (HTTP 409): \(msg)"
        case .elementNotFound(let ref):
            return "Element ref \"\(ref)\" was not found in the active snapshot. Call computer_snapshot again to refresh interactive elements."
        case .humanHasControl(let reason):
            return "The user has taken control of the computer. Wait for them to release control: \(reason)"
        case .secretRequired(let reason):
            return "A secret must not be entered directly by the model: \(reason)"
        case .executionStopped(let reason):
            return "Execution stopped: \(reason)"
        case .invalidArguments(let reason):
            return "Invalid arguments: \(reason)"
        case .unknownAction(let name):
            return "Unknown computer action: \(name)"
        }
    }
}

// MARK: - Snapshot Store
// Upstream: openbot/server/src/computer/snapshot-store.ts & agent-computer/src/index.ts

public final class ComputerSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var currentSnapshotId: UInt64 = 1
    private var activeSnapshot: ComputerSnapshotResult?
    private var elementsByRef: [String: ComputerSnapshotElement] = [:]

    public init() {}

    public func currentSnapshot() -> ComputerSnapshotResult? {
        lock.lock(); defer { lock.unlock() }
        return activeSnapshot
    }

    public func save(elements: [ComputerSnapshotElement], url: String, title: String) -> ComputerSnapshotResult {
        lock.lock(); defer { lock.unlock() }
        currentSnapshotId &+= 1
        let result = ComputerSnapshotResult(
            snapshotId: currentSnapshotId,
            url: url,
            title: title,
            elements: elements
        )
        activeSnapshot = result
        elementsByRef.removeAll(keepingCapacity: true)
        for element in elements {
            elementsByRef[element.ref] = element
        }
        return result
    }

    /// Resolves an element ref, enforcing strict snapshotId generation matching.
    /// Upstream: openbot/agent-computer/src/index.ts (`locateRef` & `StaleSnapshotError`)
    public func resolve(ref: String, snapshotId: UInt64) throws -> ComputerSnapshotElement {
        lock.lock(); defer { lock.unlock() }
        guard let active = activeSnapshot else {
            throw ComputerGatewayError.staleSnapshot("No snapshot has been taken yet. Call computer_snapshot first.")
        }
        if active.snapshotId != snapshotId {
            throw ComputerGatewayError.staleSnapshot("Snapshot ID mismatch (active: \(active.snapshotId), provided: \(snapshotId)). The screen moved or was refreshed; call computer_snapshot to receive fresh refs.")
        }
        guard let element = elementsByRef[ref] else {
            throw ComputerGatewayError.elementNotFound(ref)
        }
        return element
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        currentSnapshotId &+= 1
        activeSnapshot = nil
        elementsByRef.removeAll()
    }
}

// MARK: - Central Computer Gateway
// Upstream: openbot/server/src/computer/gateway.ts (`createComputerGateway`) & OpenDots/src/server/computer-service.ts

@MainActor
public final class ComputerGateway: ObservableObject {
    public static let shared = ComputerGateway()

    @Published public var permissions = ComputerPermissions()
    @Published public var humanHasControl = false
    @Published public var pendingHelpReason: String?
    @Published public var pendingSecretRequest: (label: String, ref: String)?
    @Published public private(set) var auditLog: [ComputerAuditEntry] = []

    public let workspace = ComputerWorkspace()
    public let shell: ComputerShell
    public let snapshotStore = ComputerSnapshotStore()

    var probe: () async -> FocusProbe = { await ScreenContext.probe() }
    var requestApproval: (String) async -> Bool = { await BlueyApproval.shared.request($0) }
    private var snapshotContext: FocusProbe?
    private var snapshotDate = Date.distantPast

    public init() {
        self.shell = ComputerShell(workspaceDir: workspace.rootPath)
    }

    private func checkExecution(mutating: Bool = false) throws {
        try Task.checkCancellation()
        guard !ExecutionGate.shared.isStopped else {
            throw ComputerGatewayError.executionStopped("Bluey execution gate is stopped.")
        }
        guard Settings.shared.computerControl, permissions.enabled else {
            throw ComputerGatewayError.disabled("Computer control is disabled in settings.")
        }
        if mutating && Settings.shared.autonomyMode == .off {
            throw ComputerGatewayError.disabled("Autonomy is off.")
        }
    }

    private static let mutations: Set<String> = ["computer_click", "computer_type", "computer_key", "computer_scroll", "computer_navigate", "computer_open_app", "computer_write_file", "computer_run_command"]
    private static let screenActions: Set<String> = ["computer_click", "computer_type", "computer_key", "computer_scroll"]

    private func validateSnapshotContext() async throws {
        guard let original = snapshotContext, Date().timeIntervalSince(snapshotDate) < 15 else {
            throw ComputerGatewayError.staleSnapshot("Take a fresh snapshot before interacting.")
        }
        let current = await probe()
        try checkExecution(mutating: true)
        guard Sentinel.sameTarget(original, current) else {
            snapshotStore.invalidate()
            throw ComputerGatewayError.staleSnapshot("The active app, window, or page changed.")
        }
    }

    private func validateElement(_ element: ComputerSnapshotElement) async throws {
        guard let rect = element.rect else { throw ComputerGatewayError.invalidArguments("Element has no actionable position.") }
        if let ax = element.axElement {
            guard ControlsReader.validate(ax, name: element.name, rect: rect) else { throw ComputerGatewayError.staleSnapshot("Control moved or changed. Take a new snapshot.") }
        } else {
            let fresh = try await ScreenReader.snapshot()
            try checkExecution(mutating: true)
            guard fresh.matchingApprovedTarget(Target(id: element.ref, text: element.name, rect: rect)) != nil else { throw ComputerGatewayError.staleSnapshot("Observed text moved or changed.") }
        }
        try await validateSnapshotContext()
    }

    private func needsApproval(name: String, args: [String: Any]) throws -> Bool {
        switch Settings.shared.autonomyMode {
        case .off: return false
        case .askEvery: return Self.mutations.contains(name)
        case .fullAccess: return false
        case .confirmConsequences:
            switch name {
            case "computer_click":
                guard let ref = args["ref"] as? String, let id = args["snapshotId"] as? NSNumber else { return true }
                let element = try snapshotStore.resolve(ref: ref, snapshotId: id.uint64Value)
                return ActionPolicy.requiresConfirmation(name: "click", label: element.name, arguments: args)
            case "computer_type": return ActionPolicy.requiresConfirmation(name: "type_text", label: "", arguments: ["text": args["text"] ?? "", "press_return": args["submit"] ?? false])
            case "computer_key": return ActionPolicy.requiresConfirmation(name: "press_keys", label: "", arguments: ["keys": args["key"] ?? ""])
            case "computer_run_command", "computer_write_file": return true
            default: return false
            }
        }
    }

    // MARK: - Control Handoff
    // Upstream: openbot/server/src/computer/gateway.ts (`takeControl`, `releaseControl`)

    public func takeControl(reason: String = "User requested control") {
        humanHasControl = true
        pendingHelpReason = reason
        snapshotStore.invalidate()
        recordAudit(action: "take_control", actor: "owner", outcome: "succeeded", detail: reason)
    }

    public func releaseControl() {
        humanHasControl = false
        pendingHelpReason = nil
        pendingSecretRequest = nil
        snapshotStore.invalidate()
        recordAudit(action: "release_control", actor: "owner", outcome: "succeeded")
    }

    // MARK: - Audit Logging
    // Upstream: OpenDots/src/server/computer-store.ts & openbot/server/src/audit.ts

    private func recordAudit(action: String, actor: String, outcome: String, detail: String? = nil) {
        let entry = ComputerAuditEntry(action: action, actor: actor, outcome: outcome, detail: detail)
        auditLog.append(entry)
        if auditLog.count > 100 {
            auditLog.removeFirst(auditLog.count - 100)
        }
    }

    // MARK: - Governed Action Dispatcher
    // Upstream: openbot/server/src/computer/gateway.ts (`govern`) & OpenDots/src/server/computer-service.ts (`action`)

    public func execute(name: String, arguments: [String: Any], actor: String = "agent") async throws -> [String: Any] {
        let mutating = Self.mutations.contains(name)
        try checkExecution(mutating: mutating)
        if humanHasControl && actor == "agent" {
            throw ComputerGatewayError.humanHasControl(pendingHelpReason ?? "User currently has control of the computer.")
        }

        // Check permission categories (browser, files, shell)
        let fileActions: Set<String> = ["computer_list_files", "computer_read_file", "computer_write_file"]
        if (fileActions.contains(name) || name.hasPrefix("computer_files_")) && !permissions.files {
            throw ComputerGatewayError.disabled("Workspace files access is disabled.")
        }
        if name == "computer_run_command" && !permissions.shell {
            throw ComputerGatewayError.disabled("Shell command execution is disabled.")
        }
        if (Self.screenActions.contains(name) || ["computer_snapshot", "computer_read", "computer_screenshot", "computer_navigate", "computer_open_app"].contains(name)) && !permissions.browser {
            throw ComputerGatewayError.disabled("Browser and screen interaction is disabled.")
        }

        if Self.screenActions.contains(name) { try await validateSnapshotContext() }
        let approvalRequired = try needsApproval(name: name, args: arguments)
        if mutating && approvalRequired {
            let original = await probe()
            let description = arguments["text"] as? String ?? arguments["command"] as? String ?? arguments["path"] as? String ?? arguments["ref"] as? String ?? name
            let approved = await requestApproval("Allow Bluey to \(name.replacingOccurrences(of: "computer_", with: "").replacingOccurrences(of: "_", with: " ")) “\(String(description.prefix(200)))”?")
            try checkExecution(mutating: true)
            guard approved else { throw ComputerGatewayError.executionStopped("User declined the action. Do not try another route.") }
            if Self.screenActions.contains(name) {
                guard Sentinel.sameTarget(original, await probe()) else { throw ComputerGatewayError.staleSnapshot("Target changed during confirmation.") }
                try await validateSnapshotContext()
            }
        }
        try checkExecution(mutating: mutating)
        recordAudit(action: name, actor: actor, outcome: "pending")
        let auditID = auditLog.last?.id

        do {
            let result = try await dispatch(name: name, args: arguments, actor: actor)
            if let auditIndex = auditLog.firstIndex(where: { $0.id == auditID }) {
                auditLog[auditIndex].outcome = "succeeded"
            }
            return result
        } catch {
            if let auditIndex = auditLog.firstIndex(where: { $0.id == auditID }) {
                auditLog[auditIndex].outcome = "failed"
                auditLog[auditIndex].detail = error.localizedDescription
            }
            throw error
        }
    }

    // MARK: - Tool Implementations
    // Upstream: openbot/server/src/computer/headless-tools.ts & agent-computer/src/index.ts

    private func dispatch(name: String, args: [String: Any], actor: String) async throws -> [String: Any] {
        switch name {

        // MARK: 1. Screen & DOM Snapshot
        case "computer_snapshot":
            return try await executeSnapshot()

        case "computer_read":
            return try await executeRead()

        case "computer_screenshot":
            return try await executeScreenshot()

        // MARK: 2. Mouse & Keyboard Actions
        case "computer_click":
            guard let ref = args["ref"] as? String else {
                throw ComputerGatewayError.invalidArguments("A 'ref' parameter is required.")
            }
            let snapshotId = (args["snapshotId"] as? NSNumber)?.uint64Value
                ?? UInt64(args["snapshotId"] as? Int ?? 0)
            guard snapshotId > 0 else {
                throw ComputerGatewayError.invalidArguments("A numeric 'snapshotId' parameter is required.")
            }
            return try await executeClick(ref: ref, snapshotId: snapshotId)

        case "computer_type":
            guard let ref = args["ref"] as? String else {
                throw ComputerGatewayError.invalidArguments("A 'ref' parameter is required.")
            }
            let snapshotId = (args["snapshotId"] as? NSNumber)?.uint64Value
                ?? UInt64(args["snapshotId"] as? Int ?? 0)
            guard snapshotId > 0 else {
                throw ComputerGatewayError.invalidArguments("A numeric 'snapshotId' parameter is required.")
            }
            let text = args["text"] as? String ?? ""
            let submit = args["submit"] as? Bool ?? false
            return try await executeType(ref: ref, snapshotId: snapshotId, text: text, submit: submit)

        case "computer_key":
            guard let key = args["key"] as? String, !key.isEmpty else {
                throw ComputerGatewayError.invalidArguments("A 'key' parameter is required.")
            }
            let ref = args["ref"] as? String
            let snapshotId = (args["snapshotId"] as? NSNumber)?.uint64Value
                ?? (args["snapshotId"] as? Int).map(UInt64.init)
            return try await executeKey(key: key, ref: ref, snapshotId: snapshotId)

        case "computer_scroll":
            let deltaY = (args["deltaY"] as? Double) ?? Double(args["deltaY"] as? Int ?? 600)
            guard deltaY.isFinite, abs(deltaY) <= 100_000 else { throw ComputerGatewayError.invalidArguments("Scroll delta must be between -100000 and 100000.") }
            return try await executeScroll(deltaY: deltaY)

        // MARK: 3. Browser & App Navigation
        case "computer_navigate":
            guard let urlString = args["url"] as? String, !urlString.isEmpty else {
                throw ComputerGatewayError.invalidArguments("A 'url' parameter is required.")
            }
            return try await executeNavigate(urlString: urlString)

        case "computer_open_app":
            guard let appName = args["name"] as? String, !appName.isEmpty else {
                throw ComputerGatewayError.invalidArguments("An application 'name' parameter is required.")
            }
            let status = await ComputerControl.openApp(appName)
            snapshotStore.invalidate()
            return ["ok": true, "status": status, "app": appName]

        // MARK: 4. File System Operations
        case "computer_list_files":
            let path = args["path"] as? String ?? "."
            let listing = try workspace.list(path)
            let entries = listing.entries.map { [
                "path": $0.path,
                "kind": $0.kind,
                "bytes": $0.bytes as Any
            ] }
            return [
                "ok": true,
                "path": listing.path,
                "entries": entries,
                "truncated": listing.truncated
            ]

        case "computer_read_file":
            guard let path = args["path"] as? String, !path.isEmpty else {
                throw ComputerGatewayError.invalidArguments("A 'path' parameter is required.")
            }
            let result = try workspace.read(path)
            return [
                "ok": true,
                "path": result.path,
                "text": result.text,
                "truncated": result.truncated,
                "bytes": result.bytes
            ]

        case "computer_write_file":
            guard let path = args["path"] as? String, !path.isEmpty else {
                throw ComputerGatewayError.invalidArguments("A 'path' parameter is required.")
            }
            guard let contents = args["contents"] as? String else {
                throw ComputerGatewayError.invalidArguments("A 'contents' string is required.")
            }
            let append = args["append"] as? Bool ?? false
            let result = try workspace.write(path, contents: contents, append: append)
            return [
                "ok": true,
                "path": result.path,
                "bytes": result.bytes,
                "appended": result.appended
            ]

        // MARK: 5. Shell Execution
        case "computer_run_command":
            guard let command = args["command"] as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ComputerGatewayError.invalidArguments("A 'command' parameter is required.")
            }
            let timeoutMs = (args["timeoutMs"] as? Double) ?? (args["timeoutMs"] as? Int).map(Double.init)
            let result = await shell.run(command: command, timeoutMs: timeoutMs)
            return [
                "ok": result.exitCode == 0,
                "command": result.command,
                "exitCode": result.exitCode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "truncated": result.truncated,
                "timedOut": result.timedOut,
                "elapsedMs": result.elapsedMs
            ]

        // MARK: 6. Human Takeover & Secrets
        case "computer_request_secret":
            guard let label = args["label"] as? String else {
                throw ComputerGatewayError.invalidArguments("A 'label' parameter is required.")
            }
            guard let ref = args["ref"] as? String else {
                throw ComputerGatewayError.invalidArguments("A 'ref' parameter is required.")
            }
            pendingSecretRequest = (label, ref)
            return [
                "ok": true,
                "waiting": true,
                "label": label,
                "message": "Waiting for the user to type \(label) directly into the page."
            ]

        case "computer_request_help":
            let reason = args["reason"] as? String ?? "Assistance required"
            takeControl(reason: reason)
            return [
                "ok": true,
                "waiting": true,
                "reason": reason,
                "message": "Handoff to user initiated: \(reason)"
            ]

        default:
            throw ComputerGatewayError.unknownAction(name)
        }
    }

    // MARK: - Detailed Subsystems

    private func executeSnapshot() async throws -> [String: Any] {
        // [STACK ADAPTATION: Maps native macOS accessibility elements & OCR text to SnapshotElement with numbered refs]
        let original = await probe()
        try checkExecution()
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let controlsData = ControlsReader.read(screen: screen)
        var elements: [ComputerSnapshotElement] = []
        var refCounter = 1

        for c in controlsData.controls {
            let el = ComputerSnapshotElement(
                ref: "\(refCounter)",
                role: c.kind,
                name: c.label.isEmpty ? c.kind : c.label,
                type: c.secure ? "password" : nil,
                rect: c.rect,
                axElement: c.element
            )
            elements.append(el)
            refCounter += 1
        }

        // Add detected OCR text lines if accessibility controls are sparse
        if let shot = try? await ScreenReader.snapshot() {
            for entry in shot.lines.prefix(50) {
                let el = ComputerSnapshotElement(
                    ref: "\(refCounter)",
                    role: "text",
                    name: entry.line.text,
                    rect: entry.line.rect
                )
                elements.append(el)
                refCounter += 1
            }
        }

        let frontApp = controlsData.app ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Desktop"
        let current = await probe()
        try checkExecution()
        guard Sentinel.sameTarget(original, current) else { throw ComputerGatewayError.staleSnapshot("Screen changed during capture.") }
        let windowTitle = current.windowTitle ?? ""
        snapshotContext = current
        snapshotDate = Date()
        let snapshot = snapshotStore.save(elements: elements, url: frontApp, title: windowTitle)

        let encodedElements = snapshot.elements.map { [
            "ref": $0.ref,
            "role": $0.role,
            "name": $0.name,
            "value": $0.value as Any
        ] }

        return [
            "ok": true,
            "snapshotId": snapshot.snapshotId,
            "url": snapshot.url,
            "title": snapshot.title,
            "elements": encodedElements,
            "truncated": snapshot.truncated,
            "capturedAt": snapshot.capturedAt
        ]
    }

    private func executeRead() async throws -> [String: Any] {
        let probe = await ScreenContext.probe()
        var text = ""
        if let shot = try? await ScreenReader.snapshot() {
            text = shot.lines.map { $0.line.text }.joined(separator: "\n")
        }
        return [
            "ok": true,
            "app": probe.app ?? "Unknown",
            "title": probe.windowTitle ?? "",
            "url": probe.url ?? "",
            "text": String(text.prefix(30_000)),
            "truncated": text.count > 30_000
        ]
    }

    private func executeScreenshot() async throws -> [String: Any] {
        let shot = try await ScreenReader.snapshot()
        let probe = await ScreenContext.probe()
        return [
            "ok": true,
            "base64": shot.jpeg.base64EncodedString(),
            "width": Double(shot.size.width),
            "height": Double(shot.size.height),
            "url": probe.url ?? probe.app ?? "Desktop",
            "capturedAt": ISO8601DateFormatter().string(from: Date())
        ]
    }

    private func executeClick(ref: String, snapshotId: UInt64) async throws -> [String: Any] {
        let element = try snapshotStore.resolve(ref: ref, snapshotId: snapshotId)
        try await validateElement(element)
        guard let rect = element.rect else {
            throw ComputerGatewayError.invalidArguments("Element \(ref) has no clickable position.")
        }
        
        var method = "direct_click"
        try checkExecution(mutating: true)
        if let ax = element.axElement {
            // Attempt direct AXUIElementPerformAction (zero mouse motion, zero cursor warps)
            var actionError = AXError.cannotComplete
            guard ExecutionGate.shared.perform({ actionError = AXUIElementPerformAction(ax, kAXPressAction as CFString) }) else { throw ComputerGatewayError.executionStopped("Stopped before click.") }
            if actionError == .success {
                method = "accessibility_press"
                try? await Task.sleep(for: .milliseconds(40))
                snapshotStore.invalidate()
                return ["ok": true, "action": "click", "ref": ref, "element": element.name, "method": method]
            }
        }

        // Fallback: post direct mouse event tap to window server coordinates WITHOUT moving mouse cursor
        let targetPoint = CGPoint(x: rect.midX, y: rect.midY)
        ComputerControl.postDirectClick(at: targetPoint)
        try? await Task.sleep(for: .milliseconds(60))

        // Click may change page: bump generation
        snapshotStore.invalidate()
        return ["ok": true, "action": "click", "ref": ref, "element": element.name, "method": method]
    }

    private func executeType(ref: String, snapshotId: UInt64, text: String, submit: Bool) async throws -> [String: Any] {
        let element = try snapshotStore.resolve(ref: ref, snapshotId: snapshotId)
        try await validateElement(element)
        
        // Security guard against password and credential fields
        let focused = ControlsReader.focusedField()
        let label = (element.name + " " + ControlsReader.focusedFieldLabel()).lowercased()
        if element.type == "password" || element.axElement.map(ControlsReader.isSecure) == true || focused.secure || ["password", "token", "api key", "card number", "cvv"].contains(where: { label.contains($0) }) {
            throw ComputerGatewayError.secretRequired("The field appears to be a secret. Use computer_request_secret to allow private user entry.")
        }

        var method = "direct_input"
        var directSetSucceeded = false

        if let ax = element.axElement {
            // First focus the element via AX
            try checkExecution(mutating: true)
            guard ExecutionGate.shared.perform({ _ = AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue) }) else { throw ComputerGatewayError.executionStopped("Stopped before focusing.") }
            // Attempt to directly set the value attribute via AX IPC (zero mouse/keyboard movement)
            var setError = AXError.cannotComplete
            guard ExecutionGate.shared.perform({ setError = AXUIElementSetAttributeValue(ax, kAXValueAttribute as CFString, text as CFTypeRef) }) else { throw ComputerGatewayError.executionStopped("Stopped before typing.") }
            if setError == .success {
                directSetSucceeded = true
                method = "accessibility_value"
            }
        }

        if !directSetSucceeded {
            // Fallback: focus field via zero-warp postDirectClick, then type key events
            if let rect = element.rect {
                let targetPoint = CGPoint(x: rect.midX, y: rect.midY)
                ComputerControl.postDirectClick(at: targetPoint)
                try? await Task.sleep(for: .milliseconds(40))
            }
            await ComputerControl.type(text) { _ in }
        }

        if submit {
            try await Task.sleep(for: .milliseconds(40))
            try checkExecution(mutating: true)
            _ = try ComputerControl.press("return")
        }

        snapshotStore.invalidate()
        return [
            "ok": true,
            "action": "type",
            "ref": ref,
            "characters": text.count,
            "submitted": submit,
            "method": method
        ]
    }

    private func executeKey(key: String, ref: String?, snapshotId: UInt64?) async throws -> [String: Any] {
        if let ref, let snapshotId {
            let element = try snapshotStore.resolve(ref: ref, snapshotId: snapshotId)
            try await validateElement(element)
            if let ax = element.axElement {
                try checkExecution(mutating: true)
            guard ExecutionGate.shared.perform({ _ = AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue) }) else { throw ComputerGatewayError.executionStopped("Stopped before focusing.") }
            } else if let rect = element.rect {
                ComputerControl.postDirectClick(at: CGPoint(x: rect.midX, y: rect.midY))
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        try checkExecution(mutating: true)
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "command", with: "cmd").replacingOccurrences(of: "control", with: "ctrl")
        guard !["cmd+shift+q", "cmd+option+shift+q", "ctrl+cmd+q", "cmd+option+escape", "cmd+option+esc"].contains(normalized) else { throw ComputerGatewayError.disabled("Logout, lock, and force quit shortcuts require user input.") }
        let formattedKey = try ComputerControl.press(key)
        snapshotStore.invalidate()
        return ["ok": true, "action": "key", "key": key, "label": formattedKey]
    }

    private func executeScroll(deltaY: Double) async throws -> [String: Any] {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let midPoint = CGPoint(x: screen.width / 2, y: screen.height / 2)
        await ComputerControl.postDirectScroll(dx: 0, dy: Int(deltaY), at: midPoint)
        snapshotStore.invalidate()
        return ["ok": true, "action": "scroll", "deltaY": deltaY]
    }

    private func executeNavigate(urlString: String) async throws -> [String: Any] {
        let result = ComputerControl.openURL(urlString)
        try? await Task.sleep(for: .milliseconds(900))
        snapshotStore.invalidate()
        let probe = await ScreenContext.probe()
        return [
            "ok": true,
            "url": probe.url ?? urlString,
            "title": probe.windowTitle ?? "",
            "status": result
        ]
    }
}
