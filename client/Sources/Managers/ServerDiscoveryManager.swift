import Foundation
import Combine

class ServerDiscoveryManager: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var activeServerURL: URL?
    @Published var pendingApprovalURL: URL?
    
    // Legacy support to prevent build errors immediately, though we'll remove uses of it
    @Published var resolvedURL: URL?
    
    private var browser: NetServiceBrowser
    private var resolvingServices: [NetService] = []
    
    override init() {
        self.browser = NetServiceBrowser()
        super.init()
        self.browser.delegate = self
    }
    
    func startDiscovery() {
        print("[Bonjour] Starting discovery for _datadonor._tcp in domain local.")
        browser.searchForServices(ofType: "_datadonor._tcp", inDomain: "local.")
    }
    
    func stopDiscovery() {
        print("[Bonjour] Stopping discovery.")
        browser.stop()
        resolvingServices.removeAll()
    }
    
    // MARK: - NetServiceBrowserDelegate
    
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        print("[Bonjour] Browser will search.")
    }
    
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("[Bonjour] Browser did stop search.")
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("[Bonjour] Browser did not search. Error: \(errorDict)")
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("[Bonjour] Found service: \(service.name) (type: \(service.type), domain: \(service.domain))")
        service.delegate = self
        resolvingServices.append(service)
        print("[Bonjour] Attempting to resolve service: \(service.name)")
        service.resolve(withTimeout: 5.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        print("[Bonjour] Removed service: \(service.name)")
        resolvingServices.removeAll(where: { $0 == service })
    }
    
    // MARK: - NetServiceDelegate
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else {
            print("[Bonjour] Service resolved but hostName is nil: \(sender.name)")
            return
        }
        
        var cleanHost = hostName
        if cleanHost.hasSuffix(".") {
            cleanHost.removeLast()
        }
        
        let port = sender.port
        print("[Bonjour] Service resolved successfully! Host: \(cleanHost), Port: \(port)")
        
        if let url = URL(string: "https://\(cleanHost):\(port)") {
            print("[Bonjour] Constructed URL: \(url.absoluteString)")
            DispatchQueue.main.async {
                self.resolvedURL = url // Keep for Dashboard fetch stats backward compatibility until updated
                
                let urlStr = url.absoluteString
                let approvedServers = UserDefaults.standard.stringArray(forKey: "approvedServers") ?? []
                
                if approvedServers.contains(urlStr) {
                    self.activeServerURL = url
                } else {
                    self.pendingApprovalURL = url
                }
            }
        }
        
        resolvingServices.removeAll(where: { $0 == sender })
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("[Bonjour] Failed to resolve service \(sender.name). Error: \(errorDict)")
        resolvingServices.removeAll(where: { $0 == sender })
    }
}
