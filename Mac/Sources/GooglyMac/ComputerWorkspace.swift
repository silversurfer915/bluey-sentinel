//
//  ComputerWorkspace.swift
//  GooglyMac
//
//  Ported directly from:
//  - CopilotKit/openbot: agent-computer/src/workspace.ts (createWorkspace, resolvePath, list, read, write)
//  - CopilotKit/OpenDots: src/shared/computer-types.ts (files_list, files_read, files_write schemas)
//

import Foundation

// MARK: - Workspace Errors
// Upstream: openbot/agent-computer/src/workspace.ts (WorkspacePathError, WorkspaceFileError, etc.)

public class WorkspaceFileError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class WorkspacePathError: WorkspaceFileError {}
public final class WorkspaceFileNotFoundError: WorkspaceFileError {}
public final class WorkspaceFileTooLargeError: WorkspaceFileError {}

// MARK: - Workspace Types & Limits
// Upstream: openbot/agent-computer/src/workspace.ts (WorkspaceEntry, WorkspaceLimits, DEFAULT_WORKSPACE_LIMITS)

public struct WorkspaceEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String // "file" | "folder"
    public let bytes: Int?

    public init(path: String, kind: String, bytes: Int? = nil) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
    }
}

public struct WorkspaceLimits: Sendable {
    public let readBytes: Int       // 64,000 bytes
    public let writeBytes: Int      // 1,000,000 bytes
    public let listEntries: Int     // 500 entries
    public let downloadBytes: Int   // 100 * 1024 * 1024

    public static let `default` = WorkspaceLimits(
        readBytes: 64_000,
        writeBytes: 1_000_000,
        listEntries: 500,
        downloadBytes: 100 * 1024 * 1024
    )
}

public struct WorkspaceListResult: Codable, Sendable {
    public let path: String
    public let entries: [WorkspaceEntry]
    public let truncated: Bool
}

public struct WorkspaceReadResult: Codable, Sendable {
    public let path: String
    public let text: String
    public let truncated: Bool
    public let bytes: Int
}

public struct WorkspaceWriteResult: Codable, Sendable {
    public let path: String
    public let bytes: Int
    public let appended: Bool
}

// MARK: - Computer Workspace Implementation
// Upstream: openbot/agent-computer/src/workspace.ts (`createWorkspace`)

public final class ComputerWorkspace: @unchecked Sendable {
    public let rootPath: String
    public let limits: WorkspaceLimits

    private let fileManager = FileManager.default
    private static let maxLinkHops = 32 // Upstream: openbot MAX_LINK_HOPS = 32

    public init(rootPath: String? = nil, limits: WorkspaceLimits = .default) {
        if let rootPath {
            self.rootPath = rootPath
        } else {
            // [STACK ADAPTATION: Default macOS storage location for Bluey's bot workspace]
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Googly/workspace", isDirectory: true)
            self.rootPath = appSupport.path
        }
        self.limits = limits
        try? fileManager.createDirectory(atPath: self.rootPath, withIntermediateDirectories: true)
    }

    // MARK: - 3-Layer Path Confinement
    // Upstream: openbot/agent-computer/src/workspace.ts (`resolvePath`, `assertInside`, `writeDestination`)

    public func resolvePath(_ requested: String, forWrite: Bool) throws -> String {
        let wanted = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            throw WorkspacePathError("A file path is required.")
        }

        // Layer 1: Absolute paths refused outright
        if wanted.hasPrefix("/") || wanted.hasPrefix("~") {
            throw WorkspacePathError("Use a path relative to your workspace, not an absolute one.")
        }

        // Layer 2: Reject ".." traversal explicitly
        let components = wanted.components(separatedBy: "/")
        if components.contains("..") {
            throw WorkspacePathError("A file path may not contain '..'. You can only reach files inside your own workspace.")
        }

        let canonicalRoot = realPath(rootPath)
        let resolvedTarget = URL(fileURLWithPath: canonicalRoot).appendingPathComponent(wanted).standardized.path
        try assertInside(root: canonicalRoot, candidate: resolvedTarget, shown: wanted)

        // Layer 3: Symlink resolution and ancestor confinement
        let anchor = forWrite ? (resolvedTarget as NSString).deletingLastPathComponent : resolvedTarget
        let realAnchor: String
        if fileManager.fileExists(atPath: anchor) {
            realAnchor = realPath(anchor)
        } else {
            if !forWrite {
                throw WorkspaceFileNotFoundError("There is no file at \(wanted).")
            }
            realAnchor = try nearestExistingAncestor(root: canonicalRoot, target: anchor)
        }
        try assertInside(root: canonicalRoot, candidate: realAnchor, shown: wanted)

        if !forWrite {
            return realAnchor
        }

        // Write destination check (prevent symlink target escapes)
        let landing = try writeDestination(target: resolvedTarget, shown: wanted)
        if landing == resolvedTarget {
            return resolvedTarget
        }

        let holder = realPath((landing as NSString).deletingLastPathComponent)
        try assertInside(root: canonicalRoot, candidate: holder, shown: wanted)
        let finalResolved = URL(fileURLWithPath: holder).appendingPathComponent((landing as NSString).lastPathComponent).path
        try assertInside(root: canonicalRoot, candidate: finalResolved, shown: wanted)
        return finalResolved
    }

    private func assertInside(root: String, candidate: String, shown: String? = nil) throws {
        // [STACK ADAPTATION: Lexical containment matching upstream assertInside]
        let rootStandard = URL(fileURLWithPath: root).standardized.path
        let candidateStandard = URL(fileURLWithPath: candidate).standardized.path

        if candidateStandard == rootStandard {
            return
        }

        let prefix = rootStandard.hasSuffix("/") ? rootStandard : rootStandard + "/"
        if !candidateStandard.hasPrefix(prefix) {
            throw WorkspacePathError("\(shown ?? candidate) is outside your workspace, so it cannot be reached.")
        }
    }

    private func realPath(_ path: String) -> String {
        // [STACK ADAPTATION: POSIX realpath implementation to follow symlinks to disk reality]
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if Darwin.realpath(path, &resolved) != nil {
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func nearestExistingAncestor(root: String, target: String) throws -> String {
        var current = target
        while true {
            if fileManager.fileExists(atPath: current) {
                return realPath(current)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current {
                throw WorkspacePathError("The workspace directory is missing.")
            }
            try assertInside(root: root, candidate: parent)
            current = parent
        }
    }

    private func writeDestination(target: String, shown: String) throws -> String {
        var current = target
        for _ in 0...Self.maxLinkHops {
            var statBuf = stat()
            if lstat(current, &statBuf) != 0 {
                return current // File doesn't exist yet: normal write
            }
            let isSymlink = (statBuf.st_mode & S_IFMT) == S_IFLNK
            if !isSymlink {
                return current
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let count = Darwin.readlink(current, &buffer, Int(PATH_MAX) - 1)
            guard count > 0 else { return current }
            buffer[count] = 0
            let linkTarget = String(cString: buffer)
            if linkTarget.hasPrefix("/") {
                current = linkTarget
            } else {
                current = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent).appendingPathComponent(linkTarget).standardized.path
            }
        }
        throw WorkspacePathError("\(shown) is a chain of links that does not settle, so where a write would land cannot be established.")
    }

    // MARK: - File Operations
    // Upstream: openbot/agent-computer/src/workspace.ts (`list`, `read`, `write`)

    /// Lists files and directories in the workspace.
    public func list(_ requested: String = ".") throws -> WorkspaceListResult {
        let canonicalRoot = realPath(rootPath)
        let start = (requested == "." || requested.trimmingCharacters(in: .whitespaces).isEmpty)
            ? canonicalRoot
            : try resolvePath(requested, forWrite: false)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: start, isDirectory: &isDir) else {
            throw WorkspaceFileError("There is no folder at \(requested).")
        }
        guard isDir.boolValue else {
            throw WorkspaceFileError("\(requested) is a file, not a folder.")
        }

        var entries: [WorkspaceEntry] = []
        var truncated = false

        func walk(dir: String) {
            guard !truncated else { return }
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir) else { return }
            for item in contents.sorted() {
                if entries.count >= limits.listEntries {
                    truncated = true
                    return
                }
                let full = (dir as NSString).appendingPathComponent(item)
                var itemIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: full, isDirectory: &itemIsDir) else { continue }
                
                let relativePath: String
                if full.hasPrefix(canonicalRoot + "/") {
                    relativePath = String(full.dropFirst(canonicalRoot.count + 1))
                } else {
                    relativePath = item
                }

                if itemIsDir.boolValue {
                    entries.append(WorkspaceEntry(path: relativePath, kind: "folder"))
                    walk(dir: full)
                } else {
                    let attrs = try? fileManager.attributesOfItem(atPath: full)
                    let size = attrs?[.size] as? Int
                    entries.append(WorkspaceEntry(path: relativePath, kind: "file", bytes: size))
                }
            }
        }

        walk(dir: start)
        return WorkspaceListResult(path: requested, entries: entries, truncated: truncated)
    }

    /// Reads a UTF-8 text file from the workspace with bounded output.
    public func read(_ requested: String) throws -> WorkspaceReadResult {
        let full = try resolvePath(requested, forWrite: false)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: full, isDirectory: &isDir) else {
            throw WorkspaceFileNotFoundError("There is no file at \(requested).")
        }
        if isDir.boolValue {
            throw WorkspaceFileError("\(requested) is a directory, not a file.")
        }

        guard let handle = FileHandle(forReadingAtPath: full) else {
            throw WorkspaceFileError("The file at \(requested) could not be opened.")
        }
        defer { try? handle.close() }

        guard let data = try? handle.readToEnd() else {
            throw WorkspaceFileError("The file at \(requested) could not be read.")
        }

        let totalBytes = data.count
        let slice = data.prefix(limits.readBytes)
        let text = String(decoding: slice, as: UTF8.self)
        let truncated = totalBytes > slice.count

        return WorkspaceReadResult(
            path: requested,
            text: text,
            truncated: truncated,
            bytes: totalBytes
        )
    }

    /// Writes text to a file in the workspace, creating parent directories as needed.
    public func write(_ requested: String, contents: String, append: Bool = false) throws -> WorkspaceWriteResult {
        guard let data = contents.data(using: .utf8) else {
            throw WorkspaceFileError("The contents to write must be text.")
        }
        if data.count > limits.writeBytes {
            throw WorkspaceFileError("That is \(data.count) bytes and the limit is \(limits.writeBytes).")
        }

        let full = try resolvePath(requested, forWrite: true)
        let parentDir = (full as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        if append && fileManager.fileExists(atPath: full) {
            guard let handle = FileHandle(forWritingAtPath: full) else {
                throw WorkspaceFileError("The file could not be opened for appending.")
            }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: full), options: .atomic)
        }

        return WorkspaceWriteResult(
            path: requested,
            bytes: data.count,
            appended: append
        )
    }
}
