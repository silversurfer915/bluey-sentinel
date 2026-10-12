import AppKit
import AVFoundation
import Speech

/// Opt-in smoke checks. No real UI actions, no credential output, and no user settings are changed.
@MainActor
enum IntegrationChecks {
    static func checkMicrophones() async {
        let store = MicrophoneStore.shared
        store.refresh()
        print("Input devices available: \(store.devices.count)")
        // Test the default and one alternative locally. No audio is saved or uploaded.
        let candidates = store.devices.sorted { ($0.name.contains("MacBook") ? 0 : 1) < ($1.name.contains("MacBook") ? 0 : 1) }
        for device in candidates.prefix(3) {
            do {
                let count = AudioFrameCounter()
                let capture = try MicrophoneCapture(uid: device.uid) { buffer in count.add(CMSampleBufferGetNumSamples(buffer)) }
                capture.start()
                try await Task.sleep(for: .seconds(1))
                capture.stop()
                print(count.value > 0 ? "PASS local microphone route \(device.name): \(count.value) frames" : "UNVERIFIED microphone route \(device.name): no frames")
            } catch { print("FAIL microphone route \(device.name): \(error.localizedDescription)") }
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition == true {
            let original = store.selectedUID
            let routes = candidates.filter { $0.name.contains("MacBook") || $0.name == "BoomAudio" }
            var errors = 0
            MacVoiceInput.shared.onError = { _ in errors += 1 }
            MacVoiceInput.shared.onCommandRecognized = { _ in }
            if let first = routes.first { store.select(first.uid) }
            MacVoiceInput.shared.startListening()
            try? await Task.sleep(for: .milliseconds(300))
            if routes.count > 1 { store.select(routes[1].uid) }
            try? await Task.sleep(for: .milliseconds(600))
            print(MacVoiceInput.shared.isListening && errors == 0 ? "PASS active speech session survives microphone switching" : "UNVERIFIED active speech session: startup or switch failed")
            MacVoiceInput.shared.stopListening(processCommand: false)
            store.select(original)
        } else { print("UNVERIFIED active speech switching: requires existing speech permission and on-device recognition") }

    }
    static func run() async {
        if ProcessInfo.processInfo.environment["BLUEY_MIC_CHECKS"] != nil {
            await checkMicrophones()
            exit(0)
        }
        let keys = AIConfig.configuredKeys
        for provider in [AIProvider.gemini, .tokenHarbor] {
            let config = ProviderConfiguration(preferred: provider, customEndpoint: "", customModel: "", customVision: false, allowFallback: false)
            guard let ai = AIConfig.candidates(configuration: config, keys: keys).first else { print("SKIP \(provider.title): no configured key"); continue }
            do {
                let tool: [String: Any] = ["type": "function", "function": ["name": "test_probe", "description": "Return the test number.", "parameters": ["type": "object", "properties": [:]]]]
                var messages: [[String: Any]] = [["role": "user", "content": "Call test_probe, then tell me its number."]]
                let body: [String: Any] = ["model": ai.model, "messages": messages, "tools": [tool], "tool_choice": ["type": "function", "function": ["name": "test_probe"]], "max_tokens": 1024]
                let first = try AIClient.message(await AIClient.send(body, ai: ai))
                guard let calls = first["tool_calls"] as? [[String: Any]], let call = calls.first, let id = call["id"] as? String else { throw BrainError.badShape("No tool call") }
                messages += [first, ["role": "tool", "tool_call_id": id, "content": "{\"number\":42}"]]
                let second = try AIClient.message(await AIClient.send(["model": ai.model, "messages": messages, "max_tokens": 1024], ai: ai))
                let reply = second["content"] as? String ?? ""
                print(reply.contains("42") ? "PASS \(provider.title): multi-turn tool round-trip" : "FAIL \(provider.title): incorrect tool result")
                if ai.supportsVision {
                    let image = NSImage(size: NSSize(width: 320, height: 120))
                    image.lockFocus()
                    NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 120)).fill()
                    ("SCREEN TEST 42" as NSString).draw(at: NSPoint(x: 15, y: 45), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.black])
                    image.unlockFocus()
                    let jpeg = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])!
                    let vision = try AIClient.message(await AIClient.send(["model": ai.model, "messages": [["role": "user", "content": [["type": "text", "text": "What number is visible in this test image?"], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]]]], "max_tokens": 256], ai: ai))
                    print((vision["content"] as? String ?? "").contains("42") ? "PASS \(provider.title): vision" : "FAIL \(provider.title): vision")
                }
            } catch { print("FAIL \(provider.title): \(error.localizedDescription)") }
        }
        do {
            let snapshot = try await ScreenReader.snapshot()
            print("PASS screen capture: \(Int(snapshot.size.width))×\(Int(snapshot.size.height)) points, \(snapshot.lines.count) OCR lines, \(snapshot.controls.count) controls")
        } catch { print("UNVERIFIED screen capture: \(error.localizedDescription)") }
        do {
            let sources = try await LiveWeb.search("wave optics interference physics")
            print("PASS live web: \(sources.count) retrieved source pages")
        } catch { print("UNVERIFIED live web: \(error.localizedDescription)") }
        exit(0)
    }
}

private final class AudioFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func add(_ count: Int) { lock.lock(); frames += count; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return frames }
}
