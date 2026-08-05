import Foundation
import CryptoKit
import Security

/// Pins self-signed server certificates on first approval.
///
/// The server uses a self-signed certificate, so the system's trust evaluation can never
/// succeed. Rather than accepting every certificate from every host, we record the public
/// key hash the first time we connect to a host the user approved, and require that same
/// key on every later connection. That turns an ongoing "trust anything" exception into a
/// one-time trust-on-first-use decision scoped to approved servers.
final class ServerTrustStore: @unchecked Sendable {
    static let shared = ServerTrustStore()

    enum Evaluation {
        case trusted
        case rejected(String)
    }

    private let pinsKey = "pinnedServerKeys"
    private let approvedKey = "approvedServers"
    private let lock = NSLock()

    private init() {}

    /// Hosts the user approved, derived from the stored approved-server URLs.
    private func approvedHosts() -> Set<String> {
        let urls = UserDefaults.standard.stringArray(forKey: approvedKey) ?? []
        return Set(urls.compactMap { URL(string: $0)?.host })
    }

    private func pins() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
    }

    private func store(pin: String, for host: String) {
        var current = pins()
        current[host] = pin
        UserDefaults.standard.set(current, forKey: pinsKey)
    }

    /// Removes the pin for a host, so a rotated certificate can be re-trusted on next
    /// connection. Called when the user removes a server from the approved list.
    func forget(host: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = pins()
        current.removeValue(forKey: host)
        UserDefaults.standard.set(current, forKey: pinsKey)
    }

    func evaluate(serverTrust: SecTrust, host: String) -> Evaluation {
        lock.lock()
        defer { lock.unlock() }

        guard approvedHosts().contains(host) else {
            return .rejected("host is not in the approved server list")
        }

        guard let fingerprint = publicKeyHash(for: serverTrust) else {
            return .rejected("could not read the server's public key")
        }

        if let existing = pins()[host] {
            guard existing == fingerprint else {
                return .rejected(
                    "certificate changed since it was approved (expected \(existing.prefix(16))…, got \(fingerprint.prefix(16))…)")
            }
            return .trusted
        }

        // Trust on first use: the user just approved this server, so adopt its key.
        store(pin: fingerprint, for: host)
        DataDonorLogger.shared.log(
            "Pinned certificate for \(host): \(fingerprint.prefix(16))…", level: .info)
        return .trusted
    }

    /// SHA-256 over the DER-encoded public key of the leaf certificate.
    private func publicKeyHash(for serverTrust: SecTrust) -> String? {
        guard let key = SecTrustCopyKey(serverTrust),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return nil
        }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }
}
