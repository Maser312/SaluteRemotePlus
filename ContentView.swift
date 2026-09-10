import SwiftUI

struct ContentView: View {
    @StateObject private var engine = RemoteEngine()
    @State private var tvIP: String = "192.168.1."
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                HStack {
                    TextField("IP телевизора", text: $tvIP)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                    
                    Button("Подключить") {
                        engine.connect(ip: tvIP.trimmingCharacters(in: .whitespaces))
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Text(engine.statusMessage)
                    .font(.caption)
                    .foregroundColor(engine.isConnected ? .green : .secondary)
            }
            .padding(.horizontal)
            
            Spacer()
            
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
                
                Button(action: { triggerHaptic(); engine.send(cmd: .select) }) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 75, height: 75)
                        .overlay(Text("OK").bold().foregroundColor(.white))
                }
            }
            
            Spacer()
            
            HStack(spacing: 30) {
                SystemButton(icon: "arrow.backward", text: "Назад") { engine.send(cmd: .back) }
                SystemButton(icon: "house", text: "Домой") { engine.send(cmd: .home) }
                SystemButton(icon: "speaker.wave.2", text: "Громче") { engine.send(cmd: .volumeUp) }
                SystemButton(icon: "speaker.wave.1", text: "Тише") { engine.send(cmd: .volumeDown) }
            }
            .padding(.bottom, 30)
        }
        .padding(.top)
    }
    
    private func triggerHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                Image(systemName: icon)
                    .font(.title3)
                Text(text)
                    .font(.caption2)
            }
            .frame(width: 55, height: 55)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(12)
        }
    }
}
