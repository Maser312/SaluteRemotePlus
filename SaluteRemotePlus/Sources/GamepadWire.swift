import Foundation
import Network
import CommonCrypto

/// Шифрованный канал "gamepad" к ТВ. Параметры (порт, ключ, IP) приходят от SberCast.
/// Используется TCP length-framed stream, как в протоколе игрового канала.
final class GamepadWire: ObservableObject {
    @Published private(set) var ready = false

    private struct Endpoint { let host: String }

    private let queue = DispatchQueue(label: "SaluteRemotePlus.GamepadWire")
    private var connection: NWConnection?
    private var session: GamepadSession?
    private var key: Data?
    private var iv: Data?
    private var endpoints: [Endpoint] = []
    private var endpointIndex = 0
    private var pending: [(Int32, Bool)] = []
    private var sendInFlight = false
    private var order: UInt32 = 0
    private var generation = 0
    // queue-confined state; never read the @Published property from this queue.
    private var transportReady = false

    func prepare(session: GamepadSession) {
        queue.async {
            self.stopLocked()
            self.session = session
            self.key = Self.decodeKey(session.aesKey)
            self.iv = Self.uuidBytes(session.sessionId)
            self.endpoints = session.ipv4.map { Endpoint(host: $0) }
            self.endpointIndex = 0
            self.order = 0
            self.openNextEndpoint()
        }
    }

    func press(_ code: Int32) {
        queue.async {
            self.pending.append((code, true))
            self.pending.append((code, false))
            self.flushIfReady()
        }
    }

    @discardableResult
    func type(_ text: String) -> [Character] {
        var skipped: [Character] = []
        var codes: [Int32] = []
        for ch in text {
            if let code = KeyMap.code(for: ch) { codes.append(code) } else { skipped.append(ch) }
        }
        queue.async {
            for code in codes {
                self.pending.append((code, true))
                self.pending.append((code, false))
            }
            self.flushIfReady()
        }
        return skipped
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    private func stopLocked() {
        generation += 1
        connection?.cancel()
        connection = nil
        transportReady = false
        setReady(false)
        sendInFlight = false
        pending.removeAll()
        endpoints.removeAll()
        endpointIndex = 0
    }

    private func setReady(_ value: Bool) {
        transportReady = value
        DispatchQueue.main.async { if self.ready != value { self.ready = value } }
    }

    private func openNextEndpoint() {
        guard let session,
              session.port > 0, session.port <= UInt(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(session.port)),
              endpointIndex < endpoints.count else {
            setReady(false)
            return
        }
        let ep = endpoints[endpointIndex]
        let conn = NWConnection(host: NWEndpoint.Host(ep.host), port: port, using: .tcp)
        connection = conn
        generation += 1
        let gen = generation
        var isReady = false

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.connection === conn else { return }
                switch state {
                case .ready:
                    isReady = true
                    self.setReady(true)
                    self.flushIfReady()
                case .failed:
                    self.advance()
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.generation, !isReady else { return }
            self.advance()
        }
    }

    private func advance() {
        connection?.cancel()
        connection = nil
        setReady(false)
        sendInFlight = false
        endpointIndex += 1
        openNextEndpoint()
    }

    private func flushIfReady() {
        guard transportReady, !sendInFlight, !pending.isEmpty,
              let connection, let key, let iv else { return }

        let item = pending.removeFirst()
        let (code, pressed) = item
        let gamepad = Self.field(1, Self.buttonMessage(code: code, pressed: pressed))
        guard let encrypted = Self.aesCBCEncrypt(gamepad, key: key, iv: iv) else {
            pending.removeAll()
            return
        }

        if pressed { order &+= 2 }
        var payload = Data(Self.be32(order))
        payload.append(encrypted)
        var packet = Data(Self.be32(UInt32(payload.count)))
        packet.append(payload)

        sendInFlight = true
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sendInFlight = false
                if error != nil {
                    if pressed { self.order &-= 2 }
                    self.pending.insert(item, at: 0)
                    self.advance()
                } else {
                    self.flushIfReady()
                }
            }
        })
    }

    private static func buttonMessage(code: Int32, pressed: Bool) -> Data {
        var d = Data([0x08])
        d.append(contentsOf: varint(UInt64(UInt32(bitPattern: code))))
        d.append(contentsOf: [0x10, pressed ? 0x01 : 0x00])
        return d
    }

    private static func field(_ number: UInt64, _ bytes: Data) -> Data {
        var d = Data(varint((number << 3) | 2))
        d.append(contentsOf: varint(UInt64(bytes.count)))
        d.append(bytes)
        return d
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }

    private static func uuidBytes(_ s: String) -> Data? {
        guard let u = UUID(uuidString: s) else { return nil }
        var raw = u.uuid
        return withUnsafeBytes(of: &raw) { Data($0) }
    }

    private static func decodeKey(_ s: String) -> Data? {
        let valid = [16, 24, 32]
        if let d = Data(base64Encoded: s), valid.contains(d.count) { return d }
        let hex = s.replacingOccurrences(of: "-", with: "")
        if hex.count % 2 == 0 {
            var d = Data()
            var i = hex.startIndex
            while i < hex.endIndex {
                let n = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<n], radix: 16) else { d = Data(); break }
                d.append(b)
                i = n
            }
            if valid.contains(d.count) { return d }
        }
        if let d = s.data(using: .utf8), valid.contains(d.count) { return d }
        return nil
    }

    private static func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard iv.count == kCCBlockSizeAES128 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let cap = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, i.baseAddress,
                                d.baseAddress, data.count,
                                o.baseAddress, cap, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
