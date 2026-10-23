import AppKit
import CoreLocation
import CoreWLAN
import ShoeboxCore
import IOKit.ps
import Network

/// Reads the power source, the network, and the Wi-Fi name for the
/// scheduled backup conditions.
@MainActor
@Observable
final class SystemMonitor: NSObject {
    private(set) var locationStatus: CLAuthorizationStatus
    /// Called when the network changes or a volume mounts.
    private var onChange: (@MainActor () -> Void)?
    private var path: NWPath?
    private let pathMonitor = NWPathMonitor()
    private let location = CLLocationManager()
    private var mountObserver: Task<Void, Never>?

    override init() {
        locationStatus = location.authorizationStatus
        super.init()
        location.delegate = self
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.path = path
                self?.onChange?()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.gstark.shoebox.network"))
        mountObserver = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didMountNotification) {
                self?.onChange?()
            }
        }
    }

    func state(destinationFolder: String?) -> SystemState {
        SystemState(
            onPowerAdapter: Self.onPowerAdapter,
            network: network,
            destinationFolderExists: destinationFolder.map { FileManager.default.fileExists(atPath: $0) } ?? true
        )
    }

    /// The name of the current Wi-Fi network. macOS gives it only with
    /// Location Services permission.
    var wifiName: String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    var locationAllowed: Bool {
        locationStatus == .authorizedAlways
    }

    func requestLocationAccess() {
        location.requestWhenInUseAuthorization()
    }

    private var network: SystemState.Network {
        guard let path, path.status == .satisfied else { return .offline }
        let expensive = path.isExpensive || path.isConstrained
        if path.usesInterfaceType(.wiredEthernet) { return .wired(expensive: expensive) }
        if path.usesInterfaceType(.wifi) { return .wifi(wifiName: wifiName, expensive: expensive) }
        return .other(expensive: expensive)
    }

    /// A desktop Mac always reports the power adapter.
    private static var onPowerAdapter: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

extension SystemMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            locationStatus = status
            onChange?()
        }
    }
}
