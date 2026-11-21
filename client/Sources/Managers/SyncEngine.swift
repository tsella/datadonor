import Foundation
import CryptoKit
import zlib

struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

class SyncEngine: NSObject, URLSessionDelegate, ObservableObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    /// Selects how uploads are dispatched:
    /// - `immediate`: in-process `ephemeral` session. Must be used during background wakes
    ///   (`HKObserverQuery`, `BGAppRefreshTask`, `BGProcessingTask`) because iOS forces any
    ///   `URLSessionConfiguration.background` task started while backgrounded to
    ///   `isDiscretionary = true`, stalling `await` until the background window expires.
    /// - `background`: out-of-process `URLSessionConfiguration.background` session. Used for
    ///   foreground-initiated syncs/backfills where `isDiscretionary = false` is honored and
    ///   uploads should keep running if the user switches away.
    enum Transport: Sendable {
        case immediate
        case background
    }

    /// Pairs a deterministic batch token (shared across retries of the same un-advanced
    /// HealthKit anchor) with a unique per-attempt ID so overlapping attempts never collide
    /// on staging files, response bodies, or continuations.
    struct UploadTaskIdentity: Equatable, Sendable {
        let batchToken: String
        let attemptId: String

        var taskDescription: String { "\(batchToken)|\(attemptId)" }

        init(batchToken: String, attemptId: String = UUID().uuidString) {
            self.batchToken = batchToken
            self.attemptId = attemptId
        }

        init?(taskDescription: String?) {
            guard let desc = taskDescription, !desc.isEmpty else { return nil }
            if let sep = desc.lastIndex(of: "|") {
                let batch = String(desc[..<sep])
                let attempt = String(desc[desc.index(after: sep)...])
                guard !batch.isEmpty, !attempt.isEmpty else { return nil }
                self.batchToken = batch
                self.attemptId = attempt
            } else {
                // Backward compatibility for legacy pre-upgrade in-flight tasks.
                self.batchToken = desc
                self.attemptId = desc
            }
        }
    }

    private var session: URLSession!
    private var ephemeralSession: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?
    private var pendingBackgroundEventsFinished = false

    /// Continuations for in-flight uploads, keyed by per-attempt `attemptId` (not by
    /// `taskIdentifier`, which resets across relaunch, and not by `batchToken`, which
    /// collides across retries of the same un-advanced anchor).
    private var pendingUploads: [String: CheckedContinuation<Void, Error>] = [:]
    /// Response bodies accumulated per `attemptId`, so overlapping retries never interleave.
    private var responseBodies: [String: Data] = [:]
    /// Temp payload files owned by each `attemptId`, deleted only when that attempt finishes.
    private var payloadFiles: [String: URL] = [:]
    /// Attempt IDs whose `onCancel` fired before continuation registration completed.
    private var cancelledAttempts: Set<String> = []
    private let stateLock = NSLock()

    /// Uploads that were in flight when the process died. A background session keeps
    /// uploading across app termination, so on relaunch the task completes with nobody
    /// waiting on it. Recording the outcome here lets the next sync tell "the server
    /// accepted this batch" apart from "this batch never went out".
    internal let orphanStore: OrphanedUploadStore

    /// Reads the batch/attempt identity attached at creation time. Returns nil for the
    /// ephemeral session's tasks, which don't participate in background-session bookkeeping.
    private func identity(for task: URLSessionTask) -> UploadTaskIdentity? {
        UploadTaskIdentity(taskDescription: task.taskDescription)
    }

    /// Scoped access to the state guarded by `stateLock`.
    ///
    /// `NSLock.lock()`/`unlock()` are unavailable from async contexts (an error under the
    /// Swift 6 language mode) because a suspension while holding the lock can resume on a
    /// different thread. This wrapper is non-async and does all its work synchronously, so
    /// it is safe to call from `async` code: no await can occur inside the critical section.
    @discardableResult
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Hosts the user has explicitly approved, with the SPKI hash pinned on first contact.
    private let trustStore: ServerTrustStore

    convenience override init() {
        self.init(
            sessionIdentifier: "la.tsel.datadonor.sync",
            orphanStore: OrphanedUploadStore(),
            trustStore: .shared
        )
    }

    init(
        sessionIdentifier: String,
        orphanStore: OrphanedUploadStore = OrphanedUploadStore(),
        trustStore: ServerTrustStore = .shared,
        createBackgroundSession: Bool = true
    ) {
        self.orphanStore = orphanStore
        self.trustStore = trustStore
        super.init()

        if createBackgroundSession {
            let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            configuration.isDiscretionary = false // Honored for foreground-initiated syncs
            configuration.sessionSendsLaunchEvents = true
            self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        } else {
            self.session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        }

        let ephemeralConfig = URLSessionConfiguration.ephemeral
        self.ephemeralSession = URLSession(configuration: ephemeralConfig, delegate: self, delegateQueue: nil)

        Self.pruneStaleTempFiles()
    }

    /// Attaches the system completion handler from `handleEventsForBackgroundURLSession`.
    /// Handles both arrival orders (handler set before or after `urlSessionDidFinishEvents`)
    /// and invokes any uncalled prior handler rather than leaking it.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        let toInvokeNow: [() -> Void] = withState {
            var callbacks: [() -> Void] = []
            if let previous = backgroundCompletionHandler {
                callbacks.append(previous)
                backgroundCompletionHandler = nil
            }
            if pendingBackgroundEventsFinished {
                pendingBackgroundEventsFinished = false
                callbacks.append(handler)
            } else {
                backgroundCompletionHandler = handler
            }
            return callbacks
        }
        if !toInvokeNow.isEmpty {
            DispatchQueue.main.async {
                for cb in toInvokeNow { cb() }
            }
        }
    }

    /// Cleans up any staged `.json` / `.json.gz` upload files left behind in `temporaryDirectory`
    /// from crashes older than 24 hours.
    private static func pruneStaleTempFiles() {
        DispatchQueue.global(qos: .utility).async {
            let tempDir = FileManager.default.temporaryDirectory
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: tempDir, includingPropertiesForKeys: [.creationDateKey]
            ) else { return }

            for file in files where file.lastPathComponent.hasSuffix(".json") || file.lastPathComponent.hasSuffix(".json.gz") {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let created = attrs[.creationDate] as? Date,
                   created < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Self-signed certificates are expected here, so the system trust evaluation will
        // always fail. Instead we pin: the first time we talk to an approved host we record
        // its public key hash, and every later connection must present the same key.
        switch trustStore.evaluate(serverTrust: serverTrust, host: host) {
        case .trusted:
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .rejected(let reason):
            DataDonorLogger.shared.log(
                "SyncEngine: Rejected TLS connection to \(host): \(reason)", level: .error)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        handleBackgroundEventsFinished()
    }

    internal func handleBackgroundEventsFinished() {
        DataDonorLogger.shared.log("SyncEngine: All background events finished.", level: .info)
        let handler: (() -> Void)? = withState {
            if let existing = backgroundCompletionHandler {
                backgroundCompletionHandler = nil
                pendingBackgroundEventsFinished = false
                return existing
            }
            pendingBackgroundEventsFinished = true
            return nil
        }
        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let identity = identity(for: dataTask) else { return }
        handleUploadData(data, for: identity)
    }

    internal func handleUploadData(_ data: Data, for identity: UploadTaskIdentity) {
        withState { responseBodies[identity.attemptId, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let identity = identity(for: task) else { return }
        handleUploadCompletion(
            for: identity,
            httpResponse: task.response as? HTTPURLResponse,
            error: error
        )
    }

    /// Registers a background upload attempt under `identity.attemptId`. Returns `false` if
    /// cancellation already landed before registration, in which case the caller must abort
    /// without starting the task.
    internal func registerUploadAttempt(
        identity: UploadTaskIdentity,
        fileURL: URL,
        continuation: CheckedContinuation<Void, Error>,
        isTaskCancelled: Bool
    ) -> Bool {
        withState {
            if cancelledAttempts.remove(identity.attemptId) != nil || isTaskCancelled {
                return false
            }
            pendingUploads[identity.attemptId] = continuation
            payloadFiles[identity.attemptId] = fileURL
            return true
        }
    }

    /// Cancels an upload attempt's waiter. If called before `registerUploadAttempt`, records
    /// the attempt ID in `cancelledAttempts` so registration aborts immediately instead of
    /// hanging.
    internal func cancelUploadAttempt(attemptId: String) {
        let continuation: CheckedContinuation<Void, Error>? = withState {
            if let existing = pendingUploads.removeValue(forKey: attemptId) {
                return existing
            }
            cancelledAttempts.insert(attemptId)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    internal func handleUploadCompletion(
        for identity: UploadTaskIdentity,
        httpResponse: HTTPURLResponse?,
        error: Error?
    ) {
        let (continuation, body, payloadFile) = withState {
            (pendingUploads.removeValue(forKey: identity.attemptId),
             responseBodies.removeValue(forKey: identity.attemptId),
             payloadFiles.removeValue(forKey: identity.attemptId))
        }

        if let payloadFile = payloadFile {
            try? FileManager.default.removeItem(at: payloadFile)
        }

        // No continuation means the caller cancelled or the process died while this upload
        // was in flight. A 2xx here is recorded under the deterministic `batchToken` so the
        // next sync advances the anchor instead of resending blind.
        let isOrphan = continuation == nil

        if let error = error {
            DataDonorLogger.shared.log(
                "SyncEngine: Upload \(identity.batchToken.prefix(12))… [\(identity.attemptId.prefix(8))] failed with error: \(error.localizedDescription)", level: .error)
            continuation?.resume(throwing: error)
            return
        }

        guard let response = httpResponse else {
            let err = SyncError(message: "Upload finished with no HTTP response")
            DataDonorLogger.shared.log("SyncEngine: Upload \(identity.batchToken.prefix(12))… \(err.message)", level: .error)
            continuation?.resume(throwing: err)
            return
        }

        if (200...299).contains(response.statusCode) {
            DataDonorLogger.shared.log(
                "SyncEngine: Upload \(identity.batchToken.prefix(12))… completed successfully (Status: \(response.statusCode))", level: .info)
            if isOrphan {
                DataDonorLogger.shared.log(
                    "SyncEngine: Upload \(identity.batchToken.prefix(12))… completed with no waiter; " +
                    "recording server acknowledgement.", level: .warn)
                orphanStore.recordSuccess(token: identity.batchToken)
            }
            continuation?.resume(returning: ())
        } else {
            let detail = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let err = SyncError(message: "Server returned status \(response.statusCode). \(detail)")
            DataDonorLogger.shared.log("SyncEngine: Upload \(identity.batchToken.prefix(12))… \(err.message)", level: .error)
            continuation?.resume(throwing: err)
        }
    }

    // MARK: - Requests

    /// The one place the wire contract is written. Four callers used to repeat the bearer
    /// header, the device header and the cache policy, so a new required header meant four
    /// edits and one of them was always missed.
    private func makeRequest(
        url: URL,
        method: String,
        apiKey: String,
        deviceId: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = cachePolicy
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let deviceId {
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        }
        return request
    }

    func fetchServerCheckpoint(serverURL: URL, apiKey: String, deviceId: String, timeout: TimeInterval = 15) async throws -> (checkpoints: [String: String], totalRecords: Int)? {
        let url = serverURL.appendingPathComponent("/api/v1/health-sync/checkpoint")
        var request = makeRequest(url: url, method: "GET", apiKey: apiKey, deviceId: deviceId)
        request.timeoutInterval = timeout

        let (data, response) = try await ephemeralSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let checkpoints = json["checkpoints"] as? [String: String] {
                let totalRecords = json["total_records"] as? Int ?? 0
                return (checkpoints: checkpoints, totalRecords: totalRecords)
            }
        }
        return nil
    }

    func ping(url: URL, apiKey: String, timeout: TimeInterval = 5) async throws -> Bool {
        var request = makeRequest(
            url: url.appendingPathComponent("/api/v1/ping"), method: "GET", apiKey: apiKey)
        request.timeoutInterval = timeout

        let (_, response) = try await ephemeralSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }

    /// gzip-compresses `data` using zlib's deflate with a gzip wrapper (windowBits 15+16).
    /// Returns nil on any failure so the caller can fall back to the uncompressed body.
    static func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        // 8 = default memLevel, Z_DEFLATED = method. windowBits 15|16 selects a gzip
        // header rather than raw zlib, which is what Content-Encoding: gzip means.
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        // `deflateBound` is the worst-case compressed size, so one buffer of that size
        // always holds the whole result and a single Z_FINISH completes the stream. No
        // append loop, and no repeated reallocation of a growing Data.
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))

        let result: Int32 = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Z_ERRNO }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            return output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int32 in
                guard let outBase = out.bindMemory(to: UInt8.self).baseAddress else { return Z_ERRNO }
                stream.next_out = outBase
                stream.avail_out = uInt(out.count)
                return deflate(&stream, Z_FINISH)
            }
        }

        guard result == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    /// Deterministic upload token for a HealthKit batch, keyed off the sample type, the
    /// starting anchor and the batch's boundary UUIDs. If a background upload finishes
    /// while the app is suspended or terminated, the next sync pass derives the same token
    /// for the un-advanced anchor and recognizes the server's earlier 2xx acknowledgement.
    static func batchToken(
        type: String,
        anchorData: Data?,
        firstUUID: String?,
        lastUUID: String?,
        deletedCount: Int
    ) -> String {
        let anchorPart = anchorData?.base64EncodedString() ?? "initial"
        let raw = "\(type)|\(anchorPart)|\(firstUUID ?? "")|\(lastUUID ?? "")|\(deletedCount)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic upload token for a combined multi-type batch.
    static func combinedBatchToken(parts: [String]) -> String {
        let raw = parts.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Uploads a payload and waits for the server to acknowledge it.
    ///
    /// Returns normally only when the server has stored the batch — either because it
    /// responded 2xx on this attempt, or (for `.background` transport) because it
    /// acknowledged an earlier attempt of the same upload while the app was suspended or
    /// killed. The caller may then safely advance its anchor(s); anything else throws.
    func sync(payload: Data, serverURL: URL, apiKey: String,
              token: String? = nil,
              transport: Transport = .background,
              timeout: TimeInterval = 300) async throws {
        let uploadToken = token ?? UUID().uuidString

        if transport == .immediate {
            try await uploadImmediate(
                payload: payload,
                serverURL: serverURL,
                apiKey: apiKey,
                token: uploadToken,
                timeout: timeout
            )
            return
        }

        // If an earlier background upload of this exact batch completed while the app was
        // suspended or terminated, consume that 2xx acknowledgement and skip re-uploading.
        if orphanStore.consumeAcknowledgement(token: uploadToken) {
            DataDonorLogger.shared.log(
                "Upload \(uploadToken.prefix(12))… was already acknowledged by the server while detached; " +
                "advancing anchor without resending.", level: .info)
            return
        }

        do {
            try await upload(payload: payload, serverURL: serverURL, apiKey: apiKey,
                             token: uploadToken, timeout: timeout)
            orphanStore.forget(token: uploadToken)
        } catch {
            // A background session keeps uploading across app death, so the server may have
            // stored this batch while we were waiting. Only a recorded 2xx counts — never
            // a merely started upload, which may never have arrived. If the task is still in
            // flight after a CancellationError, leave the token untouched so its eventual
            // 2xx completion can be recorded for the next sync run.
            guard orphanStore.consumeAcknowledgement(token: uploadToken) else { throw error }
            DataDonorLogger.shared.log(
                "Upload \(uploadToken.prefix(12))… was acknowledged by the server while detached; " +
                "treating as delivered instead of resending.", level: .info)
        }
    }

    /// Performs an immediate in-process upload via `ephemeralSession`. Bypasses `nsurlsessiond`
    /// discretionary deferral so short background windows (`HKObserverQuery`, `BGAppRefreshTask`)
    /// complete in milliseconds instead of timing out.
    private func uploadImmediate(
        payload: Data,
        serverURL: URL,
        apiKey: String,
        token uploadToken: String,
        timeout: TimeInterval
    ) async throws {
        try Task.checkCancellation()

        let (bodyData, isCompressed) = await Task.detached(priority: .utility) { () -> (Data, Bool) in
            if let compressed = Self.gzip(payload) {
                return (compressed, true)
            }
            DataDonorLogger.shared.log(
                "Compression failed for a \(payload.count)-byte payload; uploading uncompressed.",
                level: .warn)
            return (payload, false)
        }.value

        try Task.checkCancellation()

        var request = makeRequest(
            url: serverURL.appendingPathComponent("/api/v1/health-sync/post"),
            method: "POST",
            apiKey: apiKey,
            cachePolicy: .useProtocolCachePolicy
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if isCompressed {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        request.timeoutInterval = timeout

        DataDonorLogger.shared.log(
            "Immediate upload \(uploadToken.prefix(12))… (\(payload.count)B raw, \(bodyData.count)B wire)",
            level: .debug)

        let (responseData, response) = try await ephemeralSession.upload(for: request, from: bodyData)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError(message: "Upload finished with no HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(data: responseData, encoding: .utf8) ?? ""
            throw SyncError(message: "Server returned status \(httpResponse.statusCode). \(detail)")
        }

        DataDonorLogger.shared.log(
            "SyncEngine: Immediate upload \(uploadToken.prefix(12))… completed (Status: \(httpResponse.statusCode))",
            level: .info)
    }

    /// Performs one upload attempt. Background uploads must be file-backed, so the payload
    /// is compressed and staged in a temp file off the main thread, then removed once the
    /// background URLSession task completes.
    private func upload(payload: Data, serverURL: URL, apiKey: String, token uploadToken: String,
                        timeout: TimeInterval) async throws {
        // Compress and write the staging file on a background thread so multi-MB batches
        // never block the main actor.
        let (fileURL, isCompressed) = try await Task.detached(priority: .utility) { () -> (URL, Bool) in
            let tempDir = FileManager.default.temporaryDirectory
            let compressed = Self.gzip(payload)
            if compressed == nil {
                DataDonorLogger.shared.log(
                    "Compression failed for a \(payload.count)-byte payload; uploading uncompressed.",
                    level: .warn)
            }
            let bodyData = compressed ?? payload
            // Include a unique suffix per attempt so a retry doesn't overwrite a file that
            // an earlier background task is still reading.
            let fileName = "\(uploadToken)-\(UUID().uuidString)\(compressed == nil ? ".json" : ".json.gz")"
            let url = tempDir.appendingPathComponent(fileName)
            try bodyData.write(to: url, options: .atomic)
            return (url, compressed != nil)
        }.value

        // A POST is not cached, so the shared builder's no-cache default would only block
        // a revalidation the request never needed.
        var request = makeRequest(
            url: serverURL.appendingPathComponent("/api/v1/health-sync/post"),
            method: "POST",
            apiKey: apiKey,
            cachePolicy: .useProtocolCachePolicy
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if isCompressed {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        // Bound the request itself as well as the await below, so a stalled connection
        // surfaces as an error rather than pinning a background-task budget.
        request.timeoutInterval = timeout

        let identity = UploadTaskIdentity(batchToken: uploadToken)
        defer {
            withState { _ = cancelledAttempts.remove(identity.attemptId) }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let task = session.uploadTask(with: request, fromFile: fileURL)
                    task.taskDescription = identity.taskDescription

                    let registered = registerUploadAttempt(
                        identity: identity,
                        fileURL: fileURL,
                        continuation: continuation,
                        isTaskCancelled: Task.isCancelled
                    )
                    guard registered else {
                        task.cancel()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    DataDonorLogger.shared.log(
                        "Started upload \(uploadToken.prefix(12))… [\(identity.attemptId.prefix(8))] for payload size: \(payload.count) bytes",
                        level: .info)
                    task.resume()
                }
            } onCancel: {
                // Cancellation from BackgroundSyncManager's expiration handler or user stop.
                // Resume the waiter so `sync()` doesn't hang. If the task was already started,
                // it remains running out-of-process under its own `attemptId` and its staging
                // file stays intact until that specific attempt's `didCompleteWithError` fires.
                cancelUploadAttempt(attemptId: identity.attemptId)
            }
        } catch {
            // Only remove `fileURL` here if the URLSessionUploadTask was never registered
            // under `payloadFiles[identity.attemptId]`. Once started, `handleUploadCompletion`
            // owns deleting this attempt's file.
            let wasHandedToSession = withState { () -> Bool in
                pendingUploads.removeValue(forKey: identity.attemptId)
                return payloadFiles[identity.attemptId] == fileURL
            }
            if !wasHandedToSession {
                try? FileManager.default.removeItem(at: fileURL)
            }
            throw error
        }
    }

    func fetchStats(
        serverURL: URL,
        apiKey: String,
        timeScale: String,
        deviceId: String,
        scope: String = "all"
    ) async throws -> Data {
        guard var components = URLComponents(url: serverURL.appendingPathComponent("/api/v1/health-sync/stats"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "timeScale", value: timeScale),
            URLQueryItem(name: "scope", value: scope)
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        let request = makeRequest(url: url, method: "GET", apiKey: apiKey, deviceId: deviceId)

        let (data, response) = try await ephemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
