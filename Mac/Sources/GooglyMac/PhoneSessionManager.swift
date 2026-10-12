import Foundation
import GooglyShared

@MainActor
final class PhoneSessionManager {
    static let shared = PhoneSessionManager()

    private(set) var trustedPeers: [String: String] = [:] // deviceId: deviceName
    private(set) var secureSessions: [String: SecureSession] = [:]
    private(set) var currentSnapshot = PhoneSessionSnapshot()
    private var commandReceipts: [String: CommandAcknowledgement] = [:]

    var onSnapshotChanged: ((PhoneSessionSnapshot) -> Void)?

    init() {
        syncWithLocalState()
    }

    func syncWithLocalState() {
        let isStopped = ExecutionGate.shared.isStopped
        currentSnapshot.isStopped = isStopped
        currentSnapshot.autonomyMode = Settings.shared.autonomyMode.rawValue
        currentSnapshot.syncStatus = SanctraSync.shared.isConnected
            ? (SanctraSync.shared.pendingOutboxCount > 0 ? "waiting_to_sync" : "connected")
            : "disconnected"
    }

    func trustPeer(deviceId: String, name: String) {
        trustedPeers[deviceId] = name
    }

    func registerSession(peerId: String, session: SecureSession) {
        trustedPeers[peerId] = session.peerId
        secureSessions[peerId] = session
    }

    func updateSnapshot(_ snapshot: PhoneSessionSnapshot) {
        currentSnapshot = snapshot
        onSnapshotChanged?(currentSnapshot)
    }

    func updateApproval(_ approval: AgentApprovalRequest?) {
        currentSnapshot.pendingApproval = approval
        currentSnapshot.revision += 1
        onSnapshotChanged?(currentSnapshot)
    }

    func executeCommand(_ command: PhoneSessionCommand, fromPeer peerId: String, completion: @escaping (CommandAcknowledgement) -> Void) {
        guard trustedPeers[peerId] != nil else {
            let ack = CommandAcknowledgement(
                commandId: command.commandId,
                success: false,
                errorMessage: "Unauthorized: device not paired or frame not encrypted",
                snapshot: currentSnapshot
            )
            completion(ack)
            return
        }

        // Idempotency check:
        if let existing = commandReceipts[command.commandId] {
            completion(existing)
            return
        }

        // Stale revision check:
        if let expected = command.expectedRevision, expected != currentSnapshot.revision {
            let ack = CommandAcknowledgement(
                commandId: command.commandId,
                success: false,
                errorMessage: "Revision conflict: expected \(expected), current is \(currentSnapshot.revision)",
                snapshot: currentSnapshot
            )
            completion(ack)
            return
        }

        var ack = CommandAcknowledgement(commandId: command.commandId, success: true)

        switch command.action {
        case .emergencyStop:
            ExecutionGate.shared.stop()
            currentSnapshot.isStopped = true
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot

        case .resumeExecution:
            ExecutionGate.shared.resume()
            currentSnapshot.isStopped = false
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot

        case .start:
            let sid = command.sessionId ?? UUID().uuidString
            currentSnapshot.sessionId = sid
            currentSnapshot.subjectId = command.subjectId
            currentSnapshot.topicId = command.topicId
            currentSnapshot.subjectLabel = command.subjectLabel
            currentSnapshot.topicLabel = command.topicLabel
            currentSnapshot.plannedSeconds = command.plannedSeconds ?? 1500
            currentSnapshot.elapsedSeconds = 0
            currentSnapshot.isPaused = false
            currentSnapshot.isActive = true
            currentSnapshot.startedAt = command.timestamp
            currentSnapshot.lastEventId = "start_\(sid)_\(Int(command.timestamp))"
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot

            let topic = command.topicLabel ?? command.subjectLabel ?? "Focus"
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.startFocus(topic))
            }

        case .pause:
            currentSnapshot.isPaused = true
            let sid = currentSnapshot.sessionId ?? "current"
            currentSnapshot.lastEventId = "pause_\(sid)_\(Int(Date().timeIntervalSince1970))"
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.pauseFocus(0))
            }

        case .resume:
            currentSnapshot.isPaused = false
            let sid = currentSnapshot.sessionId ?? "current"
            currentSnapshot.lastEventId = "resume_\(sid)_\(Int(Date().timeIntervalSince1970))"
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.resumeFocus)
            }

        case .finish:
            currentSnapshot.isActive = false
            currentSnapshot.isPaused = false
            let sid = currentSnapshot.sessionId ?? "current"
            currentSnapshot.lastEventId = "finish_\(sid)_\(Int(Date().timeIntervalSince1970))"
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.stopFocus)
            }

        case .abandon:
            currentSnapshot.isActive = false
            currentSnapshot.isPaused = false
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.stopFocus)
            }

        case .checkFocus:
            ack.snapshot = currentSnapshot
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.checkFocus)
            }

        case .lockWindow:
            ack.snapshot = currentSnapshot
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.lockTarget)
            }

        case .openNotes:
            ack.snapshot = currentSnapshot
            Task { @MainActor in
                await BlueyCoordinator.shared.execute(.openNotes)
            }

        case .requestDayPlan:
            BlueyWorkspace.shared.onAsk?("Please review my Sanctra syllabus and plan my study day.")
            ack.snapshot = currentSnapshot

        case .approveAction:
            currentSnapshot.pendingApproval = nil
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot

        case .declineAction:
            currentSnapshot.pendingApproval = nil
            currentSnapshot.revision += 1
            ack.snapshot = currentSnapshot

        case .wrapUpNotes:
            if let notes = command.notes, !notes.isEmpty {
                NSLog("Googly: Session wrap-up notes saved: \(notes)")
            }
            ack.snapshot = currentSnapshot
        }

        commandReceipts[command.commandId] = ack
        onSnapshotChanged?(currentSnapshot)
        completion(ack)
    }

    func handlePacket(_ packet: Packet, fromPeer peerId: String, reply: @escaping (Packet) -> Void) {
        if let frame = packet.encryptedFrame {
            guard let session = secureSessions[peerId] else {
                let ack = CommandAcknowledgement(
                    commandId: "unknown",
                    success: false,
                    errorMessage: "Session not established",
                    snapshot: currentSnapshot
                )
                reply(Packet(commandAck: ack))
                return
            }
            do {
                let decrypted = try session.decrypt(frame: frame)
                let command = try JSONDecoder().decode(PhoneSessionCommand.self, from: decrypted)
                executeCommand(command, fromPeer: peerId) { [weak session] ack in
                    guard let session else {
                        reply(Packet(commandAck: ack))
                        return
                    }
                    if let ackData = try? JSONEncoder().encode(ack),
                       let encAck = try? session.encrypt(plaintext: ackData) {
                        reply(Packet(encryptedFrame: encAck, commandAck: ack))
                    } else {
                        reply(Packet(commandAck: ack))
                    }
                }
            } catch {
                let ack = CommandAcknowledgement(
                    commandId: "error",
                    success: false,
                    errorMessage: "Decryption failed: \(error.localizedDescription)",
                    snapshot: currentSnapshot
                )
                reply(Packet(commandAck: ack))
            }
            return
        }

        // If unencrypted control command arrives from untrusted / unpaired peer:
        if let cmd = packet.command, cmd != "hello", cmd != "testVoice" {
            let ack = CommandAcknowledgement(
                commandId: packet.callID ?? "unknown",
                success: false,
                errorMessage: "Unauthorized: device not paired or frame not encrypted",
                snapshot: currentSnapshot
            )
            reply(Packet(commandAck: ack))
            return
        }
    }
}
