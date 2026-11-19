import Foundation
import Combine
import Darwin

@MainActor
class ServerDiscoveryManager: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    enum DiscoveryState: Equatable {
        case idle
        case searching
        case stopping
        case restarting
    }

    /// The server the user approved and we may talk to. Never set before approval —
    /// anything else would leak the API key to an unapproved (possibly spoofed) host.
    @Published var activeServerURL: URL?
    @Published var pendingApprovalURL: URL?
    @Published private(set) var state: DiscoveryState = .idle

    private var browser: NetServiceBrowser
    private var resolvingServices: [NetService] = []
    /// Most recently resolved numeric IP per canonical server URL, kept so approving a
    /// pending server also persists its IP fallback for background syncs.
    private var resolvedIPsByURL: [String: String] = [:]

    override init() {
        self.browser = NetServiceBrowser()
        super.init()
        self.browser.delegate = self
    }

    func startDiscovery() {
        switch state {
        case .idle:
            state = .searching
            DataDonorLogger.shared.log("Discovery: searching for _datadonor._tcp in local.", level: .debug)
            browser.searchForServices(ofType: "_datadonor._tcp", inDomain: "local.")
        case .stopping:
            // NetServiceBrowser.stop() completes asynchronously via didStopSearch. Wait
            // for that callback instead of calling searchForServices early (which fails
            // with NSNetServicesActivityInProgress).
            state = .restarting
            DataDonorLogger.shared.log("Discovery: queued restart while browser is stopping.", level: .debug)
        case .searching, .restarting:
            return
        }
    }

    func stopDiscovery() {
        switch state {
        case .searching:
            state = .stopping
            DataDonorLogger.shared.log("Discovery: stopping.", level: .debug)
            cancelResolvingServices()
            browser.stop()
        case .restarting:
            state = .stopping
            DataDonorLogger.shared.log("Discovery: cancelled pending restart.", level: .debug)
        case .idle, .stopping:
            return
        }
    }

    private func cancelResolvingServices() {
        for service in resolvingServices {
            service.delegate = nil
            service.stop()
        }
        resolvingServices.removeAll()
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        DataDonorLogger.shared.log("Discovery: browser will search.", level: .debug)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DataDonorLogger.shared.log("Discovery: browser stopped searching.", level: .debug)
        switch state {
        case .restarting:
            state = .searching
            DataDonorLogger.shared.log("Discovery: restarting search for _datadonor._tcp in local.", level: .debug)
            browser.searchForServices(ofType: "_datadonor._tcp", inDomain: "local.")
        case .stopping, .searching, .idle:
            state = .idle
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        state = .idle
        DataDonorLogger.shared.log("Discovery: browser did not search: \(errorDict)", level: .warn)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard state == .searching else { return }
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
        resolvingServices.removeAll(where: { $0 == sender })
        guard let hostName = sender.hostName else {
            DataDonorLogger.shared.log("Discovery: \(sender.name) resolved without a host name.", level: .warn)
            return
        }
        let resolvedIP = Self.extractIPAddress(from: sender.addresses)
        handleResolvedEndpoint(hostName: hostName, port: sender.port, resolvedIP: resolvedIP)
    }

    internal func handleResolvedEndpoint(hostName: String, port: Int, resolvedIP: String?) {
        // Drop late resolutions that arrive after stopDiscovery() so backgrounding cannot
        // publish activeServerURL and kick off a foreground sync.
        guard state == .searching else {
            DataDonorLogger.shared.log("Discovery: ignoring late resolution for \(hostName) while \(state).", level: .debug)
            return
        }

        var cleanHost = hostName
        if cleanHost.hasSuffix(".") {
            cleanHost.removeLast()
        }

        DataDonorLogger.shared.log(
            "Discovery: resolved \(cleanHost):\(port)\(resolvedIP.map { " (\($0))" } ?? "").",
            level: .info)

        guard let url = URL(string: "https://\(cleanHost):\(port)") else { return }
        DataDonorLogger.shared.log("Discovery: candidate \(url.absoluteString).", level: .debug)
        let canonicalURL = ServerResolver.canonical(url)

        if let resolvedIP {
            resolvedIPsByURL[canonicalURL] = resolvedIP
        }
        if ServerResolver.isApproved(url) {
            activeServerURL = url
            ServerResolver.rememberActive(url)
            if let resolvedIP {
                ServerResolver.rememberResolvedIP(resolvedIP, for: url)
            }
        } else {
            pendingApprovalURL = url
        }
    }

    /// Approves the currently pending discovered server, persists it as active, and stores
    /// its resolved IP fallback for background syncs.
    func approvePendingServer() {
        guard let url = pendingApprovalURL else { return }
        ServerResolver.approve(url)
        activeServerURL = url
        ServerResolver.rememberActive(url)
        if let ip = resolvedIPsByURL[ServerResolver.canonical(url)] {
            ServerResolver.rememberResolvedIP(ip, for: url)
        }
        pendingApprovalURL = nil
    }

    private static func extractIPAddress(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        var ipv6Fallback: String?
        for addressData in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result: Int32 = addressData.withUnsafeBytes { rawBuffer in
                guard let sockaddrPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                    return -1
                }
                let family = Int32(sockaddrPtr.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6 else { return -1 }
                return getnameinfo(
                    sockaddrPtr,
                    socklen_t(addressData.count),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            if !ip.contains(":") {
                return ip
            } else if !ip.hasPrefix("fe80:") && ipv6Fallback == nil {
                ipv6Fallback = "[\(ip)]"
            }
        }
        return ipv6Fallback
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        DataDonorLogger.shared.log("Discovery: failed to resolve \(sender.name): \(errorDict)", level: .error)
        resolvingServices.removeAll(where: { $0 == sender })
    }
}
