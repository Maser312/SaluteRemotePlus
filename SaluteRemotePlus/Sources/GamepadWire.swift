import Foundation
import Network
import CommonCrypto

/// Gamepad transport reconstructed from the supplied Salute Companion APK.
/// protobuf Gamepad -> order(uint32 BE) -> AES-CBC/PKCS7 -> length(uint32 BE) -> UDP.
final class GamepadWire {
    static let shared = GamepadWire()
    private let queue = DispatchQueue(label: "SaluteRemotePlus.GamepadWire")
    private var connection: NWConnection?
    private var sessionID: String?
    private var key: Data?
    private var iv: Data?
    private var order: UInt32 = 0

    private init() {}

    func send(command: RemoteCommand, session: GamepadSession?) {
        guard let session else { return }
        queue.async {
            self.prepare(session)
            self.sendButton(code: command.keyCode, pressed: true)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(45)) {
                self.sendButton(code: command.keyCode, pressed: false)
            }
        }
    }

    private func prepare(_ session: GamepadSession) {
        if sessionID == session.sessionId, connection != nil { return }
        connection?.cancel()
        connection = nil
        sessionID = session.sessionId
        order = 0
        key = decodeKey(session.aesKey)
        iv = uuidBytes(session.sessionId)
        guard let host = session.ipv4.first,
              let port = NWEndpoint.Port(rawValue: UInt16(session.port)) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        c.start(queue: queue)
        connection = c
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
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func protobufButton(code: Int, pressed: Bool) -> Data {
        var out = Data([0x08])
        let value = UInt64(UInt32(bitPattern: Int32(code)))
        out.append(contentsOf: varint(value))
        if pressed { out.append(contentsOf: [0x10, 0x01]) }
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
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }

    private func uuidBytes(_ value: String) -> Data? {
        guard let uuid = UUID(uuidString: value) else { return nil }
        var raw = uuid.uuid
        return Data(bytes: &raw, count: 16)
    }

    private func decodeKey(_ value: String) -> Data? {
        if let d = Data(base64Encoded: value), [16, 24, 32].contains(d.count) { return d }
        let normalized = value.replacingOccurrences(of: "-", with: "")
        if let d = Data(hex: normalized), [16, 24, 32].contains(d.count) { return d }
        return nil
    }

    private func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard iv.count == kCCBlockSizeAES128, [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { dataBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBuf.baseAddress, key.count, ivBuf.baseAddress, dataBuf.baseAddress, data.count, outBuf.baseAddress, output.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = moved
        return output
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
