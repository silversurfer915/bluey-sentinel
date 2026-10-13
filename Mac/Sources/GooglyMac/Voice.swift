import AVFoundation
import AppKit
import Foundation

/// Bluey's voice: supports local Kokoro neural TTS model (100% offline, natural AI voice)
/// and Google Gemini neural speech synthesis (gemini-3.8-flash-lite-tts), with system fallback.
@MainActor
final class Voice: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = Voice()

    private var audioPlayer: AVAudioPlayer?
    private var macProcess: Process?
    private var serverProcess: Process?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var synthesisTask: Task<Void, Never>?
    private var speechGeneration = UUID()
    private var meterTimer: Timer?
    private var isSpeakingActive: Bool = false

    /// Real-time speech audio level, 0.0 (silent) … 1.0 (peak loudness).
    public private(set) var currentLevel: Double = 0.0

    /// Callbacks for speech lifecycle and audio levels.
    public var onLevelChanged: ((Double) -> Void)?
    public var onSpeechStarted: (() -> Void)?
    public var onSpeechFinished: (() -> Void)?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Check if Kokoro is installed locally
    static var isKokoroAvailable: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let py = home.appendingPathComponent(".kokoro_env/bin/python3").path
        let model = home.appendingPathComponent(".kokoro/kokoro-v1.0.onnx").path
        let userModel = home.appendingPathComponent("kokoro-v1.0.onnx").path
        // The voices file is required too; without it Kokoro fails and silently falls back.
        let voices = home.appendingPathComponent(".kokoro/voices-v1.0.bin").path
        let userVoices = home.appendingPathComponent("voices-v1.0.bin").path
        let hasPy = FileManager.default.fileExists(atPath: py)
        let hasModel = FileManager.default.fileExists(atPath: model) || FileManager.default.fileExists(atPath: userModel)
        let hasVoices = FileManager.default.fileExists(atPath: voices) || FileManager.default.fileExists(atPath: userVoices)
        return hasPy && hasModel && hasVoices
    }

    /// Installed Apple voices, resolved live so the picker only offers real options.
    static var appleVoices: [(id: String, name: String)] {
        let installed = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { (id: "system:" + $0.name.lowercased(), name: "Apple: \($0.name) (\($0.language))") }
        return installed.isEmpty
            ? [("system:daniel", "Apple: Daniel (British Male)"),
               ("system:samantha", "Apple: Samantha (US)")]
            : installed
    }

    /// Local Kokoro voices
    static let kokoroVoices: [(id: String, name: String)] = [
        ("kokoro:bm_george", "Kokoro: George (British Male - Expressive & Natural) [Local AI]"),
        ("kokoro:bm_fable", "Kokoro: Fable (British Male - Witty & British) [Local AI]"),
        ("kokoro:bf_emma", "Kokoro: Emma (British Female - Crisp & Clear) [Local AI]"),
        ("kokoro:af_heart", "Kokoro: Heart (Warm AI - Studio Quality) [Local AI]"),
        ("kokoro:am_puck", "Kokoro: Puck (Natural AI) [Local AI]")
    ]

    /// Natural prebuilt voices available in Gemini TTS
    static let geminiVoices: [(id: String, name: String)] = [
        ("gemini:Puck", "Gemini: Puck (Natural British - Witty & Expressive) [Cloud]"),
        ("gemini:Kore", "Gemini: Kore (Warm, Friendly, Clear) [Cloud]"),
        ("gemini:Charon", "Gemini: Charon (Calm & Deeper) [Cloud]"),
        ("gemini:Fenrir", "Gemini: Fenrir (Energetic) [Cloud]"),
        ("gemini:Aoede", "Gemini: Aoede (Melodic & Thoughtful) [Cloud]")
    ]

    /// Legacy choices helper for menu compatibility
    struct Choice {
        let name: String
        let identifier: String
        let quality: Int
    }

    static func availableVoices() -> [Choice] {
        var list: [Choice] = []
        list.append(contentsOf: appleVoices.map { Choice(name: $0.name, identifier: $0.id, quality: 3) })
        if isKokoroAvailable {
            list.append(contentsOf: kokoroVoices.map { Choice(name: $0.name, identifier: $0.id, quality: 3) })
        }
        list.append(contentsOf: geminiVoices.map { Choice(name: $0.name, identifier: $0.id, quality: 3) })
        return list
    }

    /// Say one short line. Speaks with selected Kokoro local voice, Gemini Neural TTS, or instant Apple voice.
    func say(_ text: String, rate: Float = 1.0) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, Settings.shared.voiceEnabled, !ExecutionGate.shared.isStopped else { return }

        stop()

        let pick = Settings.shared.voiceIdentifier ?? "system:daniel"

        // 1. Instant Apple native voice (0ms latency)
        if pick.hasPrefix("system:") {
            let voiceId = String(pick.dropFirst("system:".count))
            speakWithAppleSpeech(line, voiceName: voiceId)
            return
        }

        // 2. If Kokoro voice is picked
        if pick.hasPrefix("kokoro:") {
            let rawVoice = String(pick.dropFirst("kokoro:".count))
            synthesizeAndPlay(
                synthesis: { try await self.synthesizeKokoro(line, voice: rawVoice) },
                playback: { try self.play($0) },
                fallback: { self.speakWithAppleSpeech(line, voiceName: "daniel") }
            )
            return
        }

        // 3. If Gemini voice is picked
        if pick.hasPrefix("gemini:") || pick == "Puck" {
            let rawVoice = pick.hasPrefix("gemini:") ? String(pick.dropFirst("gemini:".count)) : pick
            if let key = AIConfig.geminiKey, !key.isEmpty {
                synthesizeAndPlay(
                    synthesis: { try await self.synthesizeGemini(line, key: key, voiceName: rawVoice) },
                    playback: { try self.play($0) },
                    fallback: { self.speakWithAppleSpeech(line, voiceName: "daniel") }
                )
                return
            }
        }

        // Fallback: Instant Apple voice
        speakWithAppleSpeech(line, voiceName: "daniel")
    }

    /// Shared asynchronous speech pipeline. Playback is supplied by the audio backend.
    func synthesizeAndPlay(synthesis: @escaping () async throws -> Data,
                           playback: @escaping (Data) throws -> Void,
                           fallback: @escaping () -> Void) {
        synthesisTask?.cancel()
        let generation = UUID()
        speechGeneration = generation
        synthesisTask = Task { @MainActor in
            defer { if speechGeneration == generation { synthesisTask = nil } }
            do {
                try Task.checkCancellation()
                let audio = try await synthesis()
                try Task.checkCancellation()
                guard speechGeneration == generation, !ExecutionGate.shared.isStopped else { return }
                try playback(audio)
            } catch {
                guard !Task.isCancelled, speechGeneration == generation, !ExecutionGate.shared.isStopped else { return }
                fallback()
            }
        }
    }

    // MARK: - Native Apple Instant Speech (0ms Latency)

    private func speakWithAppleSpeech(_ text: String, voiceName: String = "daniel") {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // Honor the selected voice by name/identifier, not just by language.
        let requested = voiceName.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let match = voices.first { $0.name.lowercased() == requested }
            ?? voices.first { $0.identifier.lowercased().hasSuffix("." + requested) }
            ?? voices.first { $0.identifier.lowercased().contains(requested) }
        if let match {
            utterance.voice = match
        } else {
            let lang = requested == "samantha" ? "en-US" : "en-GB"
            if let voice = AVSpeechSynthesisVoice(language: lang) {
                utterance.voice = voice
            }
        }
        activeUtterance = utterance
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
        startMetering()
    }

    // MARK: - Kokoro Local Neural TTS

    private func synthesizeKokoro(_ text: String, voice: String) async throws -> Data {
        let rawVoice = voice.isEmpty ? "bm_george" : voice

        // Check if the warm server is running on 127.0.0.1:8765. Built with URLComponents rather
        // than string interpolation: `.urlQueryAllowed` still permits "&" and "=", so a nudge
        // containing either would have truncated the text and could even override the voice.
        if var components = URLComponents(string: "http://127.0.0.1:8765/synthesize") {
            components.queryItems = [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "voice", value: rawVoice),
            ]
            if let srvUrl = components.url {
                var req = URLRequest(url: srvUrl)
                req.timeoutInterval = 3.0
                if let (data, resp) = try? await URLSession.shared.data(for: req) {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200, !data.isEmpty { return data }
                    NSLog("[Voice] Kokoro server returned \(code): \(String(decoding: data.prefix(200), as: UTF8.self))")
                }
            }
        }

        // Server not running yet: launch it for next time, and synthesize this line via the CLI.
        try Task.checkCancellation()
        startKokoroServerIfNeeded()

        // The CLI is run OFF the main thread. It used to call `waitUntilExit()` inside a
        // `Task { @MainActor }`, which froze the entire app — menus, notch, the Sentinel's own
        // countdown — for the seconds synthesis takes, with no timeout if Python hung.
        let wavData = try await Self.synthesizeWithKokoroCLI(text: text, voice: rawVoice)
        return wavData
    }

    /// Runs the Kokoro CLI on a background queue with a hard deadline, so a hung Python process can
    /// never wedge the app.
    private static func synthesizeWithKokoroCLI(text: String, voice: String) async throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let py = home.appendingPathComponent(".kokoro_env/bin/python3").path
        let script = home.appendingPathComponent(".kokoro/kokoro_tts.py").path
        // Per-user temp dir rather than world-writable /tmp with a guessable name.
        let outWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro_speech_\(UUID().uuidString).wav")

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: py)
                proc.arguments = [script, "--text", text, "--voice", voice, "--out", outWav.path]
                proc.standardOutput = FileHandle.nullDevice
                let errPipe = Pipe()
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Wait with a deadline instead of blocking forever.
                let deadline = Date().addingTimeInterval(12)
                while proc.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    proc.terminate()
                    continuation.resume(throwing: NSError(
                        domain: "Voice", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Kokoro synthesis timed out"]))
                    return
                }

                guard proc.terminationStatus == 0,
                      let wav = try? Data(contentsOf: outWav), !wav.isEmpty else {
                    let detail = String(decoding: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
                    NSLog("[Voice] Kokoro CLI failed (status \(proc.terminationStatus), voice \(voice)): \(detail.prefix(300))")
                    continuation.resume(throwing: NSError(
                        domain: "Voice", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Kokoro CLI synthesis failed"]))
                    return
                }
                try? FileManager.default.removeItem(at: outWav)
                continuation.resume(returning: wav)
            }
        }
    }

    private func play(_ wavData: Data) throws {
        let player = try AVAudioPlayer(data: wavData)
        player.delegate = self
        player.volume = 1.0
        player.isMeteringEnabled = true
        player.prepareToPlay()
        player.play()
        self.audioPlayer = player
        startMetering()
    }

    private func startKokoroServerIfNeeded() {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let py = home.appendingPathComponent(".kokoro_env/bin/python3").path
        let script = home.appendingPathComponent(".kokoro/kokoro_tts.py").path
        guard FileManager.default.fileExists(atPath: py), FileManager.default.fileExists(atPath: script) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = [script, "--server", "--port", "8765"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // Only record it once it actually launched, so a failed start doesn't leave a dead
            // Process recorded as our server.
            self.serverProcess = proc
        } catch {
            NSLog("[Voice] Kokoro server failed to start: \(error.localizedDescription)")
            self.serverProcess = nil
        }
    }

    // MARK: - Gemini Neural TTS

    private func synthesizeGemini(_ text: String, key: String, voiceName: String = "Puck") async throws -> Data {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash-lite-tts:generateContent?key=\(key)") else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid TTS endpoint"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "contents": [
                ["parts": [["text": text]]]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voiceName
                        ]
                    ]
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let inlineData = parts.first?["inlineData"] as? [String: Any],
              let b64Audio = inlineData["data"] as? String,
              let wavData = Data(base64Encoded: b64Audio) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "TTS \(code): \(detail)"])
        }

        return wavData
    }

    private func speakLocally(_ text: String) {
        macProcess?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Use Daniel (British voice) if available, else system default
        process.arguments = ["-v", "Daniel", text]
        try? process.run()
        self.macProcess = process
    }

    /// Short pop sound for warning alerts.
    ///
    /// Deliberately NOT gated on `voiceEnabled`: the audio cue is a safety alert, and someone who
    /// muted Bluey's voice still needs to be told they have drifted. Falls back to the system beep
    /// when the named sound is unavailable.
    func chirp() {
        if let pop = NSSound(named: "Pop") {
            pop.play()
        } else {
            NSSound.beep()
        }
    }

    func stop() {
        speechGeneration = UUID()
        synthesisTask?.cancel()
        synthesisTask = nil
        // Stop the native synthesizer too. It was previously left speaking, so a Kokoro or Gemini
        // line would play over the top of an Apple utterance — and the mic path, which calls stop()
        // so Bluey doesn't talk over the user, could never actually silence him.
        activeUtterance = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        macProcess?.terminate()
        macProcess = nil
        handleSpeechFinished()
    }

    /// Tears down the long-lived Kokoro server process. Called on app quit so relaunching doesn't
    /// leave the old server holding port 8765 and serving a stale model.
    func shutdown() {
        stop()
        if let serverProcess, serverProcess.isRunning { serverProcess.terminate() }
        serverProcess = nil
    }

    // MARK: - Speech Audio Level Metering & Lifecycle

    private func startMetering() {
        isSpeakingActive = true
        meterTimer?.invalidate()
        onSpeechStarted?()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMeters()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.meterTimer = timer
    }

    private func updateMeters() {
        guard isSpeakingActive else {
            stopMetering()
            return
        }

        if let player = audioPlayer, player.isPlaying {
            player.updateMeters()
            let p0 = player.averagePower(forChannel: 0)
            let p1 = player.numberOfChannels > 1 ? player.averagePower(forChannel: 1) : p0
            let power = max(p0, p1)
            let clamped = max(-50.0, min(-5.0, power))
            let linear = (clamped + 50.0) / 45.0
            currentLevel = currentLevel * 0.25 + Double(linear) * 0.75
            onLevelChanged?(currentLevel)
        } else if speechSynthesizer.isSpeaking || activeUtterance != nil {
            let t = CACurrentMediaTime()
            let cadence = 0.5 + 0.35 * sin(t * 19.0) * cos(t * 7.3) + 0.15 * sin(t * 31.0)
            currentLevel = max(0.12, min(0.95, cadence))
            onLevelChanged?(currentLevel)
        } else {
            handleSpeechFinished()
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func handleSpeechFinished() {
        guard isSpeakingActive else { return }
        isSpeakingActive = false
        stopMetering()
        activeUtterance = nil
        currentLevel = 0.0
        onLevelChanged?(0.0)
        onSpeechFinished?()
    }

    // MARK: - Delegates

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.audioPlayer === player {
                self.audioPlayer = nil
            }
            self.handleSpeechFinished()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.activeUtterance === utterance {
                self.activeUtterance = nil
            }
            self.handleSpeechFinished()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.activeUtterance === utterance {
                self.activeUtterance = nil
            }
            self.handleSpeechFinished()
        }
    }
}