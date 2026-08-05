import Foundation

/// Records background uploads the server acknowledged while nothing was awaiting them.
///
/// A background `URLSession` keeps uploading after the app is suspended or killed, so a
/// batch can be committed by the server with no in-process waiter left to hear about it.
/// Before this store existed the delegate resumed a `nil` continuation — a silent no-op —
/// and the client re-sent a batch the server already had, forever, because the anchor
/// never advanced.
///
/// Only acknowledgements are persisted. A merely-started or failed upload needs no record:
/// the anchor simply stays put and the batch is retried, which is already the correct
/// behaviour. Keeping the stored set to "server confirmed this" keeps writes off the
/// per-upload hot path — it is written once per orphaned upload rather than once per
/// upload — and makes the absence of an entry unambiguous.
final class OrphanedUploadStore {
    private let defaultsKey = "acknowledgedOrphanedUploads"
    private let lock = NSLock()
    private let defaults: UserDefaults

    /// Entries older than this are pruned so a crash loop cannot grow the map without
    /// bound. Pruning happens on write, which is rare.
    private let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// token → acknowledgement timestamp.
    private func load() -> [String: Double] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }

    func recordSuccess(token: String) {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().timeIntervalSince1970 - staleAfter
        var map = load().filter { $0.value >= cutoff }
        map[token] = Date().timeIntervalSince1970
        defaults.set(map, forKey: defaultsKey)
    }

    /// True only when the server confirmed the batch with a 2xx. An interrupted upload may
    /// never have reached the server, so treating it as delivered would advance the anchor
    /// past unsent data.
    func wasAcknowledged(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return load()[token] != nil
    }

    func forget(token: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = load()
        guard map.removeValue(forKey: token) != nil else { return }
        defaults.set(map, forKey: defaultsKey)
    }
}
