import AVFoundation
import AppKit
import Foundation
import Speech

/// Native on-Mac speech recognition for voice commands when no phone is connected.
/// Uses Apple's Neural Engine on Apple Silicon (M1) for 100% on-device, private, zero-latency transcription.
@MainActor
final class MacVoiceInput: NSObject, SFSpeechRecognizerDelegate {
    static let shared = MacVoiceInput()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private(set) var isListening = false
    private var silenceTimer: Timer?
    private var currentTranscript: String = ""

    /// Callbacks
    var onListeningChanged: ((Bool) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onCommandRecognized: ((String) -> Void)?

    override init() {
        super.init()
        speechRecognizer?.delegate = self
    }

    /// Checks or prompts for Microphone and Speech Recognition permissions.
    func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                Task { @MainActor in
                    let ok = (authStatus == .authorized) && audioGranted
                    completion(ok)
                }
            }
        }
    }

    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone & Speech Access Needed"
        alert.informativeText = "To use voice commands directly on your Mac without your phone, please enable Microphone and Speech Recognition access for Bluey in System Settings > Privacy & Security."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Toggles listening state.
    func toggleListening() {
        if isListening {
            stopListening(processCommand: true)
        } else {
            startListening()
        }
    }

    /// Starts streaming microphone audio to Apple Speech Recognizer.
    func startListening() {
        guard !isListening else { return }

        // Cancel any active TTS playback so Bluey doesn't talk over the user
        Voice.shared.stop()

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus != .authorized || micStatus != .authorized {
            if authStatus == .denied || authStatus == .restricted || micStatus == .denied || micStatus == .restricted {
                showPermissionDeniedAlert()
                return
            }
            requestPermissions { [weak self] granted in
                if granted {
                    self?.startListening()
                } else {
                    self?.showPermissionDeniedAlert()
                }
            }
            return
        }

        cleanupAudio()

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            NSLog("[MacVoiceInput] SFSpeechRecognizer not available")
            return
        }

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            // Prefer on-device Apple Silicon Neural Engine for 0ms lag and complete privacy
            if speechRecognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            self.recognitionRequest = request
            self.currentTranscript = ""

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                NSLog("[MacVoiceInput] Invalid input node audio format")
                return
            }

            // Grab the request locally: this closure runs on the audio render thread, and reading
            // `self.recognitionRequest` from there races the main thread nilling it in
            // cleanupAudio(). Holding a local reference also keeps it alive for the tap's lifetime.
            let activeRequest = request
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                activeRequest.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            isListening = true
            onListeningChanged?(true)
            Voice.shared.chirp() // subtle audio cue indicating listening started

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    // A trailing callback can arrive after the session already ended (silence timer,
                    // final result, or a new ⌥Space). Without this guard it re-announced "Listening…"
                    // and left the notch island stuck in that state forever, because no further
                    // callback was ever coming to clear it.
                    guard self.isListening else { return }

                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.currentTranscript = text
                        self.onPartialTranscript?(text)

                        // Reset silence timer on every new word detected
                        self.resetSilenceTimer()

                        if result.isFinal {
                            self.stopListening(processCommand: true)
                        }
                    }

                    if let error {
                        let nsErr = error as NSError
                        // Only genuine cancellations are ignored. The old test suppressed EVERY
                        // error from the Speech domain, so a real failure (server error, recogniser
                        // unavailable) ended the session silently with no transcript and no
                        // explanation — voice input just looked dead.
                        let cancelled = nsErr.domain == "kAFAssistantErrorDomain"
                            && (nsErr.code == 216 || nsErr.code == 1110 || nsErr.code == 1101)
                        if !cancelled {
                            NSLog("[MacVoiceInput] Recognition error \(nsErr.domain)/\(nsErr.code): \(error.localizedDescription)")
                        }
                        self.stopListening(processCommand: !self.currentTranscript.isEmpty)
                    }
                }
            }

            resetSilenceTimer()
        } catch {
            NSLog("[MacVoiceInput] Could not start audio engine: \(error.localizedDescription)")
            cleanupAudio()
        }
    }

    /// Stops listening and optionally delivers recognized text to the AI brain.
    func stopListening(processCommand: Bool) {
        guard isListening else { return }

        silenceTimer?.invalidate()
        silenceTimer = nil

        let recognized = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupAudio()

        isListening = false
        onListeningChanged?(false)

        if processCommand && !recognized.isEmpty {
            onCommandRecognized?(recognized)
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        // Automatically finalize if user stays silent for 1.5 seconds after speaking
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if !self.currentTranscript.isEmpty {
                    self.stopListening(processCommand: true)
                }
            }
        }
    }

    private func cleanupAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        // Remove the tap unconditionally. It used to sit inside the `isRunning` check, but the tap
        // is installed BEFORE audioEngine.start() — so when start() threw, the tap was left on bus 0
        // and the next installTap() on that bus raised an exception. One transient audio failure
        // could permanently break Mac voice input (or crash the app).
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            if !available, self.isListening {
                self.stopListening(processCommand: false)
            }
        }
    }
}
