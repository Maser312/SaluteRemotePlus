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
    private var started = false
    private var paused = false
    private var gamepadRequestInFlight = false
    private var gamepadRetryTask: Task<Void, Never>?
    private var gamepadRetryCount = 0
    private var restartTask: Task<Void, Never>?

    private let savedDeviceIDKey = "SaluteRemotePlus.savedDeviceID"
    private let savedDeviceNameKey = "SaluteRemotePlus.savedDeviceName"

    override init() {
        self.cast = LibSberCast.SberCastFactory.makeSberCast(clientName: "SaluteRemotePlus")
        super.init()
        cast.addListener(listener: self)
        cast.setClientName(name: "SaluteRemotePlus")
        cast.setClientId(name: "saluteremoteplus")
    }

    var hasSavedDevice: Bool {
        UserDefaults.standard.string(forKey: savedDeviceIDKey) != nil
    }

    func start() {
        guard !started else { return }
        started = true
        paused = false
        error = nil
        autoConnectAttempted = false
        gamepadRetryCount = 0
        status = hasSavedDevice ? "Восстанавливаем телевизор…" : "Подключаемся к локальной сети…"
        startBonjourPermissionProbe()
    }

    func resume() {
        paused = false
        if !started {
            start()
            return
        }

        // Do not create a second Bonjour browser when returning from background.
        // The SberCast instance remains alive; only the permission probe is recreated
        // if iOS cancelled it while the app was inactive.
        if permissionBrowser == nil && connectedDevice == nil {
            startBonjourPermissionProbe()
        } else if connectedDevice != nil {
            reconnectGamepadIfNeeded()
        } else {
            reconnectSavedDeviceIfPossible()
        }
    }

    func pause() {
        paused = true
        // Keep LibSberCast alive across background/foreground transitions.
        // Recreating it here causes Bonjour service errors on the next appearance.
        permissionBrowser?.cancel()
        permissionBrowser = nil
    }

    private func startBonjourPermissionProbe() {
        guard !paused, permissionBrowser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: "_staros._tcp", domain: "local."),
            using: .tcp
        )
        permissionBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    guard !self.paused else { return }
                    self.status = self.hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
                    self.cast.start()
                case .failed(let error):
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    guard !self.paused else { return }

                    // -72000 is the Bonjour/local-network service error. Do not turn
                    // it into a permanent connection failure; retry after iOS settles.
                    self.error = error.errorCode == -72000
                        ? nil
                        : "Доступ к локальной сети: \(error.localizedDescription)"
                    self.status = self.hasSavedDevice ? "Восстанавливаем телевизор…" : "Ищем телевизор…"
                    self.scheduleBonjourRetry()
                case .cancelled:
                    self.permissionBrowser = nil
                default:
                    break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "SaluteRemotePlus.LocalNetwork"))
    }

    private func scheduleBonjourRetry() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.paused, self.started else { return }
                if self.permissionBrowser == nil && self.connectedDevice == nil {
                    self.startBonjourPermissionProbe()
                }
            }
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        gamepadRequestInFlight = false
        permissionBrowser?.cancel()
        permissionBrowser = nil
        cast.stop()
        started = false
        paused = false
        status = hasSavedDevice ? "Остановлено — телевизор сохранён" : "Остановлено"
    }

    func connect(_ device: LibSberCast.SberCastDevice, save: Bool = true) {
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        gamepadRequestInFlight = false
        gamepadRetryCount = 0
        session = nil

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

    private func reconnectGamepadIfNeeded() {
        guard connectedDevice != nil, session == nil, !needsPin else { return }
        if !gamepadRequestInFlight {
            gamepadRetryCount = 0
            requestGamepadSession()
        }
    }

    func forgetSavedDevice() {
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        gamepadRequestInFlight = false
        UserDefaults.standard.removeObject(forKey: savedDeviceIDKey)
        UserDefaults.standard.removeObject(forKey: savedDeviceNameKey)
        session = nil
        connectedDevice = nil
        activeDeviceID = nil
        needsPin = false
        pin = ""
        error = nil
        status = "Телевизор отвязан"
    }

    func confirmPIN() {
        guard let id = activeDeviceID, !pin.isEmpty else { return }
        status = "Проверяем код…"
        _ = cast.confirmDeviceConnectionCode(deviceId: id, code: pin)
    }

    private func requestGamepadSession() {
        guard let id = activeDeviceID, !gamepadRequestInFlight else { return }
        gamepadRequestInFlight = true
        let sid = UUID().uuidString
        status = "Запускаем канал пульта…"
        _ = cast.sendRequest(
            deviceId: id,
            request: LibSberCast.CastRequest(type: .getGamepadSessionCastRequest(sessionId: sid))
        )

        gamepadRetryTask?.cancel()
        gamepadRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await MainActor.run {
                guard self.gamepadRequestInFlight, self.session == nil else { return }
                self.gamepadRequestInFlight = false
                self.gamepadRetryCount += 1
                if self.gamepadRetryCount <= 5 {
                    self.requestGamepadSession()
                } else {
                    self.error = "Телевизор не вернул параметры канала пульта"
                    self.status = self.connectedDevice == nil ? "Телевизор сохранён, но не подключён" : "Не удалось запустить канал пульта"
                }
            }
        }
    }

    func onStatusChanged(status: LibSberCast.CastStatus) {
        switch status.state {
        case .stopped: self.status = hasSavedDevice ? "Телевизор сохранён" : "Остановлено"
        case .starting: self.status = "Запускаем обнаружение…"
        case .running: self.status = hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
        }
    }

    func onError(error: LibSberCast.CastError) {
        self.error = error.msg
        self.gamepadRequestInFlight = false
        self.status = hasSavedDevice ? "Ошибка подключения — телевизор сохранён" : "Ошибка подключения"
    }

    func onDevicesChanged(_ devices: [LibSberCast.SberCastDevice]) {
        self.devices = devices
        if devices.isEmpty {
            status = hasSavedDevice ? "Ищем сохранённый телевизор…" : "Телевизор не найден"
            return
        }
        if !autoConnectAttempted { reconnectSavedDeviceIfPossible() }
        if connectedDevice == nil && !hasSavedDevice { status = "Выберите телевизор" }
    }

    func onCastMessageResponse(message: LibSberCast.CastMessage) {
        if message.code != .success { error = message.description }
    }

    func onCastRequestResponse(response: LibSberCast.CastRequestResponse) {
        guard response.code == .success else {
            gamepadRequestInFlight = false
            error = "Запрос к телевизору отклонён (\(response.code))"
            status = connectedDevice == nil ? "Телевизор сохранён, но недоступен" : "Ошибка подключения"
            return
        }

        switch response.type {
        case .pinConnectCastResponse(let deviceId, let status):
            activeDeviceID = deviceId
            switch status {
            case .inputPinCode:
                needsPin = true
                error = nil
                self.status = "Введите код с телевизора"
            case .authorized, .sessionAlreadyActive:
                needsPin = false
                error = nil
                gamepadRetryCount = 0
                requestGamepadSession()
            default:
                error = "Телевизор отклонил подключение"
                self.status = "Ошибка подключения"
            }

        case .pinConnectConfirmationCastResponse(let deviceId, let status, let token):
            activeDeviceID = deviceId
            switch status {
            case .authorized:
                cast.setAccessTokenForDevice(deviceId, accessToken: token)
                needsPin = false
                pin = ""
                error = nil
                gamepadRetryCount = 0
                requestGamepadSession()
            default:
                error = "Неверный код или подключение запрещено"
                self.status = "Ошибка подключения"
            }

        case .gamepadSessionConnectionInfoCastResponse(let deviceId, let status, let sessionId, let port, let serviceVersion, let aesKey, let ipV4List):
            gamepadRequestInFlight = false
            gamepadRetryTask?.cancel()
            gamepadRetryTask = nil

            guard status == .success else {
                session = nil
                error = "Канал пульта: \(status)"
                self.status = "Канал пульта недоступен — повторяем…"
                gamepadRetryCount += 1
                if gamepadRetryCount <= 5 { requestGamepadSession() }
                return
            }

            guard !sessionId.isEmpty, port > 0, !aesKey.isEmpty, !ipV4List.isEmpty else {
                session = nil
                error = "Телевизор вернул неполные параметры канала пульта"
                self.status = "Неполные параметры канала — повторяем…"
                gamepadRetryCount += 1
                if gamepadRetryCount <= 5 { requestGamepadSession() }
                return
            }

            activeDeviceID = deviceId
            gamepadRetryCount = 0
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
