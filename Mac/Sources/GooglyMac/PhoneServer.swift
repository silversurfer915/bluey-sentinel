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
    private var lastSent: FaceState?
    private var lastSentAt = Date.distantPast
    private var restartWork: DispatchWorkItem?

    /// Called with the names of connected phones whenever that list changes.
    var onPhonesChanged: (([String]) -> Void)?

    /// Called when a phone asks for something. The second argument replies to that phone.
    var onRequest: ((Packet, @escaping (Packet) -> Void) -> Void)?

    var phoneNames: [String] { phones.values.map { $0.name ?? "iPhone" } }

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
                if let face = self.lastSent { link.send(Packet(face: face)) }
                self.onPhonesChanged?(self.phoneNames)
            case .failed, .cancelled:
                self.pending[id] = nil
                self.phones[id] = nil
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
            if packet.encryptedFrame != nil {
                let peerId = packet.encryptedFrame?.senderId ?? "\(id)"
                PhoneSessionManager.shared.handlePacket(packet, fromPeer: peerId) { [weak link] response in
                    link?.send(response)
                }
                return
            }
            if packet.command != nil {
                let peerId = self.phones[id]?.name ?? "\(id)"
                PhoneSessionManager.shared.handlePacket(packet, fromPeer: peerId) { [weak self, weak link] response in
                    if response.commandAck != nil {
                        link?.send(response)
                    } else {
                        self?.onRequest?(packet) { [weak link] innerResponse in link?.send(innerResponse) }
                    }
                }
            }
        }
        link.start()
    }

    private func handlePairing(_ request: PairingRequest, id: ObjectIdentifier, reply: @escaping (Packet) -> Void) {
        do {
            let identity = SecureDeviceIdentity(deviceName: Host.current().localizedName ?? "Mac")
            let response = try identity.respondToPairing(request: request)
            if let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKeyData) {
                let session = try identity.establishSession(peerId: request.deviceId, peerKey: peerKey)
                PhoneSessionManager.shared.registerSession(peerId: request.deviceId, session: session)
            }
            reply(Packet(pairingResponse: response, sessionSnapshot: PhoneSessionManager.shared.currentSnapshot))
        } catch {
            NSLog("Googly: pairing failed: \(error)")
        }
    }

    /// Sends a command to every phone (e.g. "wake", "sleep").
    func broadcast(_ packet: Packet) {
        for phone in phones.values { phone.link.send(packet) }
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
        for phone in phones.values { phone.link.send(Packet(face: face)) }
    }
}
