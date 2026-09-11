import Foundation
import Network
import CommonCrypto

final class GamepadWire: ObservableObject {
    @Published private(set) var ready = false

    private let queue = DispatchQueue(label: "SaluteRemotePlus.GamepadWire")
    private var connection: NWConnection?
    private var session: GamepadSession?
    private var endpointCandidates: [NWEndpoint] = []
    private var endpointIndex = 0
    private var pending: [(Int32, Bool)] = []
    private var sendInFlight = false
    private var order: UInt32 = 0

    func prepare(session: GamepadSession) {
        queue.async {
            self.stopLocked()
            self.session = session
            self.endpointCandidates = session.ipv4.compactMap { host in
                NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(session.port)))
            }
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

    func stop() {
        queue.async { self.stopLocked() }
    }

    private func stopLocked() {
        connection?.cancel()
        connection = nil
        ready = false
        sendInFlight = false
        pending.removeAll()
        endpointCandidates.removeAll()
        endpointIndex = 0
    }

    private func openNextEndpoint() {
        guard endpointIndex < endpointCandidates.count else {
            ready = false
            return
        }
        guard let endpoint = endpointCandidates[safe: endpointIndex] else { return }

        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.ready = true
                    self.flushIfReady()
                case .failed:
                    self.ready = false
                    if self.connection === conn {
                        self.connection = nil
                        self.endpointIndex += 1
                        self.openNextEndpoint()
                    }
                case .cancelled:
                    self.ready = false
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func flushIfReady() {
        guard ready, !sendInFlight, !pending.isEmpty,
              let connection, let session,
              let item = pending.first else { return }

        pending.removeFirst()
        let (code, pressed) = item
        let inner = protobufButton(code: code, pressed: pressed)
        let gamepad = fieldBytes(field: 1, bytes: inner)
        let encrypted: Data
        do {
            encrypted = try aesCBCEncrypt(gamepad, key: session.aesKey, iv: session.sessionId)
        } catch {
            pending.insert(item, at: 0)
            ready = false
            connection.cancel()
            self.connection = nil
            return
        }

        if pressed {
            order &+= 2
        }
        var payload = Data()
        payload.append(contentsOf: uint32BE(order))
        payload.append(encrypted)

        var packet = Data()
        packet.append(contentsOf: uint32BE(UInt32(payload.count)))
        packet.append(payload)

        sendInFlight = true
        connection.send(
            content: packet,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.sendInFlight = false
                    if let error {
                        if pressed { self.order &-= 2 }
                        self.pending.insert(item, at: 0)
                        self.ready = false
                        self.connection?.cancel()
                        self.connection = nil
                        self.endpointIndex = min(
                            self.endpointIndex + 1,
                            self.endpointCandidates.count
                        )
                        _ = error
                        self.openNextEndpoint()
                    } else {
                        self.flushIfReady()
                    }
                }
            }
        )
    }

    private func protobufButton(code: Int32, pressed: Bool) -> Data {
        var data = Data()
        data.append(0x08)
        data.append(contentsOf: varint(UInt64(bitPattern: Int64(code))))
        data.append(0x10)
        data.append(pressed ? 0x01 : 0x00)
        return data
    }

    private func fieldBytes(field: UInt64, bytes: Data) -> Data {
        var data = Data()
        data.append(contentsOf: varint((field << 3) | 2))
        data.append(contentsOf: varint(UInt64(bytes.count)))
        data.append(bytes)
        return data
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }

    private func uint32BE(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }

    private func aesCBCEncrypt(_ data: Data, key: Data, iv: UUID) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw WireError.invalidKey }
        var uuid = iv.uuid
        let ivData = withUnsafeBytes(of: &uuid) { Data($0) }
        guard ivData.count == kCCBlockSizeAES128 else { throw WireError.invalidIV }

        let padded = pkcs7Pad(data, blockSize: kCCBlockSizeAES128)
        var output = Data(count: padded.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            padded.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyPtr.baseAddress,
                            key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress,
                            padded.count,
                            outPtr.baseAddress,
                            output.count,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw WireError.crypto(status) }
        output.removeSubrange(outLength..<output.count)
        return output
    }

    private func pkcs7Pad(_ data: Data, blockSize: Int) -> Data {
        let pad = blockSize - (data.count % blockSize)
        var result = data
        result.append(contentsOf: repeatElement(UInt8(pad), count: pad))
        return result
    }

    private enum WireError: Error {
        case invalidKey
        case invalidIV
        case crypto(CCCryptorStatus)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
