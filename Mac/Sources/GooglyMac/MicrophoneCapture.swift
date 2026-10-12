import AVFoundation

/// A capture session for exactly one input. Independent from speaker/output routing.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bluey.microphone.capture")
    private let lock = NSLock()
    private var stopped = false
    private let receive: (CMSampleBuffer) -> Void
    init(uid: String, receive: @escaping (CMSampleBuffer) -> Void) throws {
        self.receive = receive
        super.init()
        guard let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) else {
            throw NSError(domain: "BlueyMicrophone", code: 1, userInfo: [NSLocalizedDescriptionKey: "This microphone is unavailable. Select another input."])
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "BlueyMicrophone", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open this microphone."])
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }
    func start() {
        queue.async { [self] in
            lock.lock(); let start = !stopped; lock.unlock()
            if start { session.startRunning() }
        }
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in session.stopRunning() }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        receive(sampleBuffer)
    }
}
