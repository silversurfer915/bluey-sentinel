import Foundation
import GooglyShared

@MainActor
final class PhoneSessionManager {
    static let shared = PhoneSessionManager()

    private(set) var trustedPeers: [String: String] = [:] // deviceId: deviceName
    private(set) var secureSessions: [String: SecureSession] = [:]
    private(set) var currentSnapshot = PhoneSessionSnapshot()
    private var inFlight: [String: [(CommandAcknowledgement) -> Void]] = [:]
    private var commandReceipts: [String: CommandAcknowledgement] = [:]

    var onEmergencyStop: (() -> Void)?
    var onSnapshotChanged: ((PhoneSessionSnapshot) -> Void)?

    init() {
        syncWithLocalState()
    }

    func syncWithLocalState() {
        let coordinator = BlueyCoordinator.shared
        currentSnapshot.sessionId = coordinator.localSessionId
        currentSnapshot.revision = coordinator.localRevision
        currentSnapshot.plannedSeconds = coordinator.plannedSeconds
        currentSnapshot.elapsedSeconds = Int(coordinator.focusClock.elapsed())
        currentSnapshot.isActive = coordinator.focusClock.isActive
        currentSnapshot.isPaused = coordinator.paused
        let canonical = SanctraSync.shared.activeCanonicalSession
        currentSnapshot.subjectId = canonical?.subjectId
        currentSnapshot.topicId = canonical?.topicId
        currentSnapshot.subjectLabel = canonical?.subjectName ?? Settings.shared.focusGoal
        currentSnapshot.topicLabel = canonical?.topicTitle
        currentSnapshot.lastEventId = coordinator.lastEventId
        let isStopped = ExecutionGate.shared.isStopped
        currentSnapshot.isStopped = isStopped
        currentSnapshot.autonomyMode = Settings.shared.autonomyMode.rawValue
        currentSnapshot.syncStatus = SanctraSync.shared.isConnected
            ? (SanctraSync.shared.syncError != nil ? "offline" : (SanctraSync.shared.pendingOutboxCount > 0 ? "waiting_to_sync" : "connected"))
            : "disconnected"
        onSnapshotChanged?(currentSnapshot)
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

        if inFlight[command.commandId] != nil {
            inFlight[command.commandId]?.append(completion)
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

        let lifecycle: Set<PhoneSessionCommand.Action> = [.pause, .resume, .finish, .abandon]
        if lifecycle.contains(command.action), command.sessionId == nil || command.sessionId != currentSnapshot.sessionId {
            completion(CommandAcknowledgement(commandId: command.commandId, success: false, errorMessage: "Session changed. Refresh before controlling it.", snapshot: currentSnapshot))
            return
        }
        if command.action == .wrapUpNotes, !SanctraSync.shared.isConnected {
            completion(CommandAcknowledgement(commandId: command.commandId, success: false, errorMessage: "Connect Sanctra before saving session notes.", snapshot: currentSnapshot))
            return
        }
        if command.action == .emergencyStop {
            ExecutionGate.shared.stop()
            onEmergencyStop?()
            currentSnapshot.isStopped = true
            let ack = CommandAcknowledgement(commandId: command.commandId, success: true, snapshot: currentSnapshot)
            commandReceipts[command.commandId] = ack
            onSnapshotChanged?(currentSnapshot)
            completion(ack)
            return
        }
        inFlight[command.commandId] = [completion]
        Task { @MainActor in
            var success = true
            var error: String?
            if lifecycle.contains(command.action), SanctraSync.shared.isConnected {
                do {
                    guard let active = SanctraSync.shared.activeCanonicalSession, active.id == command.sessionId else { throw SanctraError.conflict("Active session changed") }
                    let (session, _) = try await SanctraSync.shared.client.mutateSession(sessionId: active.id, operationId: command.commandId, action: command.action.rawValue, expectedRevision: active.revision)
                    BlueyCoordinator.shared.adoptCanonical(session)
                    await SanctraSync.shared.syncNow()
                } catch let failure { success = false; error = failure.localizedDescription }
            } else { switch command.action {
            case .emergencyStop: break
            case .resumeExecution: ExecutionGate.shared.resume()
            case .start:
                error = await BlueyCoordinator.shared.startPhoneFocus(command)
                success = error == nil
            case .pause: _ = await BlueyCoordinator.shared.execute(.pauseFocus(0))
            case .resume: _ = await BlueyCoordinator.shared.execute(.resumeFocus)
            case .finish: _ = await BlueyCoordinator.shared.execute(.stopFocus)
            case .abandon: await BlueyCoordinator.shared.abandonFocus()
            case .checkFocus: _ = await BlueyCoordinator.shared.execute(.checkFocus)
            case .lockWindow: _ = await BlueyCoordinator.shared.execute(.lockTarget)
            case .openNotes: _ = await BlueyCoordinator.shared.execute(.openNotes)
            case .requestDayPlan:
                if let ask = BlueyWorkspace.shared.onAsk { ask("Please review my Sanctra syllabus and plan my study day.") }
                else { success = false; error = "Assistant unavailable." }
            case .approveAction, .declineAction:
                success = command.approvalId.map { BlueyApproval.shared.resolve(id: $0, allowed: command.action == .approveAction) } ?? false
                if !success { error = "Approval expired or belongs to a different action." }
            case .wrapUpNotes:
                do {
                    guard let sessionId = command.sessionId, let notes = command.notes, !notes.isEmpty else { throw SanctraError.notFound }
                    let text = notes + (command.nextStep.map { "\nNext step: " + $0 } ?? "")
                    _ = try await SanctraSync.shared.client.mutateSession(sessionId: sessionId, operationId: command.commandId, action: "edit", notes: text)
                } catch let failure { success = false; error = failure.localizedDescription }
            }
            }
            self.syncWithLocalState()
            let ack = CommandAcknowledgement(commandId: command.commandId, success: success, errorMessage: error, snapshot: self.currentSnapshot)
            self.commandReceipts[command.commandId] = ack
            self.onSnapshotChanged?(self.currentSnapshot)
            let completions = self.inFlight.removeValue(forKey: command.commandId) ?? []
            completions.forEach { $0(ack) }
        }
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
