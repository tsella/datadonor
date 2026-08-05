import Foundation

/// Single source of truth for "which server should we talk to?".
///
/// Previously the dashboard, the sync button, and the background task each answered this
/// differently, so the UI could report a server the sync path never used. `URL(string:)`
/// alone is not enough: it happily returns a non-nil relative URL for input like
/// "192.168.1.5:8443" or "myserver", which then takes precedence over a valid discovered
/// server and fails every request with an opaque error.
enum ServerResolver {

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

    // MARK: - Approved servers

    private static let approvedKey = "approvedServers"

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

    /// Hosts the user approved, canonicalized for comparison against a TLS challenge host.
    static func approvedHosts() -> Set<String> {
        Set(approvedServers().compactMap { URL(string: $0)?.host.map(canonicalHost) })
    }

    /// Adds a server to the approved list. Idempotent across casing differences.
    static func approve(_ url: URL) {
        guard !isApproved(url) else { return }
        UserDefaults.standard.set(approvedServers() + [canonical(url)], forKey: approvedKey)
    }

    /// Removes every stored entry for this server, including differently-cased ones written
    /// by older builds.
    static func revokeApproval(matchingHost host: String) {
        let target = canonicalHost(host)
        let remaining = approvedServers().filter {
            URL(string: $0)?.host.map(canonicalHost) != target
        }
        UserDefaults.standard.set(remaining, forKey: approvedKey)
    }
}
