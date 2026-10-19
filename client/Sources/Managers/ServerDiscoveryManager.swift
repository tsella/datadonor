import Foundation
import Combine

class ServerDiscoveryManager: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    /// The server the user approved and we may talk to. Never set before approval —
    /// anything else would leak the API key to an unapproved (possibly spoofed) host.
    @Published var activeServerURL: URL?
    @Published var pendingApprovalURL: URL?

    private var browser: NetServiceBrowser
    private var resolvingServices: [NetService] = []
    
    override init() {
        self.browser = NetServiceBrowser()
        super.init()
        self.browser.delegate = self
    }
    
    func startDiscovery() {
        DataDonorLogger.shared.log("Discovery: searching for _datadonor._tcp in local.", level: .debug)
        browser.searchForServices(ofType: "_datadonor._tcp", inDomain: "local.")
    }
    
    func stopDiscovery() {
        DataDonorLogger.shared.log("Discovery: stopped.", level: .debug)
        browser.stop()
        resolvingServices.removeAll()
    }
    
    // MARK: - NetServiceBrowserDelegate
    
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        DataDonorLogger.shared.log("Discovery: browser will search.", level: .debug)
    }
    
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DataDonorLogger.shared.log("Discovery: browser stopped searching.", level: .debug)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        DataDonorLogger.shared.log("Discovery: browser did not search: \(errorDict)", level: .warn)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        DataDonorLogger.shared.log("Discovery: found \(service.name) (\(service.type), \(service.domain)).", level: .debug)
        service.delegate = self
        resolvingServices.append(service)
        DataDonorLogger.shared.log("Discovery: resolving \(service.name).", level: .debug)
        service.resolve(withTimeout: 5.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DataDonorLogger.shared.log("Discovery: removed \(service.name).", level: .debug)
        resolvingServices.removeAll(where: { $0 == service })
    }
    
    // MARK: - NetServiceDelegate
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else {
            DataDonorLogger.shared.log("Discovery: \(sender.name) resolved without a host name.", level: .warn)
            return
        }
        
        var cleanHost = hostName
        if cleanHost.hasSuffix(".") {
            cleanHost.removeLast()
        }
        
        let port = sender.port
        DataDonorLogger.shared.log("Discovery: resolved \(cleanHost):\(port).", level: .info)
        
        if let url = URL(string: "https://\(cleanHost):\(port)") {
            DataDonorLogger.shared.log("Discovery: candidate \(url.absoluteString).", level: .debug)
            DispatchQueue.main.async {
                if ServerResolver.isApproved(url) {
                    self.activeServerURL = url
                    ServerResolver.rememberActive(url)
                } else {
                    // Publish the pending server as plain state. The view derives alert
                    // presentation from "is something pending?", so re-proposing the same
                    // URL needs no transition and this can stay a straightforward assignment.
                    self.pendingApprovalURL = url
                }
            }
        }
        
        resolvingServices.removeAll(where: { $0 == sender })
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        DataDonorLogger.shared.log("Discovery: failed to resolve \(sender.name): \(errorDict)", level: .error)
        resolvingServices.removeAll(where: { $0 == sender })
    }
}
