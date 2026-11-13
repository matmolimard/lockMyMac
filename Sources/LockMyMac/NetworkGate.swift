import CoreLocation
import CoreWLAN
import Network

/// Dit sur quel réseau Wi-Fi se trouve le Mac, pour suspendre la surveillance à la maison.
///
/// macOS ne donne le nom du réseau Wi-Fi qu'aux apps autorisées à utiliser la localisation
/// (un nom de réseau révèle où l'on est). lockMyMac ne lit que ce nom, jamais la position.
@MainActor
final class NetworkGate: NSObject, CLLocationManagerDelegate {
    var onChange: (() -> Void)?
    private let manager = CLLocationManager()
    private let monitor = NWPathMonitor()

    override init() {
        super.init()
        manager.delegate = self
        Self.watch(monitor) { [weak self] in self?.onChange?() }
    }

    private nonisolated static func watch(_ monitor: NWPathMonitor, then: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { _ in Task { @MainActor in then() } }
        monitor.start(queue: .global(qos: .utility))
    }

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedAlways
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    /// Nom du réseau Wi-Fi actuel ; `nil` si pas de Wi-Fi ou pas d'autorisation.
    var currentSSID: String? {
        guard isAuthorized else { return nil }
        return CWWiFiClient.shared().interface()?.ssid()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onChange?() }
    }
}
