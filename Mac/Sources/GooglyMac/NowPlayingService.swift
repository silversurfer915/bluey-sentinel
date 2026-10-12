import AppKit
import Foundation

/// Discovers active media playback from Apple Music and Spotify, and provides media controls.
@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()

    struct TrackInfo: Equatable {
        let title: String
        let artist: String
        let player: String
        let isPlaying: Bool
    }

    private(set) var currentTrack: TrackInfo?
    var onChange: ((TrackInfo?) -> Void)?

    private var pollTimer: Timer?
    private var isQuerying = false

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkNowPlaying() }
        }
        Task { @MainActor in await checkNowPlaying() }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentTrack = nil
        onChange?(nil)
    }

    /// Checks if Music or Spotify is playing in the background.
    func checkNowPlaying() async {
        guard !isQuerying else { return }
        isQuerying = true
        defer { isQuerying = false }

        let running = NSWorkspace.shared.runningApplications
        let musicApp = running.first { $0.bundleIdentifier == "com.apple.Music" }
        let spotifyApp = running.first { $0.bundleIdentifier == "com.spotify.client" }

        // Prefer the active/playing one
        var result: TrackInfo? = nil

        if let _ = spotifyApp {
            result = await querySpotify()
        }

        if result == nil, let _ = musicApp {
            result = await queryAppleMusic()
        }

        if result != currentTrack {
            self.currentTrack = result
            self.onChange?(result)
        }
    }

    /// Reads the current track whether it is playing or paused.
    ///
    /// The scripts used to return a value only `if player state is playing`, so pausing reported
    /// "no track at all" — which collapsed the island and lost the controls exactly when the user
    /// reached for the pause button. The state is returned alongside the track instead.
    private func querySpotify() async -> TrackInfo? {
        let script = """
        tell application "Spotify"
            set st to (player state as text)
            if st is "stopped" then return ""
            return (name of current track) & "|||" & (artist of current track) & "|||" & st
        end tell
        """
        return parseTrack(await runAppleScript(script), player: "Spotify")
    }

    private func queryAppleMusic() async -> TrackInfo? {
        let script = """
        tell application "Music"
            set st to (player state as text)
            if st is "stopped" then return ""
            return (name of current track) & "|||" & (artist of current track) & "|||" & st
        end tell
        """
        return parseTrack(await runAppleScript(script), player: "Apple Music")
    }

    /// Splits "title|||artist|||state" on the FIRST occurrences only, so a title that itself
    /// contains the delimiter can't shift the artist into the wrong field.
    private func parseTrack(_ output: String?, player: String) -> TrackInfo? {
        guard let output, !output.isEmpty else { return nil }
        let firstBreak = output.range(of: "|||")
        guard let firstBreak else { return nil }
        let title = String(output[output.startIndex..<firstBreak.lowerBound])
        let rest = String(output[firstBreak.upperBound...])
        let secondBreak = rest.range(of: "|||")
        let artist = secondBreak.map { String(rest[rest.startIndex..<$0.lowerBound]) } ?? rest
        let state = secondBreak.map { String(rest[$0.upperBound...]).lowercased() } ?? "playing"
        guard !title.isEmpty else { return nil }
        return TrackInfo(title: title, artist: artist, player: player, isPlaying: state == "playing")
    }

    // MARK: - Media Controls

    func togglePlayPause() {
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            Task { _ = await runAppleScript("tell application \"Spotify\" to playpause") }
        } else if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            Task { _ = await runAppleScript("tell application \"Music\" to playpause") }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await checkNowPlaying()
        }
    }

    func nextTrack() {
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            Task { _ = await runAppleScript("tell application \"Spotify\" to next track") }
        } else if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            Task { _ = await runAppleScript("tell application \"Music\" to next track") }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await checkNowPlaying()
        }
    }

    func previousTrack() {
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            Task { _ = await runAppleScript("tell application \"Spotify\" to previous track") }
        } else if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            Task { _ = await runAppleScript("tell application \"Music\" to previous track") }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await checkNowPlaying()
        }
    }

    private func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let script = NSAppleScript(source: source) else {
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
}
