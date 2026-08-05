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
        UserDefaults.standard.set(url.absoluteString, forKey: "lastActiveServerURL")
    }
}
