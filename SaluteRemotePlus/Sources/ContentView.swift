import SwiftUI
import JazzSDK

struct ContentView: View {
    @StateObject private var remote = SberCastRemote()

    var body: some View {
        NavigationStack {
            Group {
                if remote.session != nil {
                    RemotePadView(remote: remote)
                } else {
                    deviceView
                }
            }
            .navigationTitle("Salute Remote+")
            .task { remote.start() }
        }
    }

    private var deviceView: some View {
        VStack(spacing: 18) {
            Text(remote.status).font(.headline)
            if let error = remote.error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            List(remote.devices, id: \.id) { device in
                Button {
                    remote.connect(device)
                } label: {
                    VStack(alignment: .leading) {
                        Text(device.name).font(.headline)
                        Text(device.product).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if remote.needsPin {
                VStack(spacing: 10) {
                    TextField("Код с ТВ", text: $remote.pin)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button("Подтвердить") { remote.confirmPIN() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }
}

struct RemotePadView: View {
    @ObservedObject var remote: SberCastRemote

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("⏻") { send(.power) }
                Spacer()
                Button("⌂") { send(.home) }
                Button("↩") { send(.back) }
            }
            .font(.title2)

            VStack(spacing: 8) {
                Button("▲") { send(.up) }
                    .buttonStyle(.borderedProminent)
                HStack(spacing: 8) {
                    Button("◀") { send(.left) }
                    Button("OK") { send(.ok) }
                    Button("▶") { send(.right) }
                }
                .buttonStyle(.borderedProminent)
                Button("▼") { send(.down) }
                    .buttonStyle(.borderedProminent)
            }
            .font(.title)

            HStack(spacing: 12) {
                Button("−") { send(.volumeDown) }
                Button("🔇") { send(.mute) }
                Button("+") { send(.volumeUp) }
            }
            .buttonStyle(.borderedProminent)

            Button("⌕ Поиск") { send(.search) }
                .buttonStyle(.bordered)

            Text(remote.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func send(_ command: RemoteCommand) {
        GamepadWire.shared.send(command: command, session: remote.session)
    }
}
