import Foundation
import Network
import SystemConfiguration.CaptiveNetwork
import NetworkExtension
import CoreLocation

class NetworkMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let locationManager = CLLocationManager()
    
    @Published var isConnectedToTargetSSID = false
    @Published var currentSSID: String?
    @Published var currentSignalStrength: Double = 0.0
    
    var targetSSID: String = "" {
        didSet {
            checkSSID()
        }
    }
    
    override init() {
        super.init()
        DataDonorLogger.shared.log("NetworkMonitor: Initializing...", level: .debug)
        locationManager.delegate = self
        // iOS requires location permission to read the Wi-Fi SSID
        let authStatus = locationManager.authorizationStatus
        DataDonorLogger.shared.log("NetworkMonitor: Location authorization status is \(authStatus.rawValue)", level: .debug)
        if authStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        
        // Setup NWPathMonitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let isConnected = path.status == .satisfied
            DataDonorLogger.shared.log("NetworkMonitor: NWPathMonitor status changed - Is Connected: \(isConnected)", level: .info)
            DispatchQueue.main.async {
                if isConnected && path.usesInterfaceType(.wifi) {
                    DataDonorLogger.shared.log("NetworkMonitor: Connected via Wi-Fi. Checking SSID...", level: .info)
                    self.checkSSID()
                } else {
                    DataDonorLogger.shared.log("NetworkMonitor: Not connected via Wi-Fi (usesInterfaceType: \(path.usesInterfaceType(.wifi))).", level: .info)
                    self.currentSSID = nil
                    self.isConnectedToTargetSSID = false
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DataDonorLogger.shared.log("NetworkMonitor: Location authorization changed to \(status.rawValue)", level: .info)
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            checkSSID()
        }
    }
    
    func checkSSID() {
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { [weak self] network in
                guard let self = self else { return }
                
                var fetchedSSID: String? = network?.ssid
                var fetchedStrength: Double = network?.signalStrength ?? 0.0
                
                DataDonorLogger.shared.log("NetworkMonitor: NEHotspotNetwork fetched - SSID: \(fetchedSSID ?? "nil"), Strength: \(fetchedStrength)", level: .debug)
                
                #if targetEnvironment(simulator)
                // Provide a mock on simulator because NEHotspotNetwork returns nil
                if fetchedSSID == nil {
                    fetchedSSID = "Simulated_WiFi"
                    fetchedStrength = 0.85
                }
                #endif
                
                DispatchQueue.main.async {
                    self.currentSSID = fetchedSSID
                    self.currentSignalStrength = fetchedStrength
                    
                    if let ssid = fetchedSSID, !ssid.isEmpty {
                        self.isConnectedToTargetSSID = self.targetSSID.isEmpty || ssid == self.targetSSID
                    } else {
                        self.isConnectedToTargetSSID = self.targetSSID.isEmpty
                    }
                }
            }
        } else {
            // Fallback
            DispatchQueue.main.async {
                self.isConnectedToTargetSSID = self.targetSSID.isEmpty
            }
        }
    }
}
