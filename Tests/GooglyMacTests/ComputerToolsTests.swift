//
//  ComputerToolsTests.swift
//  GooglyMacTests
//
//  Unit tests for the ported computer-access tool-call layer from CopilotKit/OpenDots and CopilotKit/openbot.
//

import XCTest
@testable import GooglyMac

final class ComputerToolsTests: XCTestCase {

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
}
