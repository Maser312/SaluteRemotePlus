import Foundation

enum RemoteCommand: String, CaseIterable, Identifiable {
    case power = "POWER"
    case mute = "MUTE"
    case up = "UP"
    case down = "DOWN"
    case left = "LEFT"
    case right = "RIGHT"
    case ok = "OK"
    case back = "BACK"
    case home = "HOME"
    case search = "SEARCH"
    case source = "SOURCE"
    case volumeUp = "VOLUME_UP"
    case volumeDown = "VOLUME_DOWN"
    case channelUp = "CHANNEL_UP"
    case channelDown = "CHANNEL_DOWN"
    case playPause = "PLAY_PAUSE"

    var id: String { rawValue }

    var keyCode: Int {
        switch self {
        case .power: return 26
        case .mute: return 164
        case .up: return 19
        case .down: return 20
        case .left: return 21
        case .right: return 22
        case .ok: return 23
        case .back: return 4
        case .home: return 3
        case .search: return 84
        case .source: return 178
        case .volumeUp: return 24
        case .volumeDown: return 25
        case .channelUp: return 166
        case .channelDown: return 167
        case .playPause: return 85
        }
    }
}

struct GamepadSession {
    let sessionId: String
    let port: UInt
    let serviceVersion: String
    let aesKey: String
    let ipv4: [String]
}
