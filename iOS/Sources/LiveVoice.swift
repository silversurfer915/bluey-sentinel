import AVFoundation
import Foundation
import Speech

/// A live voice session for Bluey using native Apple Speech Recognition (free, on-device STT)
/// on the phone and DeepSeek intelligence on the Mac.
///
/// Once he's awake the mic stays on to build background meeting context (saved in 5-min chunks).
/// When you press and hold his face, Apple Speech transcribes your question in real-time.
/// Letting go sends the text question to the Mac where DeepSeek inspects the screen and replies.
/// The reply arrives as a speech bubble on the Mac alongside a cheerful chirp and animated expression on the phone.
final class LiveVoice: NSObject, ObservableObject {
    enum State: Equatable { case asleep, waking, listening, asking, thinking, speaking }

    @Published private(set) var state: State = .asleep

    /// Sends a question to the Mac running DeepSeek. Calls back with reply text.
    var sendQuestion: ((String, @escaping (String?) -> Void) -> Void)?

    /// Compatibility stubs for legacy connections
    var requestToken: ((@escaping (String?) -> Void) -> Void)?
    var runTool: ((String, String, @escaping (String, String?) -> Void) -> Void)?

    /// What he's saying, as it streams in or completes. `done` is true when the reply finished.
    var onCaption: ((String, _ done: Bool) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// For the saved transcript: a session started or ended, something you said, his replies.
    var onSessionStart: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onUserTurn: ((_ itemID: String, _ asked: Bool) -> Void)?
    var onUserWords: ((_ itemID: String, _ text: String, _ asked: Bool) -> Void)?
    var onReply: ((String) -> Void)?
    var onReport: ((String) -> Void)?
    /// Recent transcript for context in long sessions.
    var resumeContext: (() -> String?)?

    /// Records the whole session's audio in five-minute AAC chunks for meeting notes.
    let recorder = ChunkRecorder()

    /// Loudness of his chirp right now, 0…1.
    private(set) var level: Double = 0

    var volume: Double {
        get { UserDefaults.standard.object(forKey: "volume") as? Double ?? 1 }
        set {
            UserDefaults.standard.set(newValue, forKey: "volume")
            player.volume = Float(newValue)
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var audioReady = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var wantAwake = false
    private var holding = false
    private var askWhenReady = false
    private var currentTranscript = ""
    private var currentTurnID = UUID().uuidString
    private var submittedTurnID: String?
    private var recognitionGeneration = UUID()
    private var sessionGeneration = UUID()
    private var pendingBuffers = 0

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }

    // MARK: Wake and sleep

    func toggle() {
        state == .asleep ? wake() : sleep()
    }

    func wake() {
        guard state == .asleep else { return }
        wantAwake = true
        sessionGeneration = UUID()
        setState(.waking)

        AVAudioApplication.requestRecordPermission { [weak self] micGranted in
            guard let self else { return }
            guard micGranted else {
                DispatchQueue.main.async {
                    self.onCaption?("I need the microphone. Turn it on for Bluey in iPhone Settings.", true)
                    self.wantAwake = false
                    self.setState(.asleep)
                }
                return
            }

            SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
                DispatchQueue.main.async {
                    guard let self, self.wantAwake else { return }
                    guard authStatus == .authorized else {
                        self.onCaption?("I need Speech Recognition permission. Turn it on for Bluey in iPhone Settings.", true)
                        self.wantAwake = false
                        self.setState(.asleep)
                        return
                    }

                    do {
                        try self.startAudio()
                        self.onSessionStart?()
                        self.chirp(syllables: 2)
                        if self.askWhenReady {
                            self.askWhenReady = false
                            self.beginAsk()
                        } else {
                            self.setState(.listening)
                        }
                    } catch {
                        self.onCaption?("I couldn't start audio: \(error.localizedDescription)", true)
                        self.sleep()
                    }
                }
            }
        }
    }

    func sleep() {
        let wasRunning = wantAwake
        wantAwake = false
        sessionGeneration = UUID()
        recorder.finish()
        if wasRunning { onSessionEnd?() }

        stopRecognition()
        stopAudio()

        holding = false
        askWhenReady = false
        replyTimeoutWorkItem?.cancel()
        replyTimeoutWorkItem = nil
        level = 0
        setState(.asleep)
    }

    /// Says a quick hi (for checking the chirp volume).
    func sayHi() {
        chirp(syllables: 3)
        onCaption?("Hi! I'm Bluey.", true)
    }

    // MARK: Hold to ask

    func beginAsk() {
        holding = true
        onCaption?("", false)
        if state == .asleep {
            askWhenReady = true
            wake()
            return
        }
        guard state == .listening || state == .speaking || state == .waking else { return }
        setState(.asking)
        startRecognition()
    }

    func endAsk() {
        guard holding else { return }
        holding = false

        guard state == .asking else {
            if askWhenReady { askWhenReady = false }
            return
        }

        // End audio input to speech recognizer
        recognitionRequest?.endAudio()
        setState(.thinking)

        // Adaptive timeout: if transcript is already partially ready, give 0.4s for trailing tokens;
        // if still awaiting first tokens, give Apple's recognizer up to 1.0s to deliver results.
        let delay: Double = currentTranscript.isEmpty ? 1.0 : 0.4
        let turnID = currentTurnID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .thinking, self.currentTurnID == turnID else { return }
            self.finishAndSend()
        }
    }

    private func startRecognition() {
        stopRecognition()
        currentTranscript = ""
        currentTurnID = UUID().uuidString

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let generation = UUID()
        recognitionGeneration = generation
        let turnID = currentTurnID
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.wantAwake, self.recognitionGeneration == generation,
                      self.currentTurnID == turnID, self.submittedTurnID != turnID else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.currentTranscript = text
                    self.onUserWords?(turnID, text, true)
                    if result.isFinal && self.state == .thinking { self.finishAndSend() }
                }
                if error != nil && self.state == .thinking { self.finishAndSend() }
            }
        }
    }

    private func stopRecognition() {
        recognitionGeneration = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func finishAndSend() {
        guard wantAwake, state == .thinking, submittedTurnID != currentTurnID else { return }
        submittedTurnID = currentTurnID
        let question = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRecognition()

        guard !question.isEmpty else {
            // Nothing heard; go back to listening
            setState(holding ? .asking : .listening)
            return
        }

        onUserTurn?(currentTurnID, true)
        onUserWords?(currentTurnID, question, true)

        guard let sendQuestion else {
            onCaption?("The Mac isn't connected.", true)
            setState(.listening)
            return
        }

        let sessionID = sessionGeneration
        let turnID = currentTurnID
        sendQuestion(question) { [weak self] replyText in
            DispatchQueue.main.async {
                guard let self, self.wantAwake, self.sessionGeneration == sessionID, self.currentTurnID == turnID else { return }
                if let text = replyText, !text.isEmpty {
                    self.receiveReply(text)
                } else {
                    self.setState(self.holding ? .asking : .listening)
                }
            }
        }
    }

    private var replyTimeoutWorkItem: DispatchWorkItem?

    /// Immediately ends replying state without waiting for arbitrary synthetic timeouts.
    func finishReply() {
        replyTimeoutWorkItem?.cancel()
        replyTimeoutWorkItem = nil
        guard state == .speaking else { return }
        setState(holding ? .asking : .listening)
    }

    /// Called when a reply arrives from the Mac.
    func receiveReply(_ text: String) {
        guard wantAwake else { return }
        replyTimeoutWorkItem?.cancel()
        setState(.speaking)
        chirp(syllables: min(max(text.split(separator: " ").count, 3), 5))
        onCaption?(text, true)
        onReply?(text)

        // Safety fallback ceiling in case network packets drop or Mac terminates
        let words = Double(text.split(separator: " ").count)
        let safetyTimeout = min(max(4.0, 2.0 + words * 0.4), 15.0)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .speaking else { return }
            self.finishReply()
        }
        replyTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + safetyTimeout, execute: work)
    }

    func receiveCaption(_ text: String, done: Bool) {
        guard wantAwake else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        replyTimeoutWorkItem?.cancel()
        setState(.speaking)
        onCaption?(trimmed, done)
        if done {
            onReply?(trimmed)
            chirp(syllables: min(max(trimmed.split(separator: " ").count, 3), 5))
            let words = Double(trimmed.split(separator: " ").count)
            let safetyTimeout = min(max(4.0, 2.0 + words * 0.4), 15.0)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .speaking else { return }
                self.finishReply()
            }
            replyTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + safetyTimeout, execute: work)
        }
    }

    // MARK: Audio

    private func startAudio() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif

        if !audioReady {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            player.installTap(onBus: 0, bufferSize: 1024, format: playFormat) { [weak self] buffer, _ in
                guard let self, let samples = buffer.floatChannelData?[0] else { return }
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
                let rms = sqrt(sum / Float(max(buffer.frameLength, 1)))
                self.level = min(1, Double(rms) * 5)
            }
            audioReady = true
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recorder.append(buffer)
            if self.holding, let req = self.recognitionRequest {
                req.append(buffer)
            }
        }
        player.volume = Float(volume)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// A tiny cartoon chirp: a few soft, round, bell-like notes from a happy pentatonic scale.
    private func chirp(syllables: Int) {
        guard audioReady else { return }
        let rate = playFormat.sampleRate
        let scale = [1046.5, 1174.7, 1318.5, 1568.0, 1760.0, 2093.0, 2349.3, 2637.0]
        var index = Int.random(in: 1...3)
        var samples: [Float] = []
        for i in 0..<syllables {
            if i > 0 { index = min(max(index + [-1, 1, 1, 2].randomElement()!, 0), scale.count - 1) }
            let note = scale[index] * 0.5
            let duration = i == syllables - 1 ? 0.13 : Double.random(in: 0.07...0.09)
            let count = Int(duration * rate)
            var phase = 0.0
            for n in 0..<count {
                let time = Double(n) / rate
                let t = Double(n) / Double(count)
                let scoop = 1 - 0.18 * exp(-time / 0.012)
                let wobble = i == syllables - 1 ? 1 + 0.012 * sin(time * 2 * .pi * 18) : 1
                phase += 2 * .pi * note * scoop * wobble / rate
                let attack = min(1, time / 0.006)
                let envelope = attack * exp(-t * 3.2) * (1 - pow(t, 6))
                let wave = sin(phase) + 0.12 * sin(2 * phase)
                samples.append(Float(wave * envelope * 0.26))
            }
            samples += [Float](repeating: 0, count: Int(rate * 0.028))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
        pendingBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 { self.level = 0 }
            }
        }
    }
}
