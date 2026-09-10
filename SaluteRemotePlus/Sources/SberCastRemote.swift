import Foundation
import Network
import LibSberCast

@MainActor
final class SberCastRemote: NSObject, ObservableObject, LibSberCast.SberCastListener {
    @Published private(set) var devices: [LibSberCast.SberCastDevice] = []
    @Published private(set) var status = "Запуск…"
    @Published private(set) var connectedDevice: LibSberCast.SberCastDevice?
    @Published private(set) var session: GamepadSession?
    @Published var pin: String = ""
    @Published private(set) var needsPin = false
    @Published private(set) var error: String?

    private let cast: any LibSberCast.SberCast
    private var activeDeviceID: String?
    private var permissionBrowser: NWBrowser?
    private var autoConnectAttempted = false

    private let savedDeviceIDKey = "SaluteRemotePlus.savedDeviceID"
    private let savedDeviceNameKey = "SaluteRemotePlus.savedDeviceName"

    override init() {
        self.cast = LibSberCast.SberCastFactory.makeSberCast(clientName: "SaluteRemotePlus")
        super.init()
        cast.addListener(listener: self)
        cast.setClientName(name: "SaluteRemotePlus")
        cast.setClientId(name: "saluteremoteplus")
    }

    func start() {
        error = nil
        autoConnectAttempted = false
        status = "Подключаемся к локальной сети…"

        let browser = NWBrowser(
            for: .bonjour(type: "_staros._tcp", domain: "local."),
            using: .tcp
        )
        permissionBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    self.status = "Ищем телевизор…"
                    self.cast.start()
                case .failed(let error):
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    self.error = "Доступ к локальной сети: \(error.localizedDescription)"
                    self.status = "Ищем телевизор…"
                    self.cast.start()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "SaluteRemotePlus.LocalNetwork"))
    }

    func stop() {
        permissionBrowser?.cancel()
        permissionBrowser = nil
        cast.stop()
        status = "Остановлено"
    }

    func connect(_ device: LibSberCast.SberCastDevice, save: Bool = true) {
        activeDeviceID = device.id
        connectedDevice = device
        needsPin = false
        pin = ""
        error = nil

        if save {
            UserDefaults.standard.set(device.id, forKey: savedDeviceIDKey)
            UserDefaults.standard.set(device.name, forKey: savedDeviceNameKey)
        }

        status = "Подключаемся к \(device.name)…"
        let token = cast.accessTokenForDevice(device.id)
        _ = cast.connectToDevice(deviceId: device.id, accessToken: token)
    }

    func reconnectSavedDeviceIfPossible() {
        guard !autoConnectAttempted,
              let savedID = UserDefaults.standard.string(forKey: savedDeviceIDKey),
              let device = devices.first(where: { $0.id == savedID }) else { return }

        autoConnectAttempted = true
        connect(device, save: false)
    }

    func forgetSavedDevice() {
        UserDefaults.standard.removeObject(forKey: savedDeviceIDKey)
        UserDefaults.standard.removeObject(forKey: savedDeviceNameKey)
        session = nil
        connectedDevice = nil
        activeDeviceID = nil
        needsPin = false
        status = "Телевизор отвязан"
    }

    func confirmPIN() {
        guard let id = activeDeviceID, !pin.isEmpty else { return }
        status = "Проверяем код…"
        _ = cast.confirmDeviceConnectionCode(deviceId: id, code: pin)
    }

    private func requestGamepadSession() {
        guard let id = activeDeviceID else { return }
        let sid = UUID().uuidString
        status = "Запускаем канал пульта…"
        _ = cast.sendRequest(
            deviceId: id,
            request: LibSberCast.CastRequest(type: .getGamepadSessionCastRequest(sessionId: sid))
        )
    }

    func onStatusChanged(status: LibSberCast.CastStatus) {
        switch status.state {
        case .stopped: self.status = "Остановлено"
        case .starting: self.status = "Запускаем обнаружение…"
        case .running: self.status = "Ищем телевизор…"
        }
    }

    func onError(error: LibSberCast.CastError) {
        self.error = error.msg
        self.status = "Ошибка подключения"
    }

    func onDevicesChanged(_ devices: [LibSberCast.SberCastDevice]) {
        self.devices = devices
        if devices.isEmpty {
            status = "Телевизор не найден"
            return
        }

        if !autoConnectAttempted {
            reconnectSavedDeviceIfPossible()
        }

        if connectedDevice == nil {
            status = "Выберите телевизор"
        }
    }

    func onCastMessageResponse(message: LibSberCast.CastMessage) {
        if message.code != .success {
            error = message.description
        }
    }

    func onCastRequestResponse(response: LibSberCast.CastRequestResponse) {
        switch response.type {
        case .pinConnectCastResponse(let deviceId, let status):
            activeDeviceID = deviceId
            switch status {
            case .inputPinCode:
                needsPin = true
                self.status = "Введите код с телевизора"
            case .authorized, .sessionAlreadyActive:
                needsPin = false
                requestGamepadSession()
            default:
                self.error = "Телевизор отклонил подключение"
            }

        case .pinConnectConfirmationCastResponse(let deviceId, let status, let token):
            activeDeviceID = deviceId
            switch status {
            case .authorized:
                cast.setAccessTokenForDevice(deviceId, accessToken: token)
                needsPin = false
                pin = ""
                requestGamepadSession()
            default:
                error = "Неверный код или подключение запрещено"
            }

        case .gamepadSessionConnectionInfoCastResponse(let deviceId, let status, let sessionId, let port, let serviceVersion, let aesKey, let ipV4List):
            guard status == .success else {
                session = nil
                error = "Телевизор не предоставил канал пульта"
                return
            }

            activeDeviceID = deviceId
            session = GamepadSession(
                sessionId: sessionId,
                port: port,
                serviceVersion: serviceVersion,
                aesKey: aesKey,
                ipv4: Array(ipV4List)
            )
            self.status = "Пульт подключён"

        default:
            break
        }
    }

    func onBLEDeeplinkReceived(deeplink: String) {}
    func onBLEDeeplinkRunInfo(_ info: LibSberCast.RunBLEDeeplinkOnDeviceInfo) {}
}
