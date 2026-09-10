import Foundation
import Network
import CoreBluetooth

struct DiscoveredDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let host: NWEndpoint.Host?
    let port: NWEndpoint.Port?
    let peripheral: CBPeripheral?
}

final class RemoteEngine: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [DiscoveredDevice] = []
    @Published var selectedDevice: DiscoveredDevice?
    @Published var isConnected = false
    @Published var statusMessage = "Поиск устройств..."
    
    // Wi-Fi Browser
    private var browser: NWBrowser?
    private var connection: NWConnection?
    
    // Bluetooth
    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    
    enum Command: Int {
        case up = 19
        case down = 20
        case left = 21
        case right = 22
        case select = 23
        case back = 4
        case home = 3
        case power = 26
        case volumeUp = 24
        case volumeDown = 25
    }
    
    override init() {
        super.init()
        startWifiDiscovery()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Автопоиск по Wi-Fi (Bonjour / mDNS)
    func startWifiDiscovery() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_androidtvremote2._tcp", domain: nil)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: descriptor, using: parameters)
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        let device = DiscoveredDevice(
                            id: name,
                            name: name.isEmpty ? "Салют ТВ" : name,
                            host: nil,
                            port: nil,
                            peripheral: nil
                        )
                        if !(self?.devices.contains(where: { $0.id == device.id }) ?? false) {
                            self?.devices.append(device)
                        }
                    }
                }
            }
        }
        browser?.start(queue: .global(qos: .userInitiated))
    }
    
    // MARK: - Bluetooth Scanning
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Ищем любые устройства, транслирующие себя вокруг
            centralManager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let deviceName = name, !deviceName.isEmpty else { return }
        
        // Фильтруем ТВ, приставки SberBox или Салют
        let lower = deviceName.lowercased()
        if lower.contains("sber") || lower.contains("salute") || lower.contains("tv") || lower.contains("box") {
            let btDevice = DiscoveredDevice(
                id: peripheral.identifier.uuidString,
                name: "Bluetooth: \(deviceName)",
                host: nil,
                port: nil,
                peripheral: peripheral
            )
            DispatchQueue.main.async {
                if !self.devices.contains(where: { $0.id == btDevice.id }) {
                    self.devices.append(btDevice)
                }
            }
        }
    }
    
    // MARK: - Подключение к выбранному ТВ
    func connectTo(device: DiscoveredDevice) {
        self.selectedDevice = device
        self.statusMessage = "Подключение к \(device.name)..."
        
        if let peripheral = device.peripheral {
            // Подключение по BT
            targetPeripheral = peripheral
            centralManager?.connect(peripheral, options: nil)
        } else {
            // Подключение по Wi-Fi (автоматический резолв эндпоинта)
            let endpoint = NWEndpoint.service(name: device.id, type: "_androidtvremote2._tcp", domain: "local", interface: nil)
            let params = NWParameters.tcp
            connection = NWConnection(to: endpoint, using: params)
            connection?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isConnected = true
                        self?.statusMessage = "Подключено: \(device.name)"
                    case .failed(let err):
                        self?.isConnected = false
                        self?.statusMessage = "Сбой: \(err.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            connection?.start(queue: .global(qos: .userInitiated))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.statusMessage = "Подключено по BT: \(peripheral.name ?? "")"
        }
    }
    
    // MARK: - Отправка команд
    func send(cmd: Command) {
        guard isConnected else { return }
        let payload = "input keyevent \(cmd.rawValue)\n"
        guard let data = payload.data(using: .utf8) else { return }
        
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error)")
            }
        })
    }
}
