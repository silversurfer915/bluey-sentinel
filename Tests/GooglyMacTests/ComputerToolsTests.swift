//
//  ComputerToolsTests.swift
//  GooglyMacTests
//
//  Unit tests for the ported computer-access tool-call layer from CopilotKit/OpenDots and CopilotKit/openbot.
//

import XCTest
@testable import GooglyMac

final class ComputerToolsTests: XCTestCase {
    func testControlsReaderIncludesAllActiveDisplayCoordinateSpaces() {
        let bounds = ControlsReader.displayUnion([
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: -1920, y: 120, width: 1920, height: 1080),
        ], fallback: CGSize(width: 1512, height: 982))
        XCTAssertEqual(bounds, CGRect(x: -1920, y: 0, width: 3432, height: 1200))
    }

    // MARK: - 1. Tool Schemas Verification
    // Verifies contracts ported from OpenDots src/shared/computer-types.ts & openbot server/src/computer/schema.ts

    func testToolDeclarationsContainRequiredCopilotKitTools() {
        let tools = ComputerToolDefinitions.allTools
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let expected: Set<String> = [
            "computer_navigate",
            "computer_read",
            "computer_snapshot",
            "computer_screenshot",
            "computer_click",
            "computer_type",
            "computer_key",
            "computer_scroll",
            "computer_list_files",
            "computer_read_file",
            "computer_write_file",
            "computer_run_command",
            "computer_request_secret",
            "computer_request_help",
            "computer_open_app"
        ]

        for name in expected {
            XCTAssertTrue(names.contains(name), "Expected tool '\(name)' missing from declarations")
        }
    }

    func testClickAndTypeSchemasRequireRefAndSnapshotId() {
        let tools = ComputerToolDefinitions.allTools
        func findTool(_ name: String) -> [String: Any]? {
            tools.first { ($0["function"] as? [String: Any])?["name"] as? String == name }?["function"] as? [String: Any]
        }

        let click = findTool("computer_click")
        let clickParams = click?["parameters"] as? [String: Any]
        let clickRequired = clickParams?["required"] as? [String] ?? []
        XCTAssertTrue(clickRequired.contains("ref"), "computer_click must require 'ref'")
        XCTAssertTrue(clickRequired.contains("snapshotId"), "computer_click must require 'snapshotId'")

        let type = findTool("computer_type")
        let typeParams = type?["parameters"] as? [String: Any]
        let typeRequired = typeParams?["required"] as? [String] ?? []
        XCTAssertTrue(typeRequired.contains("ref"), "computer_type must require 'ref'")
        XCTAssertTrue(typeRequired.contains("snapshotId"), "computer_type must require 'snapshotId'")
        XCTAssertTrue(typeRequired.contains("text"), "computer_type must require 'text'")
    }

    // MARK: - 2. Workspace File Access & 3-Layer Confinement Tests
    // Verifies contracts ported from openbot agent-computer/src/workspace.ts

    func testWorkspaceRejectsAbsoluteAndTraversingPaths() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ws = ComputerWorkspace(rootPath: tempDir.path)

        // Layer 1: Rejection of absolute path
        XCTAssertThrowsError(try ws.resolvePath("/etc/passwd", forWrite: false)) { error in
            XCTAssertTrue(error is WorkspacePathError)
        }

        // Layer 2: Rejection of traversal
        XCTAssertThrowsError(try ws.resolvePath("../secret.txt", forWrite: false)) { error in
            XCTAssertTrue(error is WorkspacePathError)
        }
        XCTAssertThrowsError(try ws.resolvePath("docs/../../secret.txt", forWrite: false)) { error in
            XCTAssertTrue(error is WorkspacePathError)
        }
    }

    func testWorkspaceFileWriteReadAndListing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ws = ComputerWorkspace(rootPath: tempDir.path)

        // Write
        let writeResult = try ws.write("notes/test.txt", contents: "Hello from OpenBot computer tools!")
        XCTAssertEqual(writeResult.path, "notes/test.txt")
        XCTAssertEqual(writeResult.appended, false)
        XCTAssertGreaterThan(writeResult.bytes, 0)

        // Append
        let appendResult = try ws.write("notes/test.txt", contents: "\nAppended line", append: true)
        XCTAssertEqual(appendResult.appended, true)

        // Read
        let readResult = try ws.read("notes/test.txt")
        XCTAssertEqual(readResult.path, "notes/test.txt")
        XCTAssertTrue(readResult.text.contains("Hello from OpenBot"))
        XCTAssertTrue(readResult.text.contains("Appended line"))
        XCTAssertFalse(readResult.truncated)

        // List
        let listResult = try ws.list()
        let paths = listResult.entries.map { $0.path }
        XCTAssertTrue(paths.contains("notes"), "Directory 'notes' should be listed")
        XCTAssertTrue(paths.contains("notes/test.txt"), "File 'notes/test.txt' should be listed")
    }

    func testWorkspaceReadTruncationAtLimit() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let smallLimits = WorkspaceLimits(readBytes: 10, writeBytes: 1000, listEntries: 100, downloadBytes: 1000)
        let ws = ComputerWorkspace(rootPath: tempDir.path, limits: smallLimits)

        _ = try ws.write("large.txt", contents: "0123456789ABCDEF")
        let readResult = try ws.read("large.txt")
        XCTAssertEqual(readResult.text, "0123456789")
        XCTAssertTrue(readResult.truncated)
        XCTAssertEqual(readResult.bytes, 16)
    }

    // MARK: - 3. Shell Command Execution & Security Denylist Tests
    // Verifies contracts ported from openbot agent-computer/src/shell.ts

    func testShellEnvironmentSanitization() {
        let shell = ComputerShell(workspaceDir: "/tmp")
        let env = shell.buildEnvironment()

        XCTAssertNotNil(env["PATH"])
        XCTAssertEqual(env["HOME"], "/tmp")
        XCTAssertNil(env["BASH_ENV"], "BASH_ENV must be stripped from command environment")
        XCTAssertNil(env["LD_PRELOAD"], "LD_PRELOAD must be stripped")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"], "DYLD_INSERT_LIBRARIES must be stripped")
    }

    func testShellCommandExecutionOutputAndExitCode() async {
        let shell = ComputerShell(workspaceDir: "/tmp")
        let result = await shell.run(command: "echo 'openbot ported shell'")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("openbot ported shell"))
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.truncated)
    }

    func testShellTimeoutTermination() async {
        let shell = ComputerShell(workspaceDir: "/tmp")
        // Run a command that would sleep for 10 seconds, but set 1000ms timeout
        let result = await shell.run(command: "sleep 10", timeoutMs: 1000)

        XCTAssertTrue(result.timedOut, "Shell command should time out")
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - 4. Snapshot Store & Stale Snapshot Detection Tests
    // Verifies contracts ported from openbot server/src/computer/gateway.ts & agent-computer/src/index.ts

    func testSnapshotStoreMintsSequentialIdsAndResolvesRefs() throws {
        let store = ComputerSnapshotStore()
        let elements = [
            ComputerSnapshotElement(ref: "1", role: "button", name: "Submit", rect: CGRect(x: 10, y: 10, width: 50, height: 30)),
            ComputerSnapshotElement(ref: "2", role: "textbox", name: "Username", rect: CGRect(x: 10, y: 50, width: 100, height: 20))
        ]

        let snap1 = store.save(elements: elements, url: "https://example.com", title: "Example")
        XCTAssertGreaterThan(snap1.snapshotId, 0)

        // Valid resolve
        let resolved = try store.resolve(ref: "1", snapshotId: snap1.snapshotId)
        XCTAssertEqual(resolved.name, "Submit")
        XCTAssertEqual(resolved.role, "button")

        // Stale snapshotId must throw StaleSnapshot error
        XCTAssertThrowsError(try store.resolve(ref: "1", snapshotId: snap1.snapshotId - 1)) { error in
            guard let gatewayError = error as? ComputerGatewayError,
                  case .staleSnapshot = gatewayError else {
                XCTFail("Expected staleSnapshot error")
                return
            }
        }

        // Unknown ref must throw elementNotFound error
        XCTAssertThrowsError(try store.resolve(ref: "999", snapshotId: snap1.snapshotId)) { error in
            guard let gatewayError = error as? ComputerGatewayError,
                  case .elementNotFound = gatewayError else {
                XCTFail("Expected elementNotFound error")
                return
            }
        }
    }

    // MARK: - 5. Gateway Governance & Audit Logging Tests
    // Verifies contracts ported from OpenDots src/server/computer-service.ts & openbot server/src/computer/gateway.ts

    @MainActor
    func testGatewayPermissionGuardsAndAuditTrail() async throws {
        let gateway = ComputerGateway.shared

        // Disable files permission
        gateway.permissions.files = false
        do {
            _ = try await gateway.execute(name: "computer_list_files", arguments: [:])
            XCTFail("Expected permission disabled error")
        } catch {
            guard let gatewayError = error as? ComputerGatewayError,
                  case .disabled = gatewayError else {
                XCTFail("Expected disabled error")
                return
            }
        }

        // Re-enable files permission
        gateway.permissions.files = true
        let listResult = try await gateway.execute(name: "computer_list_files", arguments: [:])
        XCTAssertEqual(listResult["ok"] as? Bool, true)

        // Audit log must have recorded entries
        let lastAudit = gateway.auditLog.last
        XCTAssertNotNil(lastAudit)
        XCTAssertEqual(lastAudit?.action, "computer_list_files")
        XCTAssertEqual(lastAudit?.outcome, "succeeded")
    }

    // MARK: - 6. Snapshot-First & Zero-Mouse Integration Tests
    // Verifies Bluey's integration replaces turn-0 screenshots and legacy mouse moving

    @MainActor
    func testRealtimeHostToolsReplacesMouseNavigation() {
        let old = Settings.shared.computerControl
        defer { Settings.shared.computerControl = old }

        Settings.shared.computerControl = true
        let tools = RealtimeHost.tools
        let names = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })

        // Must contain OpenBot computer tools
        XCTAssertTrue(names.contains("computer_snapshot"))
        XCTAssertTrue(names.contains("computer_click"))
        XCTAssertTrue(names.contains("computer_type"))
        XCTAssertTrue(names.contains("computer_read"))
        XCTAssertTrue(names.contains("computer_navigate"))

        // Must NOT contain legacy mouse-moving / screenshotting action tools
        XCTAssertFalse(names.contains("click"), "Legacy mouse-warping 'click' tool should be replaced by 'computer_click'")
        XCTAssertFalse(names.contains("type_text"), "Legacy 'type_text' tool should be replaced by 'computer_type'")
        XCTAssertFalse(names.contains("press_keys"), "Legacy 'press_keys' tool should be replaced by 'computer_key'")
    }

    @MainActor
    func testRealtimeHostInstructionsIncludeSnapshotFirstGuidance() {
        let old = Settings.shared.computerControl
        defer { Settings.shared.computerControl = old }

        Settings.shared.computerControl = true
        let instructions = RealtimeHost.instructions

        XCTAssertTrue(instructions.contains("First call computer_snapshot"))
        XCTAssertTrue(instructions.contains("snapshotId"))
        XCTAssertTrue(instructions.contains("Do not navigate by taking screenshots and moving the mouse cursor"))
    }
    @MainActor
    func testGatewayHonorsComputerControlSetting() async {
        let old = Settings.shared.computerControl
        defer { Settings.shared.computerControl = old }
        Settings.shared.computerControl = false
        do {
            _ = try await ComputerGateway.shared.execute(name: "computer_request_secret", arguments: ["label": "Test", "ref": "1"])
            XCTFail("Disabled computer control must reject every gateway tool")
        } catch {}
    }

    @MainActor
    func testGatewayOffModeRejectsShellBeforeSpawn() async {
        let old = Settings.shared.autonomyMode
        defer { Settings.shared.autonomyMode = old }
        Settings.shared.autonomyMode = .off
        do {
            _ = try await ComputerGateway.shared.execute(name: "computer_run_command", arguments: ["command": "true"])
            XCTFail("Autonomy off must reject shell execution")
        } catch {}
    }

    @MainActor
    func testCancelledTaskCannotRequestSecret() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await ComputerGateway.shared.execute(name: "computer_request_secret", arguments: ["label": "Test", "ref": "1"])
                XCTFail("Cancelled task must not dispatch any tool")
            } catch {}
        }
        await task.value
    }

    @MainActor
    func testAskEveryDeclinePreventsShellDispatch() async throws {
        let oldControl = Settings.shared.computerControl
        let oldMode = Settings.shared.autonomyMode
        defer { Settings.shared.computerControl = oldControl; Settings.shared.autonomyMode = oldMode }
        Settings.shared.computerControl = true
        Settings.shared.autonomyMode = .askEvery
        let gateway = ComputerGateway()
        var approvalRequests = 0
        gateway.requestApproval = { _ in approvalRequests += 1; return false }
        do {
            _ = try await gateway.execute(name: "computer_run_command", arguments: ["command": "true"])
            XCTFail("Declined command must not execute")
        } catch {}
        XCTAssertEqual(approvalRequests, 1)
        XCTAssertTrue(gateway.auditLog.isEmpty)
    }

    @MainActor
    func testClickWithoutCapturedContextIsStale() async throws {
        let oldControl = Settings.shared.computerControl
        let oldMode = Settings.shared.autonomyMode
        defer { Settings.shared.computerControl = oldControl; Settings.shared.autonomyMode = oldMode }
        Settings.shared.computerControl = true
        Settings.shared.autonomyMode = .fullAccess
        let gateway = ComputerGateway()
        let snap = gateway.snapshotStore.save(elements: [ComputerSnapshotElement(ref: "1", role: "button", name: "Test")], url: "Test", title: "Test")
        do {
            _ = try await gateway.execute(name: "computer_click", arguments: ["ref": "1", "snapshotId": snap.snapshotId])
            XCTFail("Refs alone do not prove the active target")
        } catch ComputerGatewayError.staleSnapshot {} catch { XCTFail("Expected stale target refusal, got \(error)") }
    }

    func testShellDrainsStderrWhileWaitingForStdout() async {
        let result = await ComputerShell(workspaceDir: "/tmp").run(command: "printf '%131072s' x >&2; printf done", timeoutMs: 1000)
        XCTAssertFalse(result.timedOut, "A full stderr pipe must not deadlock stdout reading")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "done")
        XCTAssertTrue(result.truncated)
    }

    func testShellTaskCancellationTerminatesExecutionPromptly() async {
        let started = Date()
        let task = Task { await ComputerShell(workspaceDir: "/tmp").run(command: "sleep 3", timeoutMs: 5000) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    @MainActor
    func testAuditOutcomesStillCompleteAfterLogCapacity() async throws {
        let oldControl = Settings.shared.computerControl
        defer { Settings.shared.computerControl = oldControl }
        Settings.shared.computerControl = true
        let gateway = ComputerGateway()
        for _ in 0..<105 {
            _ = try await gateway.execute(name: "computer_request_secret", arguments: ["label": "Test", "ref": "1"])
        }
        XCTAssertEqual(gateway.auditLog.count, 100)
        XCTAssertTrue(gateway.auditLog.allSatisfy { $0.outcome == "succeeded" })
    }

    @MainActor
    func testSanctraStudyToolsExposeRealDataAndPlanning() {
        let names = Set(RealtimeHost.tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        XCTAssertTrue(names.contains("sanctra_study_context"))
        XCTAssertTrue(names.contains("sanctra_session_history"))
        XCTAssertTrue(names.contains("sanctra_plan_sessions"))
    }

}
