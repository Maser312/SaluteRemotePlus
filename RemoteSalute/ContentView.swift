import SwiftUI

struct ContentView: View {
    @StateObject private var engine = RemoteEngine()
    @State private var showDevicePicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Шапка со статусом и кнопкой сканера
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.selectedDevice?.name ?? "ТВ не выбран")
                        .font(.headline)
                    Text(engine.statusMessage)
                        .font(.caption)
                        .foregroundColor(engine.isConnected ? .green : .secondary)
                }
                Spacer()
                Button(action: { showDevicePicker = true }) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // D-Pad
            ZStack {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 250, height: 250)
                
                VStack {
                    PadButton(icon: "chevron.up") { engine.send(cmd: .up) }
                    Spacer()
                    PadButton(icon: "chevron.down") { engine.send(cmd: .down) }
                }
                .frame(height: 210)
                
                HStack {
                    PadButton(icon: "chevron.left") { engine.send(cmd: .left) }
                    Spacer()
                    PadButton(icon: "chevron.right") { engine.send(cmd: .right) }
                }
                .frame(width: 210)
                
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    engine.send(cmd: .select)
                }) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 75, height: 75)
                        .overlay(Text("OK").bold().foregroundColor(.white))
                }
            }
            
            Spacer()
            
            // Системные клавиши
            HStack(spacing: 30) {
                SystemButton(icon: "arrow.backward", text: "Назад") { engine.send(cmd: .back) }
                SystemButton(icon: "house", text: "Домой") { engine.send(cmd: .home) }
                SystemButton(icon: "speaker.wave.2", text: "Громче") { engine.send(cmd: .volumeUp) }
                SystemButton(icon: "speaker.wave.1", text: "Тише") { engine.send(cmd: .volumeDown) }
            }
            .padding(.bottom, 30)
        }
        .sheet(isPresented: $showDevicePicker) {
            NavigationView {
                List(engine.devices) { device in
                    Button(action: {
                        engine.connectTo(device: device)
                        showDevicePicker = false
                    }) {
                        HStack {
                            Image(systemName: device.peripheral != nil ? "wave.3.right.circle" : "tv")
                                .font(.title3)
                            Text(device.name)
                                .foregroundColor(.primary)
                            Spacer()
                            if engine.selectedDevice?.id == device.id {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                    }
                }
                .navigationTitle("Найденные устройства")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct PadButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Image(systemName: icon)
                .font(.title2.bold())
                .frame(width: 50, height: 50)
                .foregroundColor(.primary)
        }
    }
}

struct SystemButton: View {
    let icon: String
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            action()
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(text).font(.caption2)
            }
            .frame(width: 55, height: 55)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(12)
        }
    }
}
