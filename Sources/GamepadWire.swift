import Foundation
import Network
import CommonCrypto

/// Transport for the TV Gamepad service.
/// The gamepad channel is a UDP session returned by SberCast after pairing.
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

        connection?.cancel()
        connection = nil
        ready = false
        sessionID = session.sessionId
        order = 0
        key = decodeKey(session.aesKey)
        iv = uuidBytes(session.sessionId)
        endpointCandidates = session.ipv4
        endpointIndex = 0

        guard key != nil, iv != nil, !endpointCandidates.isEmpty else { return }
        openNextEndpoint(port: session.port)
    }

    private func openNextEndpoint(port: UInt) {
        guard endpointIndex < endpointCandidates.count,
              let rawPort = UInt16(exactly: port),
              let host = endpointCandidates[safe: endpointIndex] else { return }

        let c = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: rawPort)!,
            using: .udp
        )

        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.ready = true
                    self.flushIfReady()
                case .failed, .cancelled:
                    guard self.connection === c else { return }
                    self.ready = false
                    self.connection = nil
                    self.endpointIndex += 1
                    self.openNextEndpoint(port: port)
                default:
                    break
                }
            }
        }

        connection = c
        c.start(queue: queue)
    }

    private func flushIfReady() {
        guard ready, connection != nil else { return }
        while !pending.isEmpty {
            let item = pending.removeFirst()
            sendButton(code: item.0, pressed: item.1)
        }
    }

    private func sendButton(code: Int, pressed: Bool) {
        guard let connection, let key, let iv else { return }

        order &+= 1
        let button = protobufButton(code: code, pressed: pressed)
        let gamepad = protobufField(number: 1, wireType: 2, payload: button)

        var plain = Data()
        plain.append(contentsOf: uint32BE(order))
        plain.append(gamepad)

        guard let encrypted = aesCBCEncrypt(plain, key: key, iv: iv) else { return }

        var packet = Data()
        packet.append(contentsOf: uint32BE(UInt32(encrypted.count)))
        packet.append(encrypted)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.queue.async {
                    self?.ready = false
                    self?.connection?.cancel()
                }
            }
        })
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
        if let d = Data(base64Encoded: value), [16, 24, 32].contains(d.count) { return d }
        let normalized = value.replacingOccurrences(of: "-", with: "")
        if let d = Data(hex: normalized), [16, 24, 32].contains(d.count) { return d }
        return nil
    }

    private func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard iv.count == kCCBlockSizeAES128,
              [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else { return nil }

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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
