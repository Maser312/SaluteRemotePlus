import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var remote = SberCastRemote()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(red: 0.08, green: 0.04, blue: 0.13), .black], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            if remote.connectedDevice != nil { RemotePadView(remote: remote) } else { ConnectionView(remote: remote) }
        }
        .preferredColorScheme(.dark)
        .onAppear { remote.resume() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                remote.resume()
            case .background:
                remote.pause()
            default:
                break
            }
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var remote: SberCastRemote
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    ZStack { Circle().fill(.white.opacity(0.08)).frame(width: 86, height: 86); Image(systemName: "tv.fill").font(.system(size: 38, weight: .semibold)) }
                    Text("Salute Remote+").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Управление телевизором по Wi‑Fi").font(.subheadline).foregroundStyle(.white.opacity(0.55))
                }.padding(.top, 35)
                StatusCard(remote: remote)
                if !remote.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Телевизоры").font(.headline).foregroundStyle(.white.opacity(0.75))
                        ForEach(remote.devices, id: \.id) { device in
                            Button { remote.connect(device); Haptics.tap() } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "tv").font(.title3).frame(width: 42, height: 42).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name).font(.headline).foregroundStyle(.white)
                                        Text(device.features?.contains(.gamepadService) == true ? "Пульт доступен" : "Устройство найдено").font(.caption).foregroundStyle(.white.opacity(0.5))
                                    }
                                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.35))
                                }.padding(15).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if remote.needsPin {
                    VStack(spacing: 14) {
                        Text("Код на экране ТВ").font(.headline)
                        TextField("0000", text: $remote.pin).keyboardType(.numberPad).multilineTextAlignment(.center).font(.system(size: 28, weight: .bold, design: .monospaced)).padding().background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        Button { remote.confirmPIN(); Haptics.tap() } label: { Text("Подключить").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15) }.buttonStyle(.borderedProminent)
                    }.padding(18).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
                }
            }.padding(.horizontal, 20).padding(.bottom, 25)
        }
    }
}

struct StatusCard: View {
    @ObservedObject var remote: SberCastRemote
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(remote.error == nil ? .green : .red).frame(width: 9, height: 9)
            Text(remote.error ?? remote.status).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            Spacer(); if remote.devices.isEmpty { ProgressView().tint(.white) }
        }.padding(15).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct RemotePadView: View {
    @ObservedObject var remote: SberCastRemote
    @State private var showKeyboard = false
    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(remote.connectedDevice?.name ?? "Телевизор").font(.system(size: 23, weight: .bold, design: .rounded))
                            HStack(spacing: 6) { Circle().fill(.green).frame(width: 7, height: 7); Text("Подключено").font(.caption.weight(.medium)).foregroundStyle(.green) }
                        }
                        Spacer()
                        Button { remote.forgetSavedDevice(); Haptics.tap() } label: { Image(systemName: "link.badge.plus").font(.title3).frame(width: 46, height: 46).background(.white.opacity(0.08), in: Circle()) }
                    }
                    RemoteTopBar(send: send)
                    VStack(spacing: 8) {
                        RemoteButton(symbol: "chevron.up", size: 72) { send(.up) }
                        HStack(spacing: 8) { RemoteButton(symbol: "chevron.left", size: 72) { send(.left) }; RemoteButton(title: "OK", size: 78, accent: true) { send(.ok) }; RemoteButton(symbol: "chevron.right", size: 72) { send(.right) } }
                        RemoteButton(symbol: "chevron.down", size: 72) { send(.down) }
                    }.padding(18).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 30))
                    HStack(spacing: 10) { SmallRemoteButton(symbol: "speaker.wave.1.fill", title: "VOL −") { send(.volumeDown) }; SmallRemoteButton(symbol: "speaker.slash.fill", title: "MUTE") { send(.mute) }; SmallRemoteButton(symbol: "speaker.wave.3.fill", title: "VOL +") { send(.volumeUp) } }
                    HStack(spacing: 10) { SmallRemoteButton(symbol: "chevron.down.2", title: "CH −") { send(.channelDown) }; SmallRemoteButton(symbol: "playpause.fill", title: "PLAY") { send(.playPause) }; SmallRemoteButton(symbol: "chevron.up.2", title: "CH +") { send(.channelUp) } }
                    HStack(spacing: 10) {
                        SmallRemoteButton(symbol: remote.voiceState == .idle ? "mic.fill" : "stop.fill", title: remote.voiceState == .idle ? "Голос" : (remote.voiceState == .starting ? "Подключаем…" : "Говорите…"), highlighted: remote.voiceState != .idle) { Haptics.tap(); remote.toggleVoice() }
                        SmallRemoteButton(symbol: "keyboard", title: "Текст") { Haptics.tap(); showKeyboard = true }
                    }
                    HStack(spacing: 10) { SmallRemoteButton(symbol: "magnifyingglass", title: "Поиск") { send(.search) }; SmallRemoteButton(symbol: "rectangle.on.rectangle", title: "Источник") { send(.source) } }
                    Text(remote.error ?? remote.notice ?? (remote.wireReady ? "Пульт готов" : remote.status)).font(.caption).foregroundStyle(remote.error == nil ? Color.white.opacity(0.4) : Color.red.opacity(0.9)).multilineTextAlignment(.center).padding(.bottom, max(8, proxy.safeAreaInsets.bottom))
                }.padding(.horizontal, 18).padding(.top, max(10, proxy.safeAreaInsets.top))
            }
        }
        .sheet(isPresented: $showKeyboard) { TextInputSheet(remote: remote) }
    }
    private func send(_ command: RemoteCommand) { Haptics.tap(); remote.send(command) }
}

struct RemoteTopBar: View {
    let send: (RemoteCommand) -> Void
    var body: some View { HStack(spacing: 10) { SmallRemoteButton(symbol: "power", title: "Питание") { send(.power) }; SmallRemoteButton(symbol: "house.fill", title: "Домой") { send(.home) }; SmallRemoteButton(symbol: "arrow.uturn.backward", title: "Назад") { send(.back) } } }
}

struct RemoteButton: View {
    var symbol: String?; var title: String?; let size: CGFloat; var accent = false; let action: () -> Void
    var body: some View { Button(action: action) { Group { if let symbol { Image(systemName: symbol) } else { Text(title ?? "") } }.font(.system(size: title == nil ? 24 : 19, weight: .bold)).foregroundStyle(.white).frame(width: size, height: size).background(accent ? Color.purple.opacity(0.75) : Color.white.opacity(0.09), in: Circle()) }.buttonStyle(.plain) }
}

struct SmallRemoteButton: View {
    let symbol: String; let title: String; var highlighted = false; let action: () -> Void
    var body: some View { Button(action: action) { VStack(spacing: 7) { Image(systemName: symbol).font(.title3.weight(.semibold)); Text(title).font(.caption2.weight(.semibold)) }.foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 66).background(highlighted ? Color.purple.opacity(0.75) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18)) }.buttonStyle(.plain) }
}

struct TextInputSheet: View {
    @ObservedObject var remote: SberCastRemote
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 16) {
            Text("Ввод текста на ТВ").font(.headline).padding(.top, 20)
            Text("Сначала выберите поле ввода на ТВ (кнопкой OK).").font(.caption).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            TextField("Что набрать…", text: $text).focused($focused).submitLabel(.send).onSubmit { send(submit: true) }.padding(14).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                Button { Haptics.tap(); remote.sendKey(KeyMap.backspace) } label: { Label("Стереть", systemImage: "delete.left").frame(maxWidth: .infinity).padding(.vertical, 12) }.buttonStyle(.bordered)
                Button { Haptics.tap(); remote.sendKey(KeyMap.enter) } label: { Label("Enter", systemImage: "return").frame(maxWidth: .infinity).padding(.vertical, 12) }.buttonStyle(.bordered)
            }
            Button { send(submit: true) } label: { Text("Набрать и нажать Enter").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14) }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
            Button { remote.typeText(text, submit: false); Haptics.tap() } label: { Text("Только набрать").frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.bordered).disabled(text.isEmpty)
            Button { remote.youtubeSearch(text); Haptics.tap(); dismiss() } label: { Label("Искать на YouTube (любой язык)", systemImage: "play.rectangle").frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.bordered).disabled(text.isEmpty)
            if let notice = remote.notice { Text(notice).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Spacer()
        }.padding(.horizontal, 20).preferredColorScheme(.dark).onAppear { focused = true }
    }
    private func send(submit: Bool) {
        guard !text.isEmpty else { return }
        Haptics.tap(); remote.typeText(text, submit: submit)
        if remote.notice == nil { text = ""; dismiss() }
    }
}

enum Haptics { static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
