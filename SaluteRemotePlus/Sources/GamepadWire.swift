import Foundation
import Network
import CommonCrypto

/// Stream transport for the TV Gamepad service returned by LibSberCast.
/// Protocol recovered from the Salute companion: protobuf Gamepad -> AES-128-CBC/PKCS7 -> order -> 4-byte length prefix.
/// The length prefix is Netty-style framing, so the gamepad channel is a TCP stream, not a UDP datagram channel.
final class GamepadWire {
    static let shared = GamepadWire()

    private let queue = DispatchQueue(label: "SaluteRemotePlus.GamepadWire")
    private var connection: NWConnection?
    private var sessionID: String?
    private var key: Data?
    private var iv: Data?
    private var order: UInt32 = 0
    private var ready = false
    private var pending: [(Int, Bool)] = []
    private var endpointCandidates: [String] = []
    private var endpointIndex = 0
    private var currentPort: UInt16 = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var sendInFlight = false

    private init() {}

    func send(command: RemoteCommand, session: GamepadSession?) {
        guard let session else { return }
        queue.async {
            self.prepare(session)
            self.pending.append((command.keyCode, true))
            self.pending.append((command.keyCode, false))
            self.flushIfReady()
        }
    }

    private func prepare(_ session: GamepadSession) {
        if sessionID == session.sessionId,
           connection != nil,
           ready,
           key != nil,
           iv != nil {
            return
        }

        reconnectWorkItem?.cancel()
        connection?.cancel()
        connection = nil
        ready = false
        sendInFlight = false
        sessionID = session.sessionId
        order = 0
        key = decodeKey(session.aesKey)
        iv = uuidBytes(session.sessionId)
        endpointCandidates = session.ipv4
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        endpointIndex = 0
        currentPort = UInt16(exactly: session.port) ?? 0

        guard key != nil, iv != nil, !endpointCandidates.isEmpty, currentPort > 0 else { return }
        openNextEndpoint()
    }

    private func openNextEndpoint() {
        guard endpointIndex < endpointCandidates.count, currentPort > 0 else {
            endpointIndex = 0
            scheduleReconnect()
            return
        }

        let host = endpointCandidates[endpointIndex]
        // The Android companion uses Netty length-field framing. That framing belongs
        // to a reliable byte stream, so use TCP here rather than UDP datagrams.
        let c = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: currentPort)!,
            using: .tcp
        )

        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self else { return }
            self.queue.async {
                guard self.connection === c else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.sendInFlight = false
                    self.flushIfReady()

                case .failed(let error):
                    self.ready = false
                    self.connection = nil
                    self.sendInFlight = false
                    self.endpointIndex += 1
                    _ = error
                    self.openNextEndpoint()

                case .cancelled:
                    self.ready = false
                    self.connection = nil
                    self.sendInFlight = false

                default:
                    break
                }
            }
        }

        connection = c
        c.start(queue: queue)
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.connection == nil, !self.endpointCandidates.isEmpty else { return }
                self.endpointIndex = 0
                self.openNextEndpoint()
            }
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushIfReady() {
        guard ready, connection != nil, !sendInFlight, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        sendButton(code: item.0, pressed: item.1)
    }

    private func sendButton(code: Int, pressed: Bool) {
        guard let connection, let key, let iv else {
            return
        }

        if pressed {
            order &+= 2
        }

        let button = protobufButton(code: code, pressed: pressed)
        let gamepad = protobufField(number: 1, wireType: 2, payload: button)
        guard let encrypted = aesCBCEncrypt(gamepad, key: key, iv: iv) else {
            pending.insert((code, pressed), at: 0)
            return
        }

        var payload = Data()
        payload.append(contentsOf: uint32BE(order))
        payload.append(encrypted)

        var packet = Data()
        packet.append(contentsOf: uint32BE(UInt32(payload.count)))
        packet.append(payload)

        sendInFlight = true
        connection.send(content: packet, contentContext: .defaultMessage, isComplete: true) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.sendInFlight = false
                switch result {
                case .contentProcessed(nil):
                    self.flushIfReady()

                case .contentProcessed(let error?):
                    if pressed { self.order &-= 2 }
                    self.pending.insert((code, pressed), at: 0)
                    self.ready = false
                    self.connection?.cancel()
                    self.connection = nil
                    self.endpointIndex = min(self.endpointIndex + 1, self.endpointCandidates.count)
                    _ = error
                    self.openNextEndpoint()

                case .idempotent:
                    self.flushIfReady()

                @unknown default:
                    self.flushIfReady()
                }
            }
        }
    }

    private func protobufButton(code: Int, pressed: Bool) -> Data {
        var out = Data([0x08])
        let value = UInt64(UInt32(bitPattern: Int32(code)))
        out.append(contentsOf: varint(value))
        out.append(contentsOf: [0x10, pressed ? 0x01 : 0x00])
        return out
    }

    private func protobufField(number: Int, wireType: Int, payload: Data) -> Data {
        var out = Data([UInt8((number << 3) | wireType)])
        out.append(contentsOf: varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    private func varint(_ value: UInt64) -> Data {
        var x = value
        var out = Data()
        repeat {
            var byte = UInt8(x & 0x7f)
            x >>= 7
            if x != 0 { byte |= 0x80 }
            out.append(byte)
        } while x != 0
        return out
    }

    private func uint32BE(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    private func uuidBytes(_ value: String) -> Data? {
        guard let uuid = UUID(uuidString: value) else { return nil }
        var raw = uuid.uuid
        return withUnsafeBytes(of: &raw) { Data($0) }
    }

    private func decodeKey(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value), data.count == kCCKeySizeAES128 else {
            return nil
        }
        return data
    }

    private func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard iv.count == kCCBlockSizeAES128, key.count == kCCKeySizeAES128 else { return nil }

        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0

        let status = output.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { dataBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress,
                            key.count,
                            ivBuf.baseAddress,
                            dataBuf.baseAddress,
                            data.count,
                            outBuf.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        output.count = moved
        return output
    }
}
