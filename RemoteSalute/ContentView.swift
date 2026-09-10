import SwiftUI

// Фирменная палитра Салют / Sber
extension Color {
    static let saluteBg = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let saluteSurface = Color(red: 0.11, green: 0.12, blue: 0.16).opacity(0.85)
    static let saluteAccent = Color(red: 0.13, green: 0.85, blue: 0.45) // Фирменный зеленый
    static let saluteGradientStart = Color(red: 0.12, green: 0.85, blue: 0.55)
    static let saluteGradientEnd = Color(red: 0.18, green: 0.55, blue: 0.95)
}

struct ContentView: View {
    @StateObject private var engine = RemoteEngine()
    @State private var showDevicePicker = false
    @State private var showKeyboardSheet = false
    @State private var inputText: String = ""
    @State private var isMuted: Bool = false

    var body: some View {
        ZStack {
            // Фоновый градиент с фирменным неоновым свечением
            Color.saluteBg.ignoresSafeArea()
            
            RadialGradient(
                gradient: Gradient(colors: [Color.saluteGradientEnd.opacity(0.18), Color.clear]),
                center: .topTrailing,
                startRadius: 10,
                endRadius: 350
            )
            .ignoresSafeArea()
            
            RadialGradient(
                gradient: Gradient(colors: [Color.saluteGradientStart.opacity(0.12), Color.clear]),
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 400
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // Шапка: статус устройства и кнопки действий
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engine.selectedDevice?.name ?? "Салют ТВ")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        HStack(spacing: 6) {
                            Circle()
                                .fill(engine.isConnected ? Color.saluteAccent : Color.red.opacity(0.8))
                                .frame(width: 8, height: 8)
                            Text(engine.statusMessage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.gray)
                        }
                    }

                    Spacer()

                    // Клавиатура
                    GlassButton(icon: "keyboard") {
                        showKeyboardSheet = true
                    }
                    .disabled(!engine.isConnected)
                    
                    // Поиск ТВ
                    GlassButton(icon: "antenna.radiowaves.left.and.right") {
                        showDevicePicker = true
                    }
                    
                    // Кнопка питания
                    GlassButton(icon: "power", iconColor: .red.opacity(0.9)) {
                        engine.send(cmd: .power)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                Spacer()

                // Центральный D-Pad в стиле Salute
                ZStack {
                    // Внешнее кольцо со стеклянным фоном
                    Circle()
                        .fill(Color.saluteSurface)
                        .frame(width: 270, height: 270)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.2), Color.clear, Color.saluteAccent.opacity(0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                        .shadow(color: Color.black.opacity(0.5), radius: 25, x: 0, y: 15)

                    // Стрелки направлений
                    VStack {
                        PadArrowButton(icon: "chevron.up") { engine.send(cmd: .up) }
                        Spacer()
                        PadArrowButton(icon: "chevron.down") { engine.send(cmd: .down) }
                    }
                    .frame(height: 220)

                    HStack {
                        PadArrowButton(icon: "chevron.left") { engine.send(cmd: .left) }
                        Spacer()
                        PadArrowButton(icon: "chevron.right") { engine.send(cmd: .right) }
                    }
                    .frame(width: 220)

                    // Центральная кнопка OK со сберовским градиентом
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        engine.send(cmd: .select)
                    }) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.saluteGradientStart, Color.saluteGradientEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 82, height: 82)
                            .overlay(
                                Text("OK")
                                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                                    .foregroundColor(.black.opacity(0.85))
                            )
                            .shadow(color: Color.saluteAccent.opacity(0.35), radius: 15, x: 0, y: 6)
                    }
                }

                Spacer()

                // Панель громкости и воспроизведения
                HStack(spacing: 16) {
                    ControlButton(icon: "speaker.wave.1.fill", label: "Тише") {
                        engine.send(cmd: .volumeDown)
                    }
                    
                    ControlButton(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", label: "Mute") {
                        isMuted.toggle()
                        // 164 - KEYCODE_VOLUME_MUTE
                        engine.send(cmd: .volumeDown)
                    }
                    
                    ControlButton(icon: "speaker.wave.3.fill", label: "Громче") {
                        engine.send(cmd: .volumeUp)
                    }
                }
                .padding(.horizontal, 24)

                // Нижний док системных кнопок
                HStack(spacing: 24) {
                    DockButton(icon: "arrow.backward", title: "Назад") { engine.send(cmd: .back) }
                    DockButton(icon: "house.fill", title: "Домой") { engine.send(cmd: .home) }
                    DockButton(icon: "magnifyingglass", title: "Поиск") { showKeyboardSheet = true }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        // Модальное окно устройств
        .sheet(isPresented: $showDevicePicker) {
            ZStack {
                Color.saluteBg.ignoresSafeArea()
                NavigationView {
                    List(engine.devices) { device in
                        Button(action: {
                            engine.connectTo(device: device)
                            showDevicePicker = false
                        }) {
                            HStack {
                                Image(systemName: device.peripheral != nil ? "wave.3.right.circle.fill" : "tv.fill")
                                    .foregroundColor(Color.saluteAccent)
                                    .font(.title3)
                                Text(device.name)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white)
                                Spacer()
                                if engine.selectedDevice?.id == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color.saluteAccent)
                                }
                            }
                        }
                        .listRowBackground(Color.saluteSurface)
                    }
                    .scrollContentBackground(.hidden)
                    .navigationTitle("Устройства Салют")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .preferredColorScheme(.dark)
        }
        // Шторка быстрой клавиатуры
        .sheet(isPresented: $showKeyboardSheet) {
            ZStack {
                Color.saluteBg.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    Capsule()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 40, height: 4)
                        .padding(.top, 10)

                    Text("Ввод текста на ТВ")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    HStack(spacing: 10) {
                        TextField("Название фильма, канала, видео...", text: $inputText)
                            .padding(12)
                            .background(Color.saluteSurface)
                            .cornerRadius(12)
                            .foregroundColor(.white)
                            .submitLabel(.send)
                            .onSubmit { submitText() }

                        Button(action: submitText) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(Color.saluteGradientStart, Color.saluteGradientEnd)
                        }
                    }
                    .padding(.horizontal, 20)

                    HStack(spacing: 16) {
                        Button(action: { engine.send(cmd: .backspace) }) {
                            Label("Удалить", systemImage: "delete.backward.fill")
                                .font(.system(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.saluteSurface)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }

                        Button(action: { engine.send(cmd: .enter) }) {
                            Label("Enter", systemImage: "return")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.saluteAccent.opacity(0.85))
                                .foregroundColor(.black)
                                .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer()
                }
            }
            .presentationDetents([.fraction(0.35)])
            .preferredColorScheme(.dark)
        }
    }

    private func submitText() {
        guard !inputText.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        engine.sendText(inputText)
        inputText = ""
    }
}

// MARK: - Элементы дизайна

struct GlassButton: View {
    let icon: String
    var iconColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 42, height: 42)
                .background(Color.saluteSurface)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

struct PadArrowButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 55, height: 55)
        }
    }
}

struct ControlButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.saluteSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

struct DockButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            action()
        }) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.saluteSurface)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}
