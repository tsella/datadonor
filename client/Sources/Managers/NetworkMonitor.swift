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
        locationManager.delegate = self
        // iOS requires location permission to read the Wi-Fi SSID
        locationManager.requestWhenInUseAuthorization()
        
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status == .satisfied {
                self.checkSSID()
            } else {
                DispatchQueue.main.async {
                    self.currentSSID = nil
                    self.currentSignalStrength = 0.0
                    self.isConnectedToTargetSSID = false
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    func checkSSID() {
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { [weak self] network in
                guard let self = self else { return }
                
                var fetchedSSID: String? = network?.ssid
                var fetchedStrength: Double = network?.signalStrength ?? 0.0
                
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
