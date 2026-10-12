import AppKit
import CoreGraphics
import Foundation

/// A cheap, exact description of what is in front of the user right now.
///
/// This is the Sentinel's eyes, and it deliberately avoids reading the screen when it doesn't have
/// to. The frontmost app, the window title, the exact browser URL and how long the user has been
/// idle are all free to read and are enough to catch most drift. A screenshot (and therefore a
/// vision-model call) is only taken when the cheap evidence can't settle the question.
struct FocusProbe {
    var app: String?
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var idleSeconds: Double
    var at: Date

    /// The domain, when the user is in a browser. This is what "block" rules match on.
    var domain: String? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the Sentinel shows the model and writes to the log. Small on purpose.
    var summary: String {
        var lines: [String] = []
        lines.append("App: \(app ?? "unknown")")
        if let windowTitle, !windowTitle.isEmpty { lines.append("Window: \(windowTitle)") }
        if let domain { lines.append("Site: \(domain)") }
        if let url, let domain, url.count > domain.count {
            // Keep a little path context (a video page reads very differently from a homepage)
            // without shipping a 400-character query string to the model.
            if let path = URL(string: url)?.path, path.count > 1, path != "/" {
                lines.append("Path: \(path.prefix(120))")
            }
        }
        lines.append("Idle: \(Int(idleSeconds))s")
        return lines.joined(separator: "\n")
    }
}

/// Reads the cheap facts. Never captures the screen — see `ScreenReader` for that.
enum ScreenContext {
    /// Apps whose contents we can read an exact URL from, and the AppleScript that does it.
    private static let browsers: [(name: String, script: String)] = [
        ("Google Chrome", "tell application \"Google Chrome\" to return URL of active tab of front window"),
        ("Google Chrome Canary", "tell application \"Google Chrome Canary\" to return URL of active tab of front window"),
        ("Brave Browser", "tell application \"Brave Browser\" to return URL of active tab of front window"),
        ("Microsoft Edge", "tell application \"Microsoft Edge\" to return URL of active tab of front window"),
        ("Arc", "tell application \"Arc\" to return URL of active tab of front window"),
        ("Vivaldi", "tell application \"Vivaldi\" to return URL of active tab of front window"),
        ("Chromium", "tell application \"Chromium\" to return URL of active tab of front window"),
        ("Safari", "tell application \"Safari\" to return URL of front document"),
        ("Safari Technology Preview", "tell application \"Safari Technology Preview\" to return URL of front document"),
    ]

    /// How long since the user last touched the mouse or keyboard.
    static var idleSeconds: Double {
        // ~0 is the "any event" mask CGEventSource understands.
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    /// One cheap reading. The AppleScript probe is the only slow part and it is skipped unless a
    /// browser is actually in front.
    static func probe() async -> FocusProbe {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName
        let bundle = front?.bundleIdentifier
        let title = frontWindowTitle(pid: front?.processIdentifier)

        var url: String?
        if let appName, browsers.contains(where: { $0.name == appName }) {
            url = await browserURL(app: appName)
        }

        return FocusProbe(app: appName, bundleID: bundle, windowTitle: title, url: url,
                          idleSeconds: idleSeconds, at: Date())
    }

    /// The frontmost window's title, read cheaply from Quartz. Falls back to nil without permission.
    private static func frontWindowTitle(pid: pid_t?) -> String? {
        guard let pid else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            // Layer 0 is normal app content; skip menubar, dock and floating helpers.
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// The frontmost window's frame, in the overlay's top-left origin coordinates.
    ///
    /// Quartz reports windows in a bottom-left origin space, so y is flipped against the main
    /// screen. This is only used to decide where the character points, never to click, which is
    /// why the app's own `look_at_screen` path (with its Accessibility-precise boxes) is untouched.
    static func frontWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let screen = NSScreen.screens.first else { return nil }
        let screenHeight = screen.frame.height

        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  owner == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width > 40, frame.height > 40 else { continue }
            return CGRect(x: frame.minX, y: screenHeight - frame.maxY,
                          width: frame.width, height: frame.height)
        }
        return nil
    }

    /// The exact URL of the front tab. Requires one-time Automation permission; failing that, nil.
    private static func browserURL(app: String) async -> String? {
        guard let entry = browsers.first(where: { $0.name == app }) else { return nil }
        return await withCheckedContinuation { continuation in
            // NSAppleScript is not thread-safe, so each probe gets its own instance on its own queue
            // rather than sharing one across the app.
            DispatchQueue.global(qos: .utility).async {
                guard let script = NSAppleScript(source: entry.script) else {
                    continuation.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result.stringValue)
            }
        }
    }

    /// Is this app one we can read a URL from and close a tab in?
    static func isBrowser(_ app: String?) -> Bool {
        guard let app else { return false }
        return browsers.contains { $0.name == app }
    }

    /// The frontmost app, but only when it is a browser we know how to drive.
    static func frontBrowser() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication?.localizedName, isBrowser(app) else { return nil }
        return app
    }

    /// Quit an app gracefully so it gets a chance to save. Only normal, running apps are touched.
    @discardableResult
    static func quit(app: String) -> String {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == app && $0.activationPolicy == .regular
        }) else {
            return "\(app) was not running"
        }
        running.terminate()
        return "quit \(app)"
    }

    /// Close the front tab in a browser. With a `domain`, only that site's tab is closed and the
    /// browser is asked to bring it up first; otherwise the front tab goes.
    ///
    /// Domains are validated by the caller, but the script is written so a hostile string could at
    /// worst fail to match a URL — it is interpolated only inside a comparison, never executed.
    @discardableResult
    static func closeTab(in browser: String, matching domain: String?) -> String {
        guard isBrowser(browser) else { return "\(browser) is not a browser I can close tabs in" }

        let isSafari = browser.contains("Safari")
        let tabProperty = isSafari ? "current tab" : "active tab"

        let script: String
        if let domain {
            if isSafari {
                script = """
                tell application "\(browser)"
                    repeat with w in windows
                        set tabList to tabs of w
                        repeat with t in tabList
                            if (URL of t) contains "\(domain)" then
                                close t
                                return "closed " & "\(domain)"
                            end if
                        end repeat
                    end repeat
                    return "no tab matching \(domain)"
                end tell
                """
            } else {
                script = """
                tell application "\(browser)"
                    repeat with w in windows
                        set tabList to tabs of w
                        repeat with i from 1 to count of tabList
                            set t to item i of tabList
                            if (URL of t) contains "\(domain)" then
                                close t
                                return "closed " & "\(domain)"
                            end if
                        end repeat
                    end repeat
                    return "no tab matching \(domain)"
                end tell
                """
            }
        } else {
            script = """
            tell application "\(browser)"
                if (count of windows) is 0 then return "no window open"
                close \(tabProperty) of front window
                return "closed the front tab"
            end tell
            """
        }
        return runAppleScript(script) ?? "asked \(browser) to close a tab"
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}