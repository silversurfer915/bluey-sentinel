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
    private var inputCapture: MicrophoneCapture?

    private(set) var isListening = false
    private var silenceTimer: Timer?
    private var currentTranscript: String = ""
    private var recognitionGeneration = UUID()
    private var pendingStartID: UUID?

    /// Callbacks
    var onError: ((String) -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onCommandRecognized: ((String) -> Void)?

    override init() {
        super.init()
        speechRecognizer?.delegate = self
        MicrophoneStore.shared.onRouteChanged = { [weak self] in
            guard let self, self.isListening, let request = self.recognitionRequest else { return }
            self.inputCapture?.stop()
            do {
                self.inputCapture = try self.capture(for: request)
                self.inputCapture?.start()
            } catch {
                self.stopListening(processCommand: false)
                self.onError?(error.localizedDescription)
            }
        }
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
        guard !ExecutionGate.shared.isStopped else { return }
        guard !isListening else { return }

        let startID = UUID()
        pendingStartID = startID

        // Cancel any active TTS playback so Bluey doesn't talk over the user
        Voice.shared.stop()

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus != .authorized || micStatus != .authorized {
            if authStatus == .denied || authStatus == .restricted || micStatus == .denied || micStatus == .restricted {
                pendingStartID = nil
                showPermissionDeniedAlert()
                return
            }
            requestPermissions { [weak self] granted in
                guard let self, self.pendingStartID == startID, !ExecutionGate.shared.isStopped else { return }
                if granted {
                    self.startListening()
                } else {
                    self.pendingStartID = nil
                    self.showPermissionDeniedAlert()
                }
            }
            return
        }

        cleanupAudio()

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            onError?("Speech recognition is unavailable. Use the text field in Bluey instead.")
            return
        }

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            // Prefer on-device Apple Silicon Neural Engine for 0ms lag and complete privacy
            if speechRecognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            let generation = UUID()
            recognitionGeneration = generation
            self.recognitionRequest = request
            self.currentTranscript = ""

            inputCapture = try capture(for: request)
            inputCapture?.start()

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
                    guard self.isListening, self.recognitionGeneration == generation else { return }

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
            onError?(error.localizedDescription)
        }
    }

    /// Stops listening and optionally delivers recognized text to the AI brain.
    func stopListening(processCommand: Bool) {
        pendingStartID = nil
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
        silenceTimer = Timer.scheduledTimer(withTimeInterval: currentTranscript.isEmpty ? 8.0 : 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                self.stopListening(processCommand: !self.currentTranscript.isEmpty)
            }
        }
    }

    private func capture(for request: SFSpeechAudioBufferRecognitionRequest) throws -> MicrophoneCapture {
        guard let uid = MicrophoneStore.shared.activeUID else {
            throw NSError(domain: "BlueyMicrophone", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        return try MicrophoneCapture(uid: uid) { buffer in request.appendAudioSampleBuffer(buffer) }
    }

    private func cleanupAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        inputCapture?.stop()
        inputCapture = nil

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
