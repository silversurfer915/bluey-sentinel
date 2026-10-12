//
//  ComputerToolDefinitions.swift
//  GooglyMac
//
//  Ported from:
//  - CopilotKit/OpenDots: src/shared/computer-types.ts (computerInputs, computerPermissionsSchema)
//  - CopilotKit/openbot: server/src/computer/schema.ts (COMPUTER_TOOLS, action & result contracts)
//  - CopilotKit/openbot: server/src/computer/headless-tools.ts (tool descriptions & parameter schemas)
//  - CopilotKit/openbot: app/src/lib/copilot/computer-tools.tsx (tool definitions)
//

import Foundation

@preconcurrency import ApplicationServices

// MARK: - Upstream Data Structures

/// Represents an interactive element extracted from a page snapshot.
/// Upstream: openbot/server/src/computer/schema.ts (`SnapshotElement`)
public struct ComputerSnapshotElement: Codable, Equatable, Sendable {
    public let ref: String
    public let role: String
    public let name: String
    public let value: String?
    public let type: String?
    public let disabled: Bool?
    public let checked: Bool?
    
    // [STACK ADAPTATION: Screen rect stored in macOS points for native click/type targeting]
    public let rect: CGRect?

    // [STACK ADAPTATION: Direct AXUIElement handle for zero-mouse-movement accessibility actions]
    public var axElement: AXUIElement? = nil

    private enum CodingKeys: String, CodingKey {
        case ref, role, name, value, type, disabled, checked, rect
    }

    public init(
        ref: String,
        role: String,
        name: String,
        value: String? = nil,
        type: String? = nil,
        disabled: Bool? = nil,
        checked: Bool? = nil,
        rect: CGRect? = nil,
        axElement: AXUIElement? = nil
    ) {
        self.ref = ref
        self.role = role
        self.name = name
        self.value = value
        self.type = type
        self.disabled = disabled
        self.checked = checked
        self.rect = rect
        self.axElement = axElement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ref = try container.decode(String.self, forKey: .ref)
        self.role = try container.decode(String.self, forKey: .role)
        self.name = try container.decode(String.self, forKey: .name)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        self.checked = try container.decodeIfPresent(Bool.self, forKey: .checked)
        self.rect = try container.decodeIfPresent(CGRect.self, forKey: .rect)
        self.axElement = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(role, forKey: .role)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(disabled, forKey: .disabled)
        try container.encodeIfPresent(checked, forKey: .checked)
        try container.encodeIfPresent(rect, forKey: .rect)
    }
}

/// Result returned from `computer_snapshot`.
/// Upstream: openbot/server/src/computer/schema.ts (`SnapshotResult`)
public struct ComputerSnapshotResult: Codable, Sendable {
    public let snapshotId: UInt64
    public let url: String
    public let title: String
    public let elements: [ComputerSnapshotElement]
    public let truncated: Bool
    public let capturedAt: String

    public init(
        snapshotId: UInt64,
        url: String,
        title: String,
        elements: [ComputerSnapshotElement],
        truncated: Bool = false,
        capturedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.snapshotId = snapshotId
        self.url = url
        self.title = title
        self.elements = elements
        self.truncated = truncated
        self.capturedAt = capturedAt
    }
}

/// Result returned from `computer_screenshot`.
/// Upstream: openbot/server/src/computer/schema.ts (`ScreenshotResult`)
public struct ComputerScreenshotResult: Codable, Sendable {
    public let base64: String
    public let width: Double
    public let height: Double
    public let url: String
    public let capturedAt: String

    public init(
        base64: String,
        width: Double,
        height: Double,
        url: String,
        capturedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.base64 = base64
        self.width = width
        self.height = height
        self.url = url
        self.capturedAt = capturedAt
    }
}

/// Upstream: OpenDots/src/shared/computer-types.ts (`computerPermissionsSchema`)
public struct ComputerPermissions: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var browser: Bool
    public var files: Bool
    public var shell: Bool

    public init(enabled: Bool = true, browser: Bool = true, files: Bool = true, shell: Bool = true) {
        self.enabled = enabled
        self.browser = browser
        self.files = files
        self.shell = shell
    }
}

/// Upstream: OpenDots/src/shared/computer-types.ts (`ComputerAudit`)
public struct ComputerAuditEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let action: String
    public let actor: String // "agent" | "owner"
    public var outcome: String // "pending" | "succeeded" | "failed"
    public let createdAt: Int64
    public var detail: String?

    public init(id: String = UUID().uuidString, action: String, actor: String, outcome: String = "pending", createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000), detail: String? = nil) {
        self.id = id
        self.action = action
        self.actor = actor
        self.outcome = outcome
        self.createdAt = createdAt
        self.detail = detail
    }
}

// MARK: - Tool Definitions

/// Generates OpenAI-format tool declarations matching OpenDots & openbot exact schemas.
/// Upstream:
/// - OpenDots/src/server/computer-tools.ts (`computerTools`)
/// - openbot/server/src/computer/headless-tools.ts (`createHeadlessComputerTools`)
/// - openbot/app/src/lib/copilot/computer-tools.tsx
public enum ComputerToolDefinitions {
    
    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ]
            ]
        ]
    }

    /// All computer-control tools available to the AI agent.
    public static var allTools: [[String: Any]] {
        [
            // 1. Browser & Navigation
            tool(
                "computer_navigate",
                "Open a web page on your computer. Use this when asked to visit, open, look at or check a website. Returns the page title and its readable text. Answering should use what comes back.",
                ["url": ["type": "string", "description": "Full web address to open, including http:// or https://"]],
                required: ["url"]
            ),
            
            tool(
                "computer_read",
                "Read the page currently open on your computer without navigating anywhere. Use this after an action changes the page (such as submitting a form) to discover what it now displays."
            ),
            
            tool(
                "computer_snapshot",
                "List interactive elements on screen (fields, buttons, links, options), each with an accessibility ref, label and value. Call this BEFORE clicking or typing. Always send back the snapshotId it gives you. If an action reports that your refs are stale, take a fresh snapshot."
            ),
            
            tool(
                "computer_screenshot",
                "Capture an image of the current display. Returns base64 PNG data, dimensions, and current front window URL/context. Sensitive fields are masked."
            ),
            
            // 2. Mouse & Keyboard Interaction
            tool(
                "computer_click",
                "Click an interactive element on screen. Provide the element ref from your most recent snapshot and the snapshotId it came from.",
                [
                    "ref": ["type": "string", "description": "Ref of the element to click, from your most recent snapshot"],
                    "snapshotId": ["type": "integer", "description": "The snapshotId that ref came from"]
                ],
                required: ["ref", "snapshotId"]
            ),
            
            tool(
                "computer_type",
                "Enter text into an input field on screen. Provide the ref of the field from your most recent snapshot and its snapshotId. This replaces existing content in the field. Set submit to true to press Enter afterwards.",
                [
                    "ref": ["type": "string", "description": "Ref of the field from your most recent snapshot"],
                    "snapshotId": ["type": "integer", "description": "The snapshotId that ref came from"],
                    "text": ["type": "string", "description": "The text to enter"],
                    "submit": ["type": "boolean", "description": "Press Enter after typing to submit the form"]
                ],
                required: ["ref", "snapshotId", "text"]
            ),
            
            tool(
                "computer_key",
                "Press a key, such as Enter, Tab, Escape, or arrow keys. Give a ref and snapshotId to press it on a focused field, or omit ref to press it globally.",
                [
                    "key": ["type": "string", "description": "Key name, such as Enter, Tab, Escape, or shortcut combo like cmd+t"],
                    "ref": ["type": "string", "description": "Optional ref of the element to focus before pressing"],
                    "snapshotId": ["type": "integer", "description": "SnapshotId matching the ref"]
                ],
                required: ["key"]
            ),
            
            tool(
                "computer_scroll",
                "Scroll the active view vertically. Positive deltaY scrolls down; negative scrolls up. Defaults to 600.",
                [
                    "deltaY": ["type": "number", "description": "Pixels to scroll vertically (-10000 to 10000; positive is down). Default 600."]
                ]
            ),
            
            // 3. File System Access
            tool(
                "computer_list_files",
                "List what is in your persistent workspace: every file and folder saved, with sizes. Call this before reading a file whose exact name you are not sure of. Never guess a filename.",
                [
                    "path": ["type": "string", "description": "Optional subfolder relative to your workspace. Omit for root."]
                ]
            ),
            
            tool(
                "computer_read_file",
                "Read a text file from your persistent workspace. Paths are relative to your workspace (e.g., notes.md or data/output.json).",
                [
                    "path": ["type": "string", "description": "Relative path inside your workspace"]
                ],
                required: ["path"]
            ),
            
            tool(
                "computer_write_file",
                "Save a text file in your persistent workspace so you still have it later. Subdirectories are created automatically. Set append to true to add to an existing file.",
                [
                    "path": ["type": "string", "description": "Relative path inside your workspace, e.g. notes.txt"],
                    "contents": ["type": "string", "description": "The text content to write"],
                    "append": ["type": "boolean", "description": "Append to the file instead of overwriting"]
                ],
                required: ["path", "contents"]
            ),
            
            // 4. Shell Command Execution
            tool(
                "computer_run_command",
                "Run a bash shell command in your workspace. Pipes, redirects, and && work. Working directory is your workspace. Output is bounded to 64KB and commands exceeding the timeout are stopped.",
                [
                    "command": ["type": "string", "description": "Shell command line to execute"],
                    "timeoutMs": ["type": "integer", "description": "Timeout in milliseconds (1000 to 600000). Default 120000."]
                ],
                required: ["command"]
            ),
            
            // 5. Human-in-the-loop & Safety Tools
            tool(
                "computer_request_secret",
                "Ask the person to enter ONE secret directly (password, 2FA code, card number). Focus the field first with computer_click, then call this with the ref of that field and a label. The user enters it privately; you will never see the secret.",
                [
                    "label": ["type": "string", "description": "What you need, e.g. 'the one-time verification code'"],
                    "ref": ["type": "string", "description": "Ref of the target field from your latest snapshot"],
                    "snapshotId": ["type": "integer", "description": "SnapshotId matching the ref"]
                ],
                required: ["label", "ref", "snapshotId"]
            ),
            
            tool(
                "computer_request_help",
                "Ask the user to take control and perform an action you cannot: private sign-in, CAPTCHA, or hardware confirmation. Specify what you need done in one sentence.",
                [
                    "reason": ["type": "string", "description": "What you need the person to do, e.g. 'Please complete the Cloudflare verification.'"]
                ],
                required: ["reason"]
            ),

            // [STACK ADAPTATION: Native macOS application launcher matching Mac desktop workflow]
            tool(
                "computer_open_app",
                "Launch or switch to a native macOS application by name (e.g. 'Safari', 'Notes', 'Terminal').",
                [
                    "name": ["type": "string", "description": "Application name to open or activate"]
                ],
                required: ["name"]
            )
        ]
    }
}
