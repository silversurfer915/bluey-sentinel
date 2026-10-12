import Foundation
import Network
import CryptoKit
import GooglyShared

/// Advertises the Mac on the local network and streams face updates to any phone that connects.
@MainActor
final class PhoneServer {
    private var listener: NWListener?
    private var phones: [ObjectIdentifier: (link: LineConnection, name: String?)] = [:]
    private var pending: [ObjectIdentifier: LineConnection] = [:]
    private let identity = SecureIdentityStore.identity(deviceName: Host.current().localizedName ?? "Mac")
    private struct Pairing {
        var request: PairingRequest
        var session: SecureSession
        var localAccepted: Bool
        var remoteAccepted: Bool = false
    }
    private var pairings: [ObjectIdentifier: Pairing] = [:]
    var onPairingRequested: ((String, String, String) -> Void)?
    private var lastSent: FaceState?
    private var lastSentAt = Date.distantPast
    private var restartWork: DispatchWorkItem?

    /// Called with the names of connected phones whenever that list changes.
    var onPhonesChanged: (([String]) -> Void)?

    /// Called when a phone asks for something. The second argument replies to that phone.
    var onRequest: ((Packet, @escaping (Packet) -> Void) -> Void)?

    var phoneNames: [String] { phones.compactMap { id, phone in
        guard let pairing = pairings[id], pairing.localAccepted && pairing.remoteAccepted else { return nil }
        return phone.name ?? "iPhone"
    } }

    func start() {
        do {
            let listener = try NWListener(using: .googly)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: GooglyService.type)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    Task { @MainActor in self?.scheduleRestart() }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("Googly: could not start listener: \(error)")
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        listener?.cancel()
        listener = nil
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func accept(_ connection: NWConnection) {
        let link = LineConnection(connection)
        let id = ObjectIdentifier(link)
        pending[id] = link  // keep it alive until it is ready
        link.onState = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                self.pending[id] = nil
                self.phones[id] = (link, nil)
                link.send(Packet(hello: Host.current().localizedName ?? "Mac"))

                self.onPhonesChanged?(self.phoneNames)
            case .failed, .cancelled:
                self.pending[id] = nil
                self.phones[id] = nil
                self.pairings[id] = nil
                self.onPhonesChanged?(self.phoneNames)
            default:
                break
            }
        }
        link.onPacket = { [weak self, weak link] packet in
            guard let self, self.phones[id] != nil else { return }
            if let name = packet.hello {
                self.phones[id]?.name = name
                self.onPhonesChanged?(self.phoneNames)
            }
            if let pairingReq = packet.pairingRequest {
                self.handlePairing(pairingReq, id: id) { [weak link] response in link?.send(response) }
                return
            }
            guard let frame = packet.encryptedFrame, var pairing = self.pairings[id],
                  let data = try? pairing.session.decrypt(frame: frame),
                  let inner = try? JSONDecoder().decode(Packet.self, from: data) else { return }
            if inner.command == "pairingConfirm" {
                pairing.remoteAccepted = true
                self.pairings[id] = pairing
                self.completePairing(id)
                return
            }
            guard pairing.localAccepted, pairing.remoteAccepted else { return }
            if let command = inner.sessionCommand {
                PhoneSessionManager.shared.executeCommand(command, fromPeer: pairing.request.deviceId) { [weak self] ack in
                    self?.sendSecure(Packet(commandAck: ack), to: id)
                }
            } else {
                self.onRequest?(inner) { [weak self] response in self?.sendSecure(response, to: id) }
            }
        }
        link.start()
    }

    private func handlePairing(_ request: PairingRequest, id: ObjectIdentifier, reply: @escaping (Packet) -> Void) {
        guard pairings[id] == nil, request.deviceId.count <= 128, request.deviceName.count <= 128,
              request.salt.count == 16 else { return }
        do {
            let response = try identity.respondToPairing(request: request)
            let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKeyData)
            let session = try identity.establishSession(peerId: request.deviceId, peerKey: peerKey, salt: request.salt)
            let trusted = SecureIdentityStore.isTrusted(peerId: request.deviceId, publicKey: request.publicKeyData)
            pairings[id] = Pairing(request: request, session: session, localAccepted: trusted)
            reply(Packet(pairingResponse: response))
            if !trusted { onPairingRequested?(String(describing: id), request.deviceName, request.sasCode(with: identity.publicKey)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, let pending = self.pairings[id], !(pending.localAccepted && pending.remoteAccepted) else { return }
                self.phones[id]?.link.cancel()
            }
        } catch { phones[id]?.link.cancel() }
    }

    func confirmPairing(_ connectionId: String, accepted: Bool) {
        guard let id = pairings.keys.first(where: { String(describing: $0) == connectionId }), var pending = pairings[id] else { return }
        guard accepted else { phones[id]?.link.cancel(); return }
        guard SecureIdentityStore.trust(peerId: pending.request.deviceId, publicKey: pending.request.publicKeyData) else { phones[id]?.link.cancel(); return }
        pending.localAccepted = true
        pairings[id] = pending
        completePairing(id)
    }

    private func completePairing(_ id: ObjectIdentifier) {
        guard let pairing = pairings[id], pairing.localAccepted, pairing.remoteAccepted else { return }
        onPhonesChanged?(phoneNames)
        PhoneSessionManager.shared.registerSession(peerId: pairing.request.deviceId, session: pairing.session)
        sendSecure(Packet(command: "pairingReady", sessionSnapshot: PhoneSessionManager.shared.currentSnapshot), to: id)
        if let face = lastSent { sendSecure(Packet(face: face), to: id) }
    }

    private func sendSecure(_ packet: Packet, to id: ObjectIdentifier) {
        guard let pairing = pairings[id], let data = try? JSONEncoder().encode(packet),
              let frame = try? pairing.session.encrypt(plaintext: data) else { return }
        phones[id]?.link.send(Packet(encryptedFrame: frame))
    }

    /// Sends a command to every phone (e.g. "wake", "sleep").
    func broadcast(_ packet: Packet) {
        for (id, pairing) in pairings where pairing.localAccepted && pairing.remoteAccepted { sendSecure(packet, to: id) }
    }

    /// Sends the face to every phone, skipping updates too small to see.
    func send(_ face: FaceState) {
        // Resend at least once a second even when nothing changed, so the phone knows the Mac is still driving.
        let now = Date()
        if let last = lastSent, now.timeIntervalSince(lastSentAt) < 1,
           last.mood == face.mood,
           abs(last.gazeX - face.gazeX) < 0.004,
           abs(last.gazeY - face.gazeY) < 0.004,
           abs(last.talk - face.talk) < 0.02 {
            return
        }
        lastSent = face
        lastSentAt = now
        broadcast(Packet(face: face))
    }
}
