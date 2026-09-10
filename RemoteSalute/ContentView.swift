import SwiftUI

struct ContentView: View {
    @StateObject private var engine = RemoteEngine()
    @State private var showDevicePicker = false
    @State private var showKeyboardSheet = false
    @State private var inputText: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            // Шапка: статус, кнопка клавиатуры и кнопка поиска ТВ
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.selectedDevice?.name ?? "ТВ не выбран")
                        .font(.headline)
                    Text(engine.statusMessage)
                        .font(.caption)
                        .foregroundColor(engine.isConnected ? .green : .secondary)
                }
                
                Spacer()
                
                // Кнопка вызова клавиатуры
                Button(action: { showKeyboardSheet = true }) {
                    Image(systemName: "keyboard")
                        .font(.title3)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
                .disabled(!engine.isConnected)
                
                // Кнопка сканирования устройств
                Button(action: { showDevicePicker = true }) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title3)
                        .padding(10)
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
        // Модальное окно поиска устройств
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
                .navigationTitle("Устройства рядом")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        // Окно клавиатуры для быстрого ввода текста
        .sheet(isPresented: $showKeyboardSheet) {
            VStack(spacing: 16) {
                Text("Ввод текста на ТВ")
                    .font(.headline)
                    .padding(.top)
                
                HStack {
                    TextField("Напечатайте текст для ТВ...", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit {
                            submitText()
                        }
                    
                    Button(action: submitText) {
                        Image(systemName: "paperplane.fill")
                            .padding(8)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                
                // Дополнительные клавиши быстрого редактирования
                HStack(spacing: 20) {
                    Button(action: { engine.send(cmd: .backspace) }) {
                        Label("Стереть символ", systemImage: "delete.left")
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { engine.send(cmd: .enter) }) {
                        Label("Enter / Найти", systemImage: "return")
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Spacer()
            }
            .presentationDetents([.fraction(0.35), .medium])
        }
    }
    
    private func submitText() {
        guard !inputText.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        engine.sendText(inputText)
        inputText = ""
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
