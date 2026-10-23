import Foundation

/// The state of the Mac when a scheduled backup is due.
public struct SystemState: Sendable, Equatable {
    public enum Network: Sendable, Equatable {
        case offline
        /// `wifiName` is nil when macOS does not give the name, for example
        /// without Location Services permission.
        case wifi(wifiName: String?, expensive: Bool)
        case wired(expensive: Bool)
        /// Cellular or another interface.
        case other(expensive: Bool)
    }

    public var onPowerAdapter: Bool
    public var network: Network
    /// For a folder destination: the folder exists, so its drive is connected.
    public var destinationFolderExists: Bool

    public init(onPowerAdapter: Bool, network: Network, destinationFolderExists: Bool = true) {
        self.onPowerAdapter = onPowerAdapter
        self.network = network
        self.destinationFolderExists = destinationFolderExists
    }
}

/// Why a due scheduled backup waits. Back Up Now ignores these.
public enum WaitReason: Sendable, Equatable, CustomStringConvertible {
    case onBattery
    case offline
    case expensiveNetwork
    case otherWiFi(String)
    case unknownWiFi
    case notOnAllowedNetwork
    case destinationNotConnected

    public var description: String {
        switch self {
        case .onBattery: "The Mac is on battery power"
        case .offline: "No network connection"
        case .expensiveNetwork: "The network is a hotspot or in Low Data Mode"
        case .otherWiFi(let name): "\"\(name)\" is not an allowed Wi-Fi network"
        case .unknownWiFi: "The Wi-Fi network name is unknown. Allow Location Services for Shoebox"
        case .notOnAllowedNetwork: "Not on an allowed Wi-Fi network"
        case .destinationNotConnected: "The backup drive is not connected"
        }
    }
}

extension Schedule {
    public var requirePowerEnabled: Bool { requirePower ?? true }
    public var skipExpensiveNetworkEnabled: Bool { skipExpensiveNetwork ?? true }
    public var onMountEnabled: Bool { onMount ?? true }
    public var allowedWiFi: [String] { wifiNetworks ?? [] }

    /// The reasons that a scheduled backup must wait. Empty means it can run.
    public func waitReasons(_ state: SystemState, destinationIsS3: Bool) -> [WaitReason] {
        var reasons: [WaitReason] = []
        if requirePowerEnabled, !state.onPowerAdapter {
            reasons.append(.onBattery)
        }
        if destinationIsS3 {
            if state.network == .offline { reasons.append(.offline) }
        } else if !state.destinationFolderExists {
            reasons.append(.destinationNotConnected)
        }
        if skipExpensiveNetworkEnabled, state.network.isExpensive {
            reasons.append(.expensiveNetwork)
        }
        if !allowedWiFi.isEmpty {
            switch state.network {
            case .wired, .offline:
                // A cable is not a coffee shop. Offline is reported above,
                // and a folder backup needs no network.
                break
            case .wifi(let name?, _) where allowedWiFi.contains(name):
                break
            case .wifi(let name?, _):
                reasons.append(.otherWiFi(name))
            case .wifi(nil, _):
                reasons.append(.unknownWiFi)
            case .other:
                reasons.append(.notOnAllowedNetwork)
            }
        }
        return reasons
    }
}

extension SystemState.Network {
    var isExpensive: Bool {
        switch self {
        case .offline: false
        case .wifi(_, let expensive), .wired(let expensive), .other(let expensive): expensive
        }
    }
}
