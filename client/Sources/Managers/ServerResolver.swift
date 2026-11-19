import Foundation
import Security

/// Single source of truth for "which server should we talk to?" and server credentials.
///
/// Previously the dashboard, the sync button, and the background task each answered this
/// differently, so the UI could report a server the sync path never used. `URL(string:)`
/// alone is not enough: it happily returns a non-nil relative URL for input like
/// "192.168.1.5:8443" or "myserver", which then takes precedence over a valid discovered
/// server and fails every request with an opaque error.
enum ServerResolver {

    // MARK: - API Key (Keychain-backed with UserDefaults migration)

    private static let keychainService = "la.tsel.datadonor"
    private static let keychainAccount = "apiKey"
    private static let legacyApiKeyDefaultsKey = "apiKey"

    /// Reads the API key from the Keychain, migrating any legacy plaintext value from
    /// `UserDefaults` on first access. Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    /// so background sync tasks can read the key while the device is locked.
    static func loadApiKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8),
           !key.isEmpty {
            // Clean up any leftover plaintext copy in UserDefaults.
            if UserDefaults.standard.string(forKey: legacyApiKeyDefaultsKey) != nil {
                UserDefaults.standard.removeObject(forKey: legacyApiKeyDefaultsKey)
            }
            return key
        }

        // One-time migration from legacy UserDefaults storage.
        if let legacy = UserDefaults.standard.string(forKey: legacyApiKeyDefaultsKey),
           !legacy.isEmpty {
            saveApiKey(legacy)
            UserDefaults.standard.removeObject(forKey: legacyApiKeyDefaultsKey)
            return legacy
        }
        return ""
    }

    static func saveApiKey(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyApiKeyDefaultsKey)

        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    // MARK: - URL Resolution

    /// Parses a user-entered override, rejecting anything that isn't a usable absolute URL.
    static func parseOverride(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    /// True when the user typed something in the override field that we cannot use.
    static func overrideIsInvalid(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parseOverride(raw) == nil
    }

    /// The effective server: a valid override wins, otherwise the approved discovered server.
    static func resolve(override: String, discovered: URL?) -> URL? {
        parseOverride(override) ?? discovered
    }

    /// Resolution for contexts with no access to the discovery manager (the background
    /// task). Falls back to the last server the user approved and we successfully reached.
    static func resolveFromDefaults() -> URL? {
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: "customServerURL") ?? ""
        if let parsed = parseOverride(override) {
            return parsed
        }
        if let last = defaults.string(forKey: "lastActiveServerURL") {
            return parseOverride(last)
        }
        return nil
    }

    /// Records a server the user approved so background syncs can reach it later.
    static func rememberActive(_ url: URL) {
        UserDefaults.standard.set(canonical(url), forKey: "lastActiveServerURL")
    }

    // MARK: - Approved servers & cached LAN IPs

    private static let approvedKey = "approvedServers"
    /// Maps canonical approved hostnames (e.g. "mac.lan") to their last resolved IP
    /// (e.g. "192.168.1.42"). iOS throttles mDNS multicast lookups in background tasks,
    /// so falling back to the cached IP lets background syncs connect immediately while
    /// still requiring the approved hostname's pinned TLS public key.
    private static let cachedHostIPsKey = "cachedServerHostIPs"

    /// The canonical string form of a server URL.
    ///
    /// Hostnames are case-insensitive, but Bonjour reports whatever casing the service
    /// advertises (`Mac.lan`) while URLSession lowercases the host before the TLS challenge
    /// (`mac.lan`). Comparing raw strings therefore treats one server as two. Everything
    /// that stores or compares a server URL goes through here so the distinction cannot
    /// leak into storage in the first place.
    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url?.absoluteString ?? url.absoluteString.lowercased()
    }

    /// Canonical host, for keying per-server state such as pinned certificates.
    static func canonicalHost(_ host: String) -> String {
        host.lowercased()
    }

    static func approvedServers() -> [String] {
        UserDefaults.standard.stringArray(forKey: approvedKey) ?? []
    }

    static func isApproved(_ url: URL) -> Bool {
        let target = canonical(url)
        return approvedServers().contains { $0.lowercased() == target }
    }

    /// Hosts the user approved (including any explicit custom override URL), canonicalized
    /// for comparison against a TLS challenge host.
    static func approvedHosts() -> Set<String> {
        var hosts = Set(approvedServers().compactMap { URL(string: $0)?.host.map(canonicalHost) })
        let override = UserDefaults.standard.string(forKey: "customServerURL") ?? ""
        if let overrideHost = parseOverride(override)?.host {
            hosts.insert(canonicalHost(overrideHost))
        }
        return hosts
    }

    /// Records the resolved IP address for an approved hostname so background syncs can
    /// fall back to direct IP when iOS throttles mDNS (`.local`/`.lan`) resolution.
    static func rememberResolvedIP(_ ip: String, for url: URL) {
        guard let host = url.host else { return }
        let normalizedHost = canonicalHost(host)
        let normalizedIP = canonicalHost(ip)
        guard !normalizedIP.isEmpty, normalizedIP != normalizedHost else { return }
        var map = UserDefaults.standard.dictionary(forKey: cachedHostIPsKey) as? [String: String] ?? [:]
        if map[normalizedHost] != normalizedIP {
            map[normalizedHost] = normalizedIP
            UserDefaults.standard.set(map, forKey: cachedHostIPsKey)
        }
    }

    /// Returns a URL pointing directly to the cached IP for `url`'s host (preserving scheme
    /// and port), or nil if none is cached or `url` already uses that IP.
    static func cachedFallbackURL(for url: URL) -> URL? {
        guard let host = url.host else { return nil }
        let normalizedHost = canonicalHost(host)
        let map = UserDefaults.standard.dictionary(forKey: cachedHostIPsKey) as? [String: String] ?? [:]
        guard let cachedIP = map[normalizedHost], !cachedIP.isEmpty, cachedIP != normalizedHost else {
            return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.host = cachedIP
        return components.url
    }

    /// Resolves a TLS challenge host to the approved logical host whose pin should be checked.
    /// Returns `(logicalHost, viaCachedIP)` or `nil` if the host is not approved.
    static func approvedHost(forChallengeHost challengeHost: String) -> (logicalHost: String, viaCachedIP: Bool)? {
        let target = canonicalHost(challengeHost)
        let approved = approvedHosts()
        if approved.contains(target) {
            return (target, false)
        }
        let map = UserDefaults.standard.dictionary(forKey: cachedHostIPsKey) as? [String: String] ?? [:]
        for (logicalHost, cachedIP) in map where approved.contains(logicalHost) {
            // URLSession strips brackets from IPv6 hosts in protectionSpace.host.
            let bareCachedIP = cachedIP.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if canonicalHost(bareCachedIP) == target {
                return (logicalHost, true)
            }
        }
        return nil
    }

    /// True when the host is clearly on a local network (mDNS `.local`/`.lan`, single-label
    /// hostname, or RFC1918 private IPv4), so pure cellular without VPN cannot reach it.
    static func isLocalOnlyHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home") || !host.contains(".") {
            return true
        }
        // RFC1918 private IPv4 ranges
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return true
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// Adds a server to the approved list. Idempotent across casing differences.
    static func approve(_ url: URL) {
        guard !isApproved(url) else { return }
        UserDefaults.standard.set(approvedServers() + [canonical(url)], forKey: approvedKey)
    }

    /// Removes every stored entry for this server, including differently-cased ones written
    /// by older builds, and stops the app dialling it again.
    ///
    /// Dropping the entry alone was not enough: `resolveFromDefaults` prefers the typed
    /// override and then the remembered active server, so both kept pointing at a host whose
    /// pin had just been forgotten. Every background sync then failed the TLS check with
    /// nothing surfaced to the user.
    static func revokeApproval(matchingHost host: String) {
        let target = canonicalHost(host)
        let remaining = approvedServers().filter {
            URL(string: $0)?.host.map(canonicalHost) != target
        }
        UserDefaults.standard.set(remaining, forKey: approvedKey)

        let defaults = UserDefaults.standard
        for key in ["lastActiveServerURL", "customServerURL"] {
            guard let stored = defaults.string(forKey: key),
                  URL(string: stored)?.host.map(canonicalHost) == target else { continue }
            defaults.removeObject(forKey: key)
        }

        if var map = defaults.dictionary(forKey: cachedHostIPsKey) as? [String: String] {
            map.removeValue(forKey: target)
            defaults.set(map, forKey: cachedHostIPsKey)
        }
    }
}
