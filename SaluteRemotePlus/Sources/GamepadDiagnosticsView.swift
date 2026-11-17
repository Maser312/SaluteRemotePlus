import SwiftUI
import Network
import CommonCrypto
import CryptoKit
import UIKit

private struct DiagnosticCandidate: Identifiable {
    let id: Int
    let transport: NWParameters
    let transportName: String
    let keyMode: String
    let ivMode: String
    let cipherMode: String
    let framing: Bool
    let wrapped: Bool
    let counterMode: Bool

    var title: String {
        "\(transportName) · key:\(keyMode) · iv:\(ivMode) · AES-\(cipherMode) · \(framing ? "length-prefix" : "raw") · \(wrapped ? "protobuf wrapper" : "protobuf raw") · \(counterMode ? "counter" : "no counter")"
    }
}

@MainActor
final class GamepadDiagnostics: ObservableObject {
    @Published private(set) var candidates: [DiagnosticCandidate] = []
    @Published private(set) var index = 0
    @Published private(set) var running = false
    @Published private(set) var waitingForUser = false
    @Published private(set) var connected = false
    @Published private(set) var logs: [String] = []
    @Published private(set) var successDescription: String?
    @Published private(set) var lastError: String?

    private let session: GamepadSession
    private var connection: NWConnection?
    private var generation = 0

    init(session: GamepadSession) { self.session = session }

    var current: DiagnosticCandidate? { candidates.indices.contains(index) ? candidates[index] : nil }
    var progressText: String { candidates.isEmpty ? "Не запущено" : "\(min(index + 1, candidates.count)) / \(candidates.count)" }

    func startFullScan() {
        stop()
        candidates = Self.makeCandidates()
        index = 0
        successDescription = nil
        lastError = nil
        logs.removeAll()
        running = true
        log("Старт: \(candidates.count) вариантов. На ТВ отправляется короткое нажатие RIGHT.")
        runCurrent()
    }

    func stop() {
        generation += 1
        connection?.cancel()
        connection = nil
        running = false
        waitingForUser = false
        connected = false
    }

    func confirmSuccess() {
        guard let candidate = current else { return }
        successDescription = candidate.title
        UserDefaults.standard.set(candidate.title, forKey: "SaluteRemotePlus.workingDiagnosticCandidate")
        log("ПОДТВЕРЖДЕНО ПОЛЬЗОВАТЕЛЕМ: \(candidate.title)")
        stop()
    }

    func skipCurrent() {
        guard running, waitingForUser else { return }
        log("Нет реакции: \(current?.title ?? "неизвестный вариант")")
        connection?.cancel()
        connection = nil
        waitingForUser = false
        connected = false
        index += 1
        if index >= candidates.count {
            running = false
            log("Перебор завершён. Подтверждённого варианта нет.")
        } else {
            runCurrent()
        }
    }

    func copyReport() {
        let header = "SaluteRemotePlus diagnostics\nTV: \(session.ipv4.joined(separator: ", ")): \(session.port)\nService: \(session.serviceVersion)\nSession: \(session.sessionId)\nProgress: \(progressText)\nSuccess: \(successDescription ?? "none")"
        UIPasteboard.general.string = ([header] + logs).joined(separator: "\n")
    }

    private func runCurrent() {
        guard running, let candidate = current else { return }
        generation += 1
        let gen = generation
        connected = false
        waitingForUser = false
        lastError = nil
        log("Проверка \(index + 1)/\(candidates.count): \(candidate.title)")
        guard let host = session.ipv4.first,
              session.port > 0, session.port <= UInt(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(session.port)),
              let packets = makeTestPackets(candidate: candidate) else {
            lastError = "Не удалось подготовить адрес, порт, AES-ключ или IV"
            log("ОШИБКА: \(lastError!)")
            waitingForUser = true
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: candidate.transport)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
                guard let self, gen == self.generation, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.connected = true
                    self.sendPackets(packets, through: conn, generation: gen)
                case .failed(let error):
                    self.lastError = error.localizedDescription
                    self.log("Соединение не удалось: \(error.localizedDescription)")
                    self.waitingForUser = true
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func makeTestPackets(candidate: DiagnosticCandidate) -> [Data]? {
        guard let key = decodeKey(session.aesKey, mode: candidate.keyMode),
              let iv = decodeIV(session.sessionId, mode: candidate.ivMode) else { return nil }
        func makePacket(code: UInt8, pressed: Bool, order: UInt32) -> Data? {
            var body = Data()
            if candidate.counterMode { body.append(contentsOf: be32(order)) }
            let button = Data([0x08, code, 0x10, pressed ? 0x01 : 0x00])
            if candidate.wrapped {
                body.append(contentsOf: [0x0A, UInt8(button.count)])
                body.append(button)
            } else {
                body.append(button)
            }
            guard let encrypted = crypt(body, key: key, iv: iv, cipherMode: candidate.cipherMode) else { return nil }
            var packet = Data()
            if candidate.framing { packet.append(contentsOf: be32(UInt32(encrypted.count))) }
            packet.append(encrypted)
            return packet
        }
        guard let down = makePacket(code: 0x16, pressed: true, order: 1),
              let up = makePacket(code: 0x16, pressed: false, order: 2) else { return nil }
        return [down, up]
    }

    private func sendPackets(_ packets: [Data], through connection: NWConnection?, generation: Int) {
        guard let connection, !packets.isEmpty else { return }
        func send(_ index: Int) {
            guard index < packets.count else {
                Task { @MainActor in
                    guard generation == self.generation else { return }
                    self.waitingForUser = true
                    self.log("Пакеты переданы сетевому стеку. Это НЕ подтверждение обработки телевизором.")
                }
                return
            }
            connection.send(content: packets[index], completion: .contentProcessed { error in
                if let error {
                    Task { @MainActor in
                        guard generation == self.generation else { return }
                        self.lastError = error.localizedDescription
                        self.log("Ошибка отправки: \(error.localizedDescription)")
                        self.waitingForUser = true
                    }
                } else {
                    send(index + 1)
                }
            })
        }
        send(0)
    }

    private func decodeKey(_ raw: String, mode: String) -> Data? {
        switch mode {
        case "base64": return Data(base64Encoded: raw)
        case "hex":
            let s = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            guard s.count % 2 == 0 else { return nil }
            var d = Data(); var i = s.startIndex
            while i < s.endIndex {
                let n = s.index(i, offsetBy: 2)
                guard let b = UInt8(s[i..<n], radix: 16) else { return nil }
                d.append(b); i = n
            }
            return d
        case "utf8": return raw.data(using: .utf8)
        case "sha256": return Data(SHA256.hash(data: Data(raw.utf8)))
        default: return nil
        }
    }

    private func decodeIV(_ raw: String, mode: String) -> Data? {
        switch mode {
        case "uuidBytes":
            guard let u = UUID(uuidString: raw) else { return nil }
            var v = u.uuid
            return withUnsafeBytes(of: &v) { Data($0) }
        case "uuidUTF8": return Data(raw.utf8.prefix(16))
        case "uuidHex":
            let s = raw.replacingOccurrences(of: "-", with: "")
            guard s.count == 32 else { return nil }
            var d = Data(); var i = s.startIndex
            while i < s.endIndex {
                let n = s.index(i, offsetBy: 2)
                guard let b = UInt8(s[i..<n], radix: 16) else { return nil }
                d.append(b); i = n
            }
            return d
        case "zero": return Data(repeating: 0, count: 16)
        case "sha256": return Data(SHA256.hash(data: Data(raw.utf8)).prefix(16))
        default: return nil
        }
    }

    private func crypt(_ input: Data, key: Data, iv: Data, cipherMode: String) -> Data? {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else { return nil }
        var output = Data(count: input.count + 32)
        var moved = 0
        let options = CCOptions(kCCOptionPKCS7Padding | (cipherMode == "ECB" ? kCCOptionECBMode : 0))
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { data in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                k.baseAddress, key.count, v.baseAddress,
                                data.baseAddress, input.count, out.baseAddress,
                                output.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = moved
        return output
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    private func log(_ value: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(stamp)] \(value)")
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }

    private static func makeCandidates() -> [DiagnosticCandidate] {
        var result: [DiagnosticCandidate] = []
        var id = 0
        let transports: [(NWParameters, String)] = [(.tcp, "TCP"), (.udp, "UDP")]
        for (transport, transportName) in transports {
            for key in ["base64", "hex", "utf8", "sha256"] {
                for iv in ["uuidBytes", "uuidUTF8", "uuidHex", "zero", "sha256"] {
                    for cipher in ["CBC", "ECB"] {
                        for framing in [true, false] {
                            for wrapped in [true, false] {
                                for counter in [true, false] {
                                    result.append(DiagnosticCandidate(id: id, transport: transport,
                                        transportName: transportName, keyMode: key, ivMode: iv,
                                        cipherMode: cipher, framing: framing,
                                        wrapped: wrapped, counterMode: counter))
                                    id += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}

struct GamepadDiagnosticsView: View {
    let session: GamepadSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diagnostics: GamepadDiagnostics
    @State private var showSuccess = false

    init(session: GamepadSession) {
        self.session = session
        _diagnostics = StateObject(wrappedValue: GamepadDiagnostics(session: session))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        Text("Сессия телевизора").font(.headline)
                        infoRow("Адреса", session.ipv4.joined(separator: ", "))
                        infoRow("Порт", String(session.port))
                        infoRow("Версия сервиса", session.serviceVersion)
                        infoRow("Session ID", session.sessionId)
                        infoRow("Длина ключа", "\(session.aesKey.utf8.count) символов")
                        infoRow("Состояние TCP", diagnostics.connected ? "Подключено" : "Не подключено")
                    }
                    .padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Автопоиск протокола").font(.headline)
                        Text("Перебираются TCP/UDP, варианты AES-ключа и IV, упаковка protobuf и framing. Для каждого варианта отправляется одно короткое нажатие RIGHT и сразу отпускание.")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                        Text("Важно: iOS может подтвердить только передачу пакета в сеть. Ответ телевизора о выполнении команды не предусмотрен в известном протоколе, поэтому реакцию нужно подтвердить глазами.")
                            .font(.caption).foregroundStyle(.orange)
                        HStack {
                            Text(diagnostics.progressText).font(.system(.subheadline, design: .monospaced))
                            Spacer()
                            if diagnostics.running { ProgressView().tint(.white) }
                        }
                        if let current = diagnostics.current {
                            Text(current.title).font(.caption.monospaced()).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if let error = diagnostics.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        HStack {
                            Button("Запустить полный перебор") { diagnostics.startFullScan() }
                                .buttonStyle(.borderedProminent).disabled(diagnostics.running)
                            Button("Стоп") { diagnostics.stop() }
                                .buttonStyle(.bordered).disabled(!diagnostics.running)
                        }
                        if diagnostics.waitingForUser && diagnostics.successDescription == nil {
                            Text("Посмотри на телевизор: изменился ли фокус/экран после тестового RIGHT?")
                                .font(.subheadline.weight(.semibold))
                            HStack {
                                Button("Сработало!") {
                                    diagnostics.confirmSuccess()
                                    showSuccess = true
                                }.buttonStyle(.borderedProminent).tint(.green)
                                Button("Нет, дальше") { diagnostics.skipCurrent() }
                                    .buttonStyle(.bordered).tint(.red)
                            }
                        }
                        if let found = diagnostics.successDescription {
                            Label("Найден кандидат", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green).font(.headline)
                            Text(found).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Журнал").font(.headline)
                            Spacer()
                            Button("Копировать") { diagnostics.copyReport() }
                                .font(.caption)
                        }
                        ForEach(Array(diagnostics.logs.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
                        }
                    }
                    .padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Диагностика пульта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Закрыть") { diagnostics.stop(); dismiss() }
                }
            }
            .preferredColorScheme(.dark)
            .alert("Команда сработала", isPresented: $showSuccess) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text("Кандидат сохранён в журнале диагностики. Перед переносом в основной пульт его нужно проверить повторно.")
            }
            .onDisappear { diagnostics.stop() }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption)
    }
}
