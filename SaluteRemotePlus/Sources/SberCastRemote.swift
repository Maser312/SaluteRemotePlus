import Foundation
import JazzSDK

@MainActor
final class SberCastRemote: NSObject, ObservableObject, SberCastListener {
    @Published private(set) var devices: [SberCastDevice] = []
    @Published private(set) var status = "Запуск…"
    @Published private(set) var connectedDevice: SberCastDevice?
    @Published private(set) var session: GamepadSession?
    @Published var pin: String = ""
    @Published private(set) var needsPin = false
    @Published private(set) var error: String?

    private let cast: any SberCast
    private var activeDeviceID: String?

    override init() {
        self.cast = SberCastFactory.makeSberCast(clientName: "SaluteRemotePlus")
        super.init()
        cast.addListener(listener: self)
        var settings = cast.getSettings()
        settings.connectionMediums.wifiMdns = true
        settings.connectionMediums.ble = false
        _ = cast.setSettings(sberCastSettings: settings)
        cast.setClientName(name: "SaluteRemotePlus")
        cast.setClientId(name: "saluteremoteplus")
    }

    func start() {
        error = nil
        status = "Ищем телевизор…"
        cast.start()
    }

    func stop() {
        cast.stop()
        status = "Остановлено"
    }

    func connect(_ device: SberCastDevice) {
        activeDeviceID = device.id
        connectedDevice = device
        needsPin = false
        error = nil
        status = "Подключаемся к \(device.name)…"
        let token = cast.accessTokenForDevice(device.id)
        _ = cast.connectToDevice(deviceId: device.id, accessToken: token)
    }

    func confirmPIN() {
        guard let id = activeDeviceID, !pin.isEmpty else { return }
        status = "Проверяем код…"
        _ = cast.confirmDeviceConnectionCode(deviceId: id, code: pin)
    }

    private func requestGamepadSession() {
        guard let id = activeDeviceID else { return }
        let sid = UUID().uuidString
        status = "Получаем канал пульта…"
        _ = cast.sendRequest(
            deviceId: id,
            request: CastRequest(type: .getGamepadSessionCastRequest(sessionId: sid))
        )
    }

    func onStatusChanged(status: CastStatus) {
        switch status.state {
        case .stopped: self.status = "Остановлено"
        case .starting: self.status = "Запускаем обнаружение…"
        case .running: self.status = "Ищем телевизор…"
        }
    }

    func onError(error: CastError) {
        self.error = error.msg
        self.status = "Ошибка"
    }

    func onDevicesChanged(_ devices: [SberCastDevice]) {
        self.devices = devices
        if devices.isEmpty {
            status = "Телевизор не найден"
        } else {
            status = "Выберите телевизор"
        }
    }

    func onCastMessageResponse(message: CastMessage) {}

    func onCastRequestResponse(response: CastRequestResponse) {
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
                self.error = "Не удалось авторизовать пульт"
            }

        case .pinConnectConfirmationCastResponse(let deviceId, let status, let token):
            activeDeviceID = deviceId
            switch status {
            case .authorized:
                cast.setAccessTokenForDevice(deviceId, accessToken: token)
                needsPin = false
                requestGamepadSession()
            default:
                error = "Неверный код или подключение запрещено"
            }

        case .gamepadSessionConnectionInfoCastResponse(let deviceId, let status, let sessionId, let port, let serviceVersion, let aesKey, let ipV4List):
            guard status == .success else {
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
    func onBLEDeeplinkRunInfo(_ info: RunBLEDeeplinkOnDeviceInfo) {}
}
