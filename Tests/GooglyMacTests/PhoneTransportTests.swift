import XCTest
import CryptoKit
@testable import GooglyShared
@testable import GooglyMac

final class PhoneTransportTests: XCTestCase {
    func testPhoneHistoryAcknowledgementCarriesCanonicalIdentityAndNotes() throws {
        let payload = #"{"commandId":"history","success":true,"history":{"sessions":[{"id":"shared-session","subjectName":"Physics","durationSeconds":123,"notes":"Learned optics"}],"nextCursor":null}}"#
        let ack = try JSONDecoder().decode(CommandAcknowledgement.self, from: Data(payload.utf8))
        XCTAssertEqual(ack.history?.sessions.first?.id, "shared-session")
        XCTAssertEqual(ack.history?.sessions.first?.notes, "Learned optics")
    }

    func testWidgetClockFreezesPausedTimeAndBindsControlToSession() {
        let date = Date(timeIntervalSince1970: 1000)
        let running = FocusWidgetSnapshot(PhoneSessionSnapshot(sessionId: "shared", elapsedSeconds: 120, isActive: true, revision: 8), at: date)
        XCTAssertEqual(running.elapsed(at: date.addingTimeInterval(30)), 150)
        let paused = FocusWidgetSnapshot(PhoneSessionSnapshot(sessionId: "shared", elapsedSeconds: 120, isPaused: true, isActive: true, revision: 8), at: date)
        XCTAssertEqual(paused.elapsed(at: date.addingTimeInterval(30)), 120)
        let url = URLComponents(url: running.controlURL("pause")!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "id" })?.value, "shared")
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "revision" })?.value, "8")
    }

    func testPairingAndKeyDerivation() throws {
        let macIdentity = SecureDeviceIdentity(deviceName: "MacBook Pro")
        let phoneIdentity = SecureDeviceIdentity(deviceName: "iPhone")
        
        let pairRequest = phoneIdentity.makePairingRequest()
        let pairResponse = try macIdentity.respondToPairing(request: pairRequest)
        
        XCTAssertEqual(pairRequest.sasCode(with: macIdentity.publicKey), pairResponse.sasCode(with: phoneIdentity.publicKey))
        
        let macSession = try macIdentity.establishSession(peerId: phoneIdentity.deviceId, peerKey: phoneIdentity.publicKey)
        let phoneSession = try phoneIdentity.establishSession(peerId: macIdentity.deviceId, peerKey: macIdentity.publicKey)
        
        let plaintext = "Hello from iPhone".data(using: .utf8)!
        let frame = try phoneSession.encrypt(plaintext: plaintext)
        
        let decrypted = try macSession.decrypt(frame: frame)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testBidirectionalFramesUseDifferentNonces() throws {
        let a = SecureDeviceIdentity(deviceName: "A")
        let b = SecureDeviceIdentity(deviceName: "B")
        let ab = try a.establishSession(peerId: b.deviceId, peerKey: b.publicKey)
        let ba = try b.establishSession(peerId: a.deviceId, peerKey: a.publicKey)
        let first = try ab.encrypt(plaintext: Data("request".utf8))
        let reply = try ba.encrypt(plaintext: Data("reply".utf8))
        XCTAssertNotEqual(first.nonce, reply.nonce)
        XCTAssertEqual(try ba.decrypt(frame: first), Data("request".utf8))
        XCTAssertEqual(try ab.decrypt(frame: reply), Data("reply".utf8))
    }

    func testFrameSequenceCannotBeChangedToBypassReplay() throws {
        let a = SecureDeviceIdentity(deviceName: "A")
        let b = SecureDeviceIdentity(deviceName: "B")
        let ab = try a.establishSession(peerId: b.deviceId, peerKey: b.publicKey)
        let ba = try b.establishSession(peerId: a.deviceId, peerKey: a.publicKey)
        var frame = try ab.encrypt(plaintext: Data("stop".utf8))
        _ = try ba.decrypt(frame: frame)
        frame.sequence += 1
        XCTAssertThrowsError(try ba.decrypt(frame: frame))
    }

    func testReplayProtectionRejectsOldOrEqualSequence() throws {
        let macIdentity = SecureDeviceIdentity(deviceName: "Mac")
        let phoneIdentity = SecureDeviceIdentity(deviceName: "iPhone")
        
        let macSession = try macIdentity.establishSession(peerId: phoneIdentity.deviceId, peerKey: phoneIdentity.publicKey)
        let phoneSession = try phoneIdentity.establishSession(peerId: macIdentity.deviceId, peerKey: macIdentity.publicKey)
        
        let frame1 = try phoneSession.encrypt(plaintext: "cmd 1".data(using: .utf8)!)
        let frame2 = try phoneSession.encrypt(plaintext: "cmd 2".data(using: .utf8)!)
        
        _ = try macSession.decrypt(frame: frame1)
        _ = try macSession.decrypt(frame: frame2)
        
        // Replaying frame1 must throw an error
        XCTAssertThrowsError(try macSession.decrypt(frame: frame1)) { error in
            guard let secError = error as? SecureTransportError, case .replayDetected = secError else {
                XCTFail("Expected replayDetected error, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testUnauthenticatedCommandsAreRejected() {
        let server = PhoneSessionManager()
        let unauthenticatedPacket = Packet(command: "startFocus", text: "Physics")
        
        let expectation = expectation(description: "Rejected reply")
        server.handlePacket(unauthenticatedPacket, fromPeer: "unpaired_device_1") { response in
            XCTAssertEqual(response.commandAck?.success, false)
            XCTAssertEqual(response.commandAck?.errorMessage, "Unauthorized: device not paired or frame not encrypted")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    @MainActor
    func testStaleCommandRevisionRejection() throws {
        let manager = PhoneSessionManager()
        let phoneId = "paired_phone_1"
        manager.trustPeer(deviceId: phoneId, name: "Test iPhone")
        
        let currentSnapshot = PhoneSessionSnapshot(
            sessionId: "sess_100",
            subjectId: "sub_1",
            topicId: "top_1",
            subjectLabel: "Physics",
            topicLabel: "Optics",
            plannedSeconds: 1500,
            elapsedSeconds: 300,
            isPaused: false,
            isActive: true,
            startedAt: Date().timeIntervalSince1970 - 300,
            revision: 3,
            syncStatus: "connected",
            isStopped: false,
            autonomyMode: "confirmConsequences"
        )
        manager.updateSnapshot(currentSnapshot)
        
        // Stale command expecting revision 2 when current is 3
        let staleCommand = PhoneSessionCommand(
            commandId: "cmd_stale_1",
            action: .pause,
            sessionId: "sess_100",
            expectedRevision: 2,
            timestamp: Date().timeIntervalSince1970
        )
        
        let expectation = expectation(description: "Conflict reply")
        manager.executeCommand(staleCommand, fromPeer: phoneId) { ack in
            XCTAssertFalse(ack.success)
            XCTAssertTrue(ack.errorMessage?.contains("Revision conflict") == true)
            XCTAssertEqual(ack.snapshot?.revision, 3)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    @MainActor
    func testWrongSessionCannotBePausedEvenWithCurrentRevision() {
        let manager = PhoneSessionManager()
        manager.trustPeer(deviceId: "fixture", name: "Fixture")
        manager.updateSnapshot(PhoneSessionSnapshot(sessionId: "new-session", isActive: true, revision: 4))
        let command = PhoneSessionCommand(action: .pause, sessionId: "old-session", expectedRevision: 4)
        var result: CommandAcknowledgement?
        manager.executeCommand(command, fromPeer: "fixture") { result = $0 }
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(manager.currentSnapshot.isPaused, false)
    }

    @MainActor
    func testWrapUpDoesNotClaimPersistenceWithoutConnection() {
        let manager = PhoneSessionManager()
        manager.trustPeer(deviceId: "fixture", name: "Fixture")
        var result: CommandAcknowledgement?
        manager.executeCommand(PhoneSessionCommand(action: .wrapUpNotes, sessionId: "missing", notes: "fixture"), fromPeer: "fixture") { result = $0 }
        XCTAssertEqual(result?.success, false)
    }

    @MainActor
    func testEmergencyStopLatchesGateFromPhone() {
        let manager = PhoneSessionManager()
        let phoneId = "paired_phone_1"
        manager.trustPeer(deviceId: phoneId, name: "Test iPhone")
        
        ExecutionGate.shared.resume()
        XCTAssertFalse(ExecutionGate.shared.isStopped)
        
        let stopCmd = PhoneSessionCommand(
            commandId: "cmd_stop_1",
            action: .emergencyStop,
            timestamp: Date().timeIntervalSince1970
        )
        
        let exp = expectation(description: "Stop ack")
        manager.executeCommand(stopCmd, fromPeer: phoneId) { ack in
            XCTAssertTrue(ack.success)
            XCTAssertTrue(ExecutionGate.shared.isStopped)
            XCTAssertEqual(ack.snapshot?.isStopped, true)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        ExecutionGate.shared.resume()
    }

    @MainActor
    func testSpeechDonePacketSerialization() throws {
        let donePacket = Packet(command: "speechDone")
        let data = try JSONEncoder().encode(donePacket)
        let decoded = try JSONDecoder().decode(Packet.self, from: data)
        XCTAssertEqual(decoded.command, "speechDone")
    }

    @MainActor
    func testVoiceLifecycleAndCursorTalkSync() {
        let voice = Voice.shared
        voice.stop()
        XCTAssertEqual(voice.currentLevel, 0.0)

        let engine = CursorEngine()
        XCTAssertEqual(engine.talkLevel(), 0.0)

        // Custom talk level above threshold triggers talking mood in face
        engine.talkLevel = { 0.75 }
        let face = engine.face(in: CGSize(width: 1440, height: 900), now: CACurrentMediaTime())
        XCTAssertEqual(face.talk, 0.75)
        XCTAssertEqual(face.mood, .talking)

        // Stopping voice always resets its visible level.
        voice.stop()
        XCTAssertEqual(voice.currentLevel, 0.0)
    }
}
