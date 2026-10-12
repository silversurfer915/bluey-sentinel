import XCTest
@testable import GooglyMac

final class VoiceLifecycleTests: XCTestCase {
    @MainActor
    func testStopPreventsDelayedSynthesisPlayback() async {
        let voice = Voice()
        var generated: CheckedContinuation<Data, Never>?
        var played = false
        voice.synthesizeAndPlay(synthesis: {
            await withCheckedContinuation { generated = $0 }
        }, playback: { _ in played = true }, fallback: {})
        while generated == nil { await Task.yield() }
        voice.stop()
        generated?.resume(returning: Data([1]))
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(played, "Stopped synthesis must never start playback")
    }

    @MainActor
    func testStopPreventsCancelledSynthesisFallback() async {
        let voice = Voice()
        var generated: CheckedContinuation<Data, Error>?
        var fellBack = false
        voice.synthesizeAndPlay(synthesis: {
            try await withCheckedThrowingContinuation { generated = $0 }
        }, playback: { _ in }, fallback: { fellBack = true })
        while generated == nil { await Task.yield() }
        voice.stop()
        generated?.resume(throwing: CancellationError())
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(fellBack, "Cancellation must not start native fallback speech")
    }
}
