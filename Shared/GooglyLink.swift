import Foundation
import Network
import CryptoKit
import Security

/// Everything the Mac and the iPhone agree on: the Bonjour service name,
/// what a "face update" looks like, and how lines of JSON travel over TCP.
public enum GooglyService {
    public static let type = "_googly._tcp"
}

public enum Mood: String, Codable, CaseIterable, Sendable {
    case listening, resting, thinking, talking, pointing, happy, sleepy

    public var title: String { rawValue.capitalized }
}

/// What the phone should show right now.
public struct FaceState: Codable, Equatable, Sendable {
    /// Where the eyes look. x: -1 left … 1 right. y: -1 up … 1 down.
    public var gazeX: Double
    public var gazeY: Double
    public var mood: Mood
    /// Voice level, 0…1. Drives the talking bounce.
    public var talk: Double

    public init(gazeX: Double = 0, gazeY: Double = 0, mood: Mood = .listening, talk: Double = 0) {
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.mood = mood
        self.talk = talk
    }
}

// MARK: - Secure Transport & CryptoKit Pairing

public enum SecureTransportError: Error, Equatable, Sendable {
    case replayDetected
    case authenticationFailed
    case unauthorizedPeer
    case decryptionFailed
    case invalidSequence
    case invalidKey
}

public struct PairingRequest: Codable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var publicKeyData: Data
    public var salt: Data

    public init(deviceId: String, deviceName: String, publicKeyData: Data, salt: Data) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKeyData = publicKeyData
        self.salt = salt
    }

    public func sasCode(with responderKey: Curve25519.KeyAgreement.PublicKey) -> String {
        var hashData = Data()
        hashData.append(publicKeyData)
        hashData.append(responderKey.rawRepresentation)
        hashData.append(salt)
        let digest = SHA256.hash(data: hashData)
        let num = digest.withUnsafeBytes { $0.load(as: UInt32.self) }
        return String(format: "%06d", num % 1_000_000)
    }
}

public struct PairingResponse: Codable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var publicKeyData: Data
    public var salt: Data

    public init(deviceId: String, deviceName: String, publicKeyData: Data, salt: Data) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKeyData = publicKeyData
        self.salt = salt
    }

    public func sasCode(with initiatorKey: Curve25519.KeyAgreement.PublicKey) -> String {
        var hashData = Data()
        hashData.append(initiatorKey.rawRepresentation)
        hashData.append(publicKeyData)
        hashData.append(salt)
        let digest = SHA256.hash(data: hashData)
        let num = digest.withUnsafeBytes { $0.load(as: UInt32.self) }
        return String(format: "%06d", num % 1_000_000)
    }
}

public struct EncryptedFrame: Codable, Sendable {
    public var senderId: String
    public var sequence: UInt64
    public var ciphertext: Data
    public var tag: Data
    public var nonce: Data

    public init(senderId: String, sequence: UInt64, ciphertext: Data, tag: Data, nonce: Data) {
        self.senderId = senderId
        self.sequence = sequence
        self.ciphertext = ciphertext
        self.tag = tag
        self.nonce = nonce
    }
}

public final class SecureSession: @unchecked Sendable {
    public let peerId: String
    public let selfId: String
    public let symmetricKey: SymmetricKey
    private let incomingKey: SymmetricKey
    private let lock = NSLock()
    private var outgoingSequence: UInt64 = 0
    private var incomingSequence: UInt64 = 0

    public init(selfId: String, peerId: String, symmetricKey: SymmetricKey) {
        self.selfId = selfId
        self.peerId = peerId
        self.symmetricKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: symmetricKey, info: Data("BlueyFrames:\(selfId)>\(peerId)".utf8), outputByteCount: 32)
        self.incomingKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: symmetricKey, info: Data("BlueyFrames:\(peerId)>\(selfId)".utf8), outputByteCount: 32)
    }

    public func encrypt(plaintext: Data) throws -> EncryptedFrame {
        lock.lock()
        outgoingSequence += 1
        let seq = outgoingSequence
        lock.unlock()

        let nonce = ChaChaPoly.Nonce()
        let aad = Data("\(selfId):\(seq)".utf8)
        let sealed = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: nonce, authenticating: aad)
        return EncryptedFrame(senderId: selfId, sequence: seq, ciphertext: sealed.ciphertext, tag: sealed.tag, nonce: nonce.withUnsafeBytes { Data($0) })
    }

    public func decrypt(frame: EncryptedFrame) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard frame.senderId == peerId else { throw SecureTransportError.unauthorizedPeer }
        guard frame.sequence > incomingSequence else {
            throw SecureTransportError.replayDetected
        }

        let nonce = try ChaChaPoly.Nonce(data: frame.nonce)
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: frame.ciphertext, tag: frame.tag)
        let opened = try ChaChaPoly.open(sealedBox, using: incomingKey, authenticating: Data("\(frame.senderId):\(frame.sequence)".utf8))
        incomingSequence = frame.sequence
        return opened
    }
}

public final class SecureDeviceIdentity: @unchecked Sendable {
    public let deviceId: String
    public let deviceName: String
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    public init(deviceName: String, deviceId: String = UUID().uuidString, privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.privateKey = privateKey
    }

    public func makePairingRequest() -> PairingRequest {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PairingRequest(
            deviceId: deviceId,
            deviceName: deviceName,
            publicKeyData: publicKey.rawRepresentation,
            salt: salt
        )
    }

    public func respondToPairing(request: PairingRequest) throws -> PairingResponse {
        return PairingResponse(
            deviceId: deviceId,
            deviceName: deviceName,
            publicKeyData: publicKey.rawRepresentation,
            salt: request.salt
        )
    }

    public func establishSession(peerId: String, peerKey: Curve25519.KeyAgreement.PublicKey, salt: Data = Data("BlueyTransportSaltV2".utf8)) throws -> SecureSession {
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: "BlueySessionFramesV2".data(using: .utf8)!,
            outputByteCount: 32
        )
        return SecureSession(selfId: deviceId, peerId: peerId, symmetricKey: symmetricKey)
    }
}

/// Private identities and approved peer public keys are local Keychain records.
public enum SecureIdentityStore {
    private static let service = "co.visionairy.bluey.transport.v2"
    private static func read(_ name: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    @discardableResult private static func write(_ name: String, _ data: Data) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    public static func identity(deviceName: String) -> SecureDeviceIdentity {
        if let data = read("identity"), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            let id = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
            return SecureDeviceIdentity(deviceName: deviceName, deviceId: id, privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        _ = write("identity", key.rawRepresentation)
        let id = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        return SecureDeviceIdentity(deviceName: deviceName, deviceId: id, privateKey: key)
    }
    public static func isTrusted(peerId: String, publicKey: Data) -> Bool { read("peer:" + peerId) == publicKey }
    @discardableResult public static func trust(peerId: String, publicKey: Data) -> Bool { write("peer:" + peerId, publicKey) }
}

// MARK: - Controller Protocol Models

public struct AgentApprovalRequest: Codable, Equatable, Sendable {
    public var id: String
    public var actionName: String
    public var targetDescription: String
    public var details: String?
    public var requestedAt: Double

    public init(id: String, actionName: String, targetDescription: String, details: String? = nil, requestedAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.actionName = actionName
        self.targetDescription = targetDescription
        self.details = details
        self.requestedAt = requestedAt
    }
}

public struct PhoneSessionSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var subjectId: String?
    public var topicId: String?
    public var subjectLabel: String?
    public var topicLabel: String?
    public var plannedSeconds: Int
    public var elapsedSeconds: Int
    public var isPaused: Bool
    public var isActive: Bool
    public var startedAt: Double?
    public var revision: Int
    public var syncStatus: String
    public var isStopped: Bool
    public var autonomyMode: String
    public var pendingApproval: AgentApprovalRequest?
    public var lastEventId: String?
    public var agentSteps: [String]
    public var agentStatus: String?
    public var agentBusy: Bool

    public init(
        sessionId: String? = nil,
        subjectId: String? = nil,
        topicId: String? = nil,
        subjectLabel: String? = nil,
        topicLabel: String? = nil,
        plannedSeconds: Int = 1500,
        elapsedSeconds: Int = 0,
        isPaused: Bool = false,
        isActive: Bool = false,
        startedAt: Double? = nil,
        revision: Int = 0,
        syncStatus: String = "disconnected",
        isStopped: Bool = false,
        autonomyMode: String = "confirmConsequences",
        pendingApproval: AgentApprovalRequest? = nil,
        lastEventId: String? = nil,
        agentSteps: [String] = [],
        agentStatus: String? = nil,
        agentBusy: Bool = false
    ) {
        self.sessionId = sessionId
        self.subjectId = subjectId
        self.topicId = topicId
        self.subjectLabel = subjectLabel
        self.topicLabel = topicLabel
        self.plannedSeconds = plannedSeconds
        self.elapsedSeconds = elapsedSeconds
        self.isPaused = isPaused
        self.isActive = isActive
        self.startedAt = startedAt
        self.revision = revision
        self.syncStatus = syncStatus
        self.isStopped = isStopped
        self.autonomyMode = autonomyMode
        self.pendingApproval = pendingApproval
        self.lastEventId = lastEventId
        self.agentSteps = agentSteps
        self.agentStatus = agentStatus
        self.agentBusy = agentBusy
    }
}

public struct PhoneSessionCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable, Hashable {
        case start
        case pause
        case resume
        case finish
        case abandon
        case emergencyStop
        case resumeExecution
        case checkFocus
        case lockWindow
        case openNotes
        case requestDayPlan
        case approveAction
        case declineAction
        case wrapUpNotes
        case readSessionHistory
    }

    public var commandId: String
    public var action: Action
    public var sessionId: String?
    public var expectedRevision: Int?
    public var subjectId: String?
    public var topicId: String?
    public var subjectLabel: String?
    public var topicLabel: String?
    public var plannedSeconds: Int?
    public var approvalId: String?
    public var notes: String?
    public var nextStep: String?
    public var cursor: String?
    public var timestamp: Double

    public init(
        commandId: String = UUID().uuidString,
        action: Action,
        sessionId: String? = nil,
        expectedRevision: Int? = nil,
        subjectId: String? = nil,
        topicId: String? = nil,
        subjectLabel: String? = nil,
        topicLabel: String? = nil,
        plannedSeconds: Int? = nil,
        approvalId: String? = nil,
        notes: String? = nil,
        nextStep: String? = nil,
        cursor: String? = nil,
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.commandId = commandId
        self.action = action
        self.sessionId = sessionId
        self.expectedRevision = expectedRevision
        self.subjectId = subjectId
        self.topicId = topicId
        self.subjectLabel = subjectLabel
        self.topicLabel = topicLabel
        self.plannedSeconds = plannedSeconds
        self.approvalId = approvalId
        self.notes = notes
        self.nextStep = nextStep
        self.cursor = cursor
        self.timestamp = timestamp
    }
}

public struct StudyHistoryItem: Codable, Identifiable, Sendable {
    public let id: String
    public var subjectName: String?
    public var subjectId: String?
    public var topicTitle: String?
    public var startTime: Double?
    public var endTime: Double?
    public var durationSeconds: Int?
    public var notes: String?
    public var date: String?
    public var source: String?
}

public struct StudyHistoryPage: Codable, Sendable {
    public var sessions: [StudyHistoryItem]
    public var nextCursor: String?
}

public struct CommandAcknowledgement: Codable, Sendable {
    public var commandId: String
    public var success: Bool
    public var errorMessage: String?
    public var snapshot: PhoneSessionSnapshot?
    public var history: StudyHistoryPage?

    public init(commandId: String, success: Bool, errorMessage: String? = nil, snapshot: PhoneSessionSnapshot? = nil, history: StudyHistoryPage? = nil) {
        self.commandId = commandId
        self.success = success
        self.errorMessage = errorMessage
        self.snapshot = snapshot
        self.history = history
    }
}

public struct Packet: Codable, Sendable {
    public var face: FaceState?
    /// Sent once by each side after connecting, with a device name.
    public var hello: String?
    /// Voice volume 0…1. The Mac shares it, the phone sets it.
    public var volume: Double?
    /// A request or event: "testVoice" (phone→Mac), "playing"/"done" (phone→Mac), "stopSpeech" (Mac→phone).
    public var command: String?
    /// Speech audio (mp3, base64) for the phone to play.
    public var audio: String?
    /// Which speech an audio packet or a playing/done event belongs to.
    public var speech: Int?
    /// Pairs a request with its reply (tool calls, realtime tokens).
    public var callID: String?
    /// Tool name for a "tool" request.
    public var tool: String?
    /// Free text: tool arguments or output, a token, a caption.
    public var text: String?
    /// A JPEG (base64) that goes with a tool result.
    public var image: String?

    // Secure transport and controller fields:
    public var encryptedFrame: EncryptedFrame?
    public var pairingRequest: PairingRequest?
    public var pairingResponse: PairingResponse?
    public var sessionSnapshot: PhoneSessionSnapshot?
    public var commandAck: CommandAcknowledgement?
    public var sessionCommand: PhoneSessionCommand?

    public init(face: FaceState? = nil, hello: String? = nil, volume: Double? = nil, command: String? = nil,
                audio: String? = nil, speech: Int? = nil, callID: String? = nil, tool: String? = nil,
                text: String? = nil, image: String? = nil, encryptedFrame: EncryptedFrame? = nil,
                pairingRequest: PairingRequest? = nil, pairingResponse: PairingResponse? = nil,
                sessionSnapshot: PhoneSessionSnapshot? = nil, commandAck: CommandAcknowledgement? = nil, sessionCommand: PhoneSessionCommand? = nil) {
        self.face = face
        self.hello = hello
        self.volume = volume
        self.command = command
        self.audio = audio
        self.speech = speech
        self.callID = callID
        self.tool = tool
        self.text = text
        self.image = image
        self.encryptedFrame = encryptedFrame
        self.pairingRequest = pairingRequest
        self.pairingResponse = pairingResponse
        self.sessionSnapshot = sessionSnapshot
        self.commandAck = commandAck
        self.sessionCommand = sessionCommand
    }
}

public extension NWParameters {
    static var googly: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// Newline-delimited JSON over one NWConnection. All callbacks run on the main queue.
public final class LineConnection {
    public let connection: NWConnection
    public var onPacket: ((Packet) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?

    private var buffer = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onState?(state)
        }
        connection.start(queue: .main)
        receive()
    }

    public func send(_ packet: Packet) {
        guard var data = try? encoder.encode(packet) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                guard self.buffer.count <= 2 * 1024 * 1024 else { self.connection.cancel(); return }
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<newline]
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    if let packet = try? self.decoder.decode(Packet.self, from: line) {
                        self.onPacket?(packet)
                    }
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }
}
