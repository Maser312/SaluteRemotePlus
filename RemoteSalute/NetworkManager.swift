import Foundation
import Network

final class RemoteEngine: ObservableObject {
    @Published var isConnected = false
    @Published var statusMessage = "Отключено"
    
    private var connection: NWConnection?
    
    enum Command: Int {
        case up = 19
        case down = 20
        case left = 21
        case right = 22
        case select = 23    // DPAD_CENTER
        case back = 4
        case home = 3
        case power = 26
        case volumeUp = 24
        case volumeDown = 25
    }
    
    func connect(ip: String, port: UInt16 = 5555) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let host = NWEndpoint.Host(ip)
        
        connection?.cancel()
        
        let params = NWParameters.tcp
        connection = NWConnection(host: host, port: nwPort, using: params)
        
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.statusMessage = "Подключено к \(ip)"
                case .failed(let error):
                    self?.isConnected = false
                    self?.statusMessage = "Ошибка: \(error.localizedDescription)"
                case .waiting(let error):
                    self?.statusMessage = "Ожидание: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        connection?.start(queue: .global(qos: .userInitiated))
    }
    
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
