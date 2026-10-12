import XCTest
import CryptoKit
@testable import GooglyShared
@testable import GooglyMac

final class PhoneTransportTests: XCTestCase {
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
}
