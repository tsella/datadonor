import Foundation
import Combine

class ServerDiscoveryManager: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var resolvedURL: URL?
    
    private var browser: NetServiceBrowser
    private var resolvingServices: [NetService] = []
    
    override init() {
        self.browser = NetServiceBrowser()
        super.init()
        self.browser.delegate = self
    }
    
    func startDiscovery() {
        browser.searchForServices(ofType: "_datadonor._tcp", inDomain: "local.")
    }
    
    func stopDiscovery() {
        browser.stop()
        resolvingServices.removeAll()
    }
    
    // MARK: - NetServiceBrowserDelegate
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 5.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvingServices.removeAll(where: { $0 == service })
    }
    
    // MARK: - NetServiceDelegate
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else { return }
        
        var cleanHost = hostName
        if cleanHost.hasSuffix(".") {
            cleanHost.removeLast()
        }
        
        let port = sender.port
        if let url = URL(string: "https://\(cleanHost):\(port)") {
            DispatchQueue.main.async {
                self.resolvedURL = url
            }
        }
        
        resolvingServices.removeAll(where: { $0 == sender })
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        resolvingServices.removeAll(where: { $0 == sender })
    }
}
