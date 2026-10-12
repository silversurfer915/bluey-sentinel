import Foundation
import Network
import SwiftUI
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Finds the Mac app on the local network with Bonjour and keeps a connection open.
final class MacLink: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var isPaired = false
    @Published private(set) var pairingSASCode: String?
    @Published private(set) var macName: String?
    /// Every Mac running Bluey on this Wi-Fi, by its Bonjour name.
    @Published private(set) var macs: [String] = []
    /// The Mac the phone is linked to (or trying to link to).
    @Published private(set) var currentMac: String?
    /// The Mac picked in the speaker panel. Remembered, so the phone goes back to it on launch.
    @Published private(set) var preferredMac: String? = UserDefaults.standard.string(forKey: "preferredMac")
    /// Authoritative focus session snapshot from the Mac.
    @Published private(set) var snapshot = PhoneSessionSnapshot()

    /// Commands from the Mac, like "wake" and "sleep".
    var onCommand: ((String) -> Void)?
    var onPacket: ((Packet) -> Void)?
    var onFace: ((FaceState) -> Void)?

    private var waiting: [String: (Packet?) -> Void] = [:]
    private var browser: NWBrowser?
    private var link: LineConnection?
    private var retry: DispatchWorkItem?

    let identity: SecureDeviceIdentity
    private var secureSession: SecureSession?

    init() {
        self.identity = SecureDeviceIdentity(deviceName: Self.deviceName)
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: GooglyService.type, domain: nil), using: .googly)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.macs = results.compactMap(Self.serviceName).sorted()
            if let preferred = self.preferredMac, self.currentMac != preferred, self.macs.contains(preferred) {
                self.link?.cancel()
            }
            self.connectIfNeeded()
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.restart() }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        retry?.cancel()
        browser?.cancel()
        browser = nil
        link?.cancel()
        link = nil
        connected = false
        isPaired = false
    }

    private func restart() {
        stop()
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.browser == nil { self.start() } else { self.connectIfNeeded() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func choose(_ name: String) {
        preferredMac = name
        UserDefaults.standard.set(name, forKey: "preferredMac")
        if currentMac != name { link?.cancel() }
        connectIfNeeded()
    }

    private static func serviceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func connectIfNeeded() {
        guard link == nil, let results = browser?.browseResults, !results.isEmpty else { return }
        let result = results.first { Self.serviceName($0) == preferredMac } ?? results.first!
        currentMac = Self.serviceName(result)
        let link = LineConnection(NWConnection(to: result.endpoint, using: .googly))
        link.onState = { [weak self, weak link] state in
            guard let self, let link, link === self.link else { return }
            switch state {
            case .ready:
                self.connected = true
                let pairReq = self.identity.makePairingRequest()
                link.send(Packet(hello: Self.deviceName, pairingRequest: pairReq))
            case .failed, .cancelled:
                self.connected = false
                self.isPaired = false
                let waiting = self.waiting
                self.waiting = [:]
                waiting.values.forEach { $0(nil) }
                self.macName = nil
                self.link = nil
                self.scheduleRetry()
            case .waiting:
                link.cancel()
            default:
                break
            }
        }
        link.onPacket = { [weak self] packet in
            guard let self else { return }
            if let name = packet.hello { self.macName = name }
            if let face = packet.face { self.onFace?(face) }

            if let pairResp = packet.pairingResponse {
                self.handlePairingResponse(pairResp)
            }

            if let snap = packet.sessionSnapshot {
                self.snapshot = snap
            }

            if let ack = packet.commandAck {
                if let snap = ack.snapshot { self.snapshot = snap }
                if let done = self.waiting.removeValue(forKey: ack.commandId) {
                    done(packet)
                }
            }

            if let frame = packet.encryptedFrame, let session = self.secureSession {
                if let decrypted = try? session.decrypt(frame: frame),
                   let ack = try? JSONDecoder().decode(CommandAcknowledgement.self, from: decrypted) {
                    if let snap = ack.snapshot { self.snapshot = snap }
                    if let done = self.waiting.removeValue(forKey: ack.commandId) {
                        done(Packet(commandAck: ack))
                    }
                }
            }

            self.onPacket?(packet)
            if let command = packet.command {
                if let callID = packet.callID, let done = self.waiting.removeValue(forKey: callID) {
                    done(packet)
                } else {
                    self.onCommand?(command)
                }
            }
        }
        self.link = link
        link.start()
    }

    private func handlePairingResponse(_ response: PairingResponse) {
        do {
            guard let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: response.publicKeyData) else { return }
            let session = try identity.establishSession(peerId: response.deviceId, peerKey: peerKey)
            self.secureSession = session
            self.isPaired = true
            self.pairingSASCode = response.sasCode(with: identity.publicKey)
        } catch {
            NSLog("Googly: phone failed to establish secure session: \(error)")
        }
    }

    func send(_ packet: Packet) {
        link?.send(packet)
    }

    func request(_ packet: Packet, _ done: @escaping (Packet?) -> Void) {
        guard let link, connected else { done(nil); return }
        var packet = packet
        let id = UUID().uuidString
        packet.callID = id
        waiting[id] = done
        link.send(packet)
    }

    // MARK: - Controller Commands

    func sendCommand(_ command: PhoneSessionCommand, completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        guard let link, connected else {
            completion?(CommandAcknowledgement(commandId: command.commandId, success: false, errorMessage: "Mac disconnected"))
            return
        }

        if let session = secureSession, let data = try? JSONEncoder().encode(command),
           let frame = try? session.encrypt(plaintext: data) {
            waiting[command.commandId] = { reply in
                completion?(reply?.commandAck)
            }
            link.send(Packet(callID: command.commandId, encryptedFrame: frame))
        } else {
            // Unencrypted fallback (will be gated/rejected by Mac if unauthorized)
            waiting[command.commandId] = { reply in
                completion?(reply?.commandAck)
            }
            link.send(Packet(command: command.action.rawValue, callID: command.commandId))
        }
    }

    func startFocus(subjectLabel: String, topicLabel: String?, durationMinutes: Int, completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(
            action: .start,
            sessionId: "phone-" + UUID().uuidString,
            subjectLabel: subjectLabel,
            topicLabel: topicLabel,
            plannedSeconds: durationMinutes * 60,
            timestamp: Date().timeIntervalSince1970
        )
        sendCommand(cmd, completion: completion)
    }

    func pauseFocus(completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(
            action: .pause,
            sessionId: snapshot.sessionId,
            expectedRevision: snapshot.revision,
            timestamp: Date().timeIntervalSince1970
        )
        sendCommand(cmd, completion: completion)
    }

    func resumeFocus(completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(
            action: .resume,
            sessionId: snapshot.sessionId,
            expectedRevision: snapshot.revision,
            timestamp: Date().timeIntervalSince1970
        )
        sendCommand(cmd, completion: completion)
    }

    func finishFocus(completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(
            action: .finish,
            sessionId: snapshot.sessionId,
            expectedRevision: snapshot.revision,
            timestamp: Date().timeIntervalSince1970
        )
        sendCommand(cmd, completion: completion)
    }

    func abandonFocus(completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(
            action: .abandon,
            sessionId: snapshot.sessionId,
            expectedRevision: snapshot.revision,
            timestamp: Date().timeIntervalSince1970
        )
        sendCommand(cmd, completion: completion)
    }

    func emergencyStop(completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(action: .emergencyStop)
        sendCommand(cmd, completion: completion)
    }

    func resumeExecution(completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(action: .resumeExecution)
        sendCommand(cmd, completion: completion)
    }

    func quickAction(_ action: PhoneSessionCommand.Action, completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(action: action)
        sendCommand(cmd, completion: completion)
    }

    func respondToApproval(id: String, approve: Bool, completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(action: approve ? .approveAction : .declineAction, approvalId: id)
        sendCommand(cmd, completion: completion)
    }

    func saveWrapUpNotes(notes: String, nextStep: String?, completion: ((CommandAcknowledgement?) -> Void)? = nil) {
        let cmd = PhoneSessionCommand(
            action: .wrapUpNotes,
            sessionId: snapshot.sessionId,
            notes: notes,
            nextStep: nextStep
        )
        sendCommand(cmd, completion: completion)
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Phone"
        #endif
    }
}
