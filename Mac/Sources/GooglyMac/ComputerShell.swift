//
//  ComputerShell.swift
//  GooglyMac
//
//  Ported directly from:
//  - CopilotKit/openbot: agent-computer/src/shell.ts (createShell, environmentForCommand, clamp, timeout, process group)
//  - CopilotKit/OpenDots: src/shared/computer-types.ts (exec schema)
//

import Foundation

// MARK: - Shell Result Structure
// Upstream: openbot/agent-computer/src/shell.ts (`ShellResult`)

public struct ComputerShellResult: Codable, Sendable {
    public let command: String
    public let exitCode: Int
    public let stdout: String
    public let stderr: String
    public let truncated: Bool
    public let timedOut: Bool
    public let elapsedMs: Int

    public init(
        command: String,
        exitCode: Int,
        stdout: String,
        stderr: String,
        truncated: Bool,
        timedOut: Bool,
        elapsedMs: Int
    ) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.timedOut = timedOut
        self.elapsedMs = elapsedMs
    }
}

// MARK: - Computer Shell Implementation
// Upstream: openbot/agent-computer/src/shell.ts (`createShell`)

public final class ComputerShell: @unchecked Sendable {
    public static let defaultTimeoutMs: Double = 120_000 // 120s
    public static let minTimeoutMs: Double = 1_000       // 1s
    public static let maxTimeoutMs: Double = 600_000     // 10m
    public static let maxOutputBytes: Int = 64 * 1024    // 64 KB

    private let workspaceDir: String

    public init(workspaceDir: String) {
        self.workspaceDir = workspaceDir
    }

    // MARK: - Environment Sanitization
    // Upstream: openbot/agent-computer/src/shell.ts (`environmentForCommand`, `NEVER_PASSED`)

    private static let neverPassedVariables: Set<String> = [
        "BASH_ENV", "ENV", "BASH_XTRACEFD", "BASHOPTS", "SHELLOPTS",
        "CDPATH", "GLOBIGNORE", "IFS", "LD_PRELOAD", "LD_LIBRARY_PATH",
        "LD_AUDIT", "PS4", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH" // [STACK ADAPTATION: added macOS DYLD equivalents]
    ]

    private static let allowedPrefixes = ["LC_"]
    private static let allowedNames: Set<String> = [
        "PATH", "LANG", "LANGUAGE", "TERM", "TERMINFO", "COLORTERM",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "FTP_PROXY",
        "http_proxy", "https_proxy", "no_proxy", "all_proxy", "ftp_proxy"
    ]

    public func buildEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        let source = ProcessInfo.processInfo.environment

        for (key, value) in source {
            if Self.neverPassedVariables.contains(key) { continue }
            if Self.allowedNames.contains(key) || Self.allowedPrefixes.contains(where: { key.hasPrefix($0) }) {
                env[key] = sanitizeProxy(value)
            }
        }

        // Standard shell environment variables
        env["HOME"] = workspaceDir
        env["PWD"] = workspaceDir
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        }
        return env
    }

    private func sanitizeProxy(_ raw: String) -> String {
        // Upstream: strips userinfo from proxy strings to avoid leaking passwords in env
        guard let url = URL(string: raw), url.user != nil else { return raw }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        return components?.string ?? raw
    }

    // MARK: - Output Clamping
    // Upstream: openbot/agent-computer/src/shell.ts (`clamp`)

    private func clamp(_ text: String) -> (text: String, truncated: Bool) {
        guard let data = text.data(using: .utf8) else { return (text, false) }
        if data.count <= Self.maxOutputBytes {
            return (text, false)
        }
        // Retain the last 64KB (where compiler / command errors appear)
        let slice = data.suffix(Self.maxOutputBytes)
        let kept = String(decoding: slice, as: UTF8.self)
        return (kept, true)
    }

    // MARK: - Process Execution with Process Group & Timeout
    // Upstream: openbot/agent-computer/src/shell.ts (`run`)

    public func run(
        command: String,
        timeoutMs: Double? = nil,
        signal: DispatchWorkItem? = nil
    ) async -> ComputerShellResult {
        let started = Date()
        let requestedTimeout = timeoutMs ?? Self.defaultTimeoutMs
        let effectiveTimeout = min(max(requestedTimeout, Self.minTimeoutMs), Self.maxTimeoutMs)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceDir)
        process.environment = buildEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let execution = ShellExecution(process: process)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard try execution.launch() else {
                            continuation.resume(returning: ComputerShellResult(command: command, exitCode: -1, stdout: "", stderr: "Command cancelled before launch.", truncated: false, timedOut: false, elapsedMs: Int(Date().timeIntervalSince(started) * 1000)))
                            return
                        }
                    } catch {
                        continuation.resume(returning: ComputerShellResult(command: command, exitCode: -1, stdout: "", stderr: "Failed to spawn shell: \(error.localizedDescription)", truncated: false, timedOut: false, elapsedMs: Int(Date().timeIntervalSince(started) * 1000)))
                        return
                    }
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                    timer.schedule(deadline: .now() + effectiveTimeout / 1000)
                    timer.setEventHandler { execution.terminate(timedOut: true) }
                    timer.resume()
                    let stdout = ShellOutput()
                    let stderr = ShellOutput()
                    let readers = DispatchGroup()
                    for (pipe, output) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
                        readers.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { readers.leave() }
                            while true {
                                let data = pipe.fileHandleForReading.readData(ofLength: 8192)
                                if data.isEmpty { break }
                                output.append(data)
                            }
                        }
                    }
                    process.waitUntilExit()
                    timer.cancel()
                    readers.wait()
                    continuation.resume(returning: ComputerShellResult(command: command, exitCode: Int(process.terminationStatus), stdout: stdout.text, stderr: stderr.text, truncated: stdout.truncated || stderr.truncated, timedOut: execution.timedOut, elapsedMs: Int(Date().timeIntervalSince(started) * 1000)))
                }
            }
        }, onCancel: { execution.terminate(timedOut: false) })
    }
}

/// Serializes cancellation with spawn so cancelling before launch cannot leave an orphan command.
private final class ShellExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var didTimeOut = false
    init(process: Process) { self.process = process }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }
    func launch() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        try process.run()
        return true
    }
    func terminate(timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard process.isRunning else { return }
        didTimeOut = didTimeOut || timedOut
        let pid = process.processIdentifier
        // Foundation creates a child process group on macOS. Check before signalling it.
        if getpgid(pid) == pid { Darwin.kill(-pid, SIGKILL) }
        Darwin.kill(pid, SIGKILL)
    }
}

/// One reader owns each buffer; retain only the bounded output tail while draining the pipe.
private final class ShellOutput: @unchecked Sendable {
    private var data = Data()
    private(set) var truncated = false
    var text: String { String(decoding: data, as: UTF8.self) }
    func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > ComputerShell.maxOutputBytes {
            data = data.suffix(ComputerShell.maxOutputBytes)
            truncated = true
        }
    }
}
