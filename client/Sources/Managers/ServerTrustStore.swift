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
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var cachedPins: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cachedPins = defaults.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
    }

    private func pins() -> [String: String] {
        cachedPins
    }

    /// `UserDefaults` is thread-safe; persisting synchronously under `lock` keeps storage
    /// strictly ordered with in-memory pin updates and revocations across URLSession and UI threads.
    private func persistLocked() {
        defaults.set(cachedPins, forKey: pinsKey)
    }

    internal func storePinForTesting(_ pin: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        store(pin: pin, for: host)
    }

    internal func storedPin(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedPins[normalize(host)]
    }

    private func store(pin: String, for host: String) {
        cachedPins[normalize(host)] = pin
        persistLocked()
    }

    /// Hostnames are case-insensitive, and the two sides disagree in practice: Bonjour
    /// advertises `Mac.lan` while URLSession lowercases to `mac.lan` for the TLS challenge.
    /// `ServerResolver` owns that canonical form so approval, pinning and discovery cannot
    /// drift apart.
    private func normalize(_ host: String) -> String {
        ServerResolver.canonicalHost(host)
    }

    /// Removes the pin for a host, so a rotated certificate can be re-trusted on next
    /// connection. Called when the user removes a server from the approved list.
    func forget(host: String) {
        lock.lock()
        defer { lock.unlock() }
        // Drop every entry matching case-insensitively: pins written by older builds were
        // keyed by the raw host, so a stale `Mac.lan` entry can sit beside `mac.lan`.
        let target = normalize(host)
        cachedPins = cachedPins.filter { normalize($0.key) != target }
        persistLocked()
    }

    func evaluate(serverTrust: SecTrust, host: String) -> Evaluation {
        lock.lock()
        defer { lock.unlock() }

        guard let match = ServerResolver.approvedHost(forChallengeHost: host) else {
            return .rejected("host is not in the approved server list")
        }

        let logicalHost = match.logicalHost

        guard let fingerprint = publicKeyHash(for: serverTrust) else {
            return .rejected("could not read the server's public key")
        }

        if let existing = pins()[logicalHost] {
            guard existing == fingerprint else {
                return .rejected(
                    "certificate changed since it was approved (expected \(existing.prefix(16))…, got \(fingerprint.prefix(16))…)")
            }
            return .trusted
        }

        // Never trust-on-first-use via a cached fallback IP: a different machine could
        // hold that DHCP address on another network. Require an already-established pin.
        guard !match.viaCachedIP else {
            return .rejected("cached IP fallback requires an existing certificate pin for \(logicalHost)")
        }

        // Trust on first use: the user just approved this server, so adopt its key.
        store(pin: fingerprint, for: logicalHost)
        DataDonorLogger.shared.log(
            "Pinned certificate for \(logicalHost): \(fingerprint.prefix(16))…", level: .info)
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
