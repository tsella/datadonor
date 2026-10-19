import Foundation
import CryptoKit
import zlib

struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

class SyncEngine: NSObject, URLSessionDelegate, ObservableObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private var session: URLSession!
    private var ephemeralSession: URLSession!
    var backgroundCompletionHandler: (() -> Void)?

    /// Continuations for in-flight uploads, keyed by a client-generated upload token that
    /// we stash in `URLSessionTask.taskDescription`.
    ///
    /// Deliberately *not* keyed by `taskIdentifier`: identifiers are only unique within a
    /// single session instance, and after the app is relaunched the reattached background
    /// session reissues them from a low number. A new upload could then collide with a
    /// reattached task and resume the wrong continuation — advancing an anchor past data
    /// the server never acknowledged. Guarded by `stateLock` because URLSession delegate
    /// callbacks arrive on its own operation queue.
    private var pendingUploads: [String: CheckedContinuation<Void, Error>] = [:]
    /// Response bodies accumulated per upload token, so we can report server-side errors.
    private var responseBodies: [String: Data] = [:]
    /// Temp payload files to clean up once their task finishes.
    private var payloadFiles: [String: URL] = [:]
    private let stateLock = NSLock()

    /// Uploads that were in flight when the process died. A background session keeps
    /// uploading across app termination, so on relaunch the task completes with nobody
    /// waiting on it. Recording the outcome here lets the next sync tell "the server
    /// accepted this batch" apart from "this batch never went out".
    private let orphanStore = OrphanedUploadStore()

    /// Reads the token we attached at creation time. Returns nil for the ephemeral
    /// session's tasks, which don't participate in this bookkeeping.
    private func token(for task: URLSessionTask) -> String? {
        task.taskDescription
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
    private let trustStore = ServerTrustStore.shared

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "la.tsel.datadonor.sync")
        configuration.isDiscretionary = false // Try to sync immediately when triggered
        configuration.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        let ephemeralConfig = URLSessionConfiguration.ephemeral
        self.ephemeralSession = URLSession(configuration: ephemeralConfig, delegate: self, delegateQueue: nil)

        Self.pruneStaleTempFiles()
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
        DataDonorLogger.shared.log("SyncEngine: All background events finished.", level: .info)
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let token = token(for: dataTask) else { return }
        withState { responseBodies[token, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let token = token(for: task) else { return }

        let (continuation, body, payloadFile) = withState {
            (pendingUploads.removeValue(forKey: token),
             responseBodies.removeValue(forKey: token),
             payloadFiles.removeValue(forKey: token))
        }

        if let payloadFile = payloadFile {
            try? FileManager.default.removeItem(at: payloadFile)
        }

        // No continuation means the process died while this upload was in flight and the
        // background session finished it after relaunch. Nobody is awaiting the result, so
        // record it: a 2xx here means the server holds a batch whose anchor was never
        // advanced, and the next sync would otherwise resend it blind.
        let isOrphan = continuation == nil

        if let error = error {
            DataDonorLogger.shared.log(
                "SyncEngine: Upload \(token) failed with error: \(error.localizedDescription)", level: .error)
            continuation?.resume(throwing: error)
            return
        }

        guard let response = task.response as? HTTPURLResponse else {
            let err = SyncError(message: "Upload finished with no HTTP response")
            DataDonorLogger.shared.log("SyncEngine: Upload \(token) \(err.message)", level: .error)
            continuation?.resume(throwing: err)
            return
        }

        if (200...299).contains(response.statusCode) {
            DataDonorLogger.shared.log(
                "SyncEngine: Upload \(token) completed successfully (Status: \(response.statusCode))", level: .info)
            if isOrphan {
                DataDonorLogger.shared.log(
                    "SyncEngine: Upload \(token) completed after relaunch with no waiter; " +
                    "recording server acknowledgement.", level: .warn)
                orphanStore.recordSuccess(token: token)
            }
            continuation?.resume(returning: ())
        } else {
            let detail = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let err = SyncError(message: "Server returned status \(response.statusCode). \(detail)")
            DataDonorLogger.shared.log("SyncEngine: Upload \(token) \(err.message)", level: .error)
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

    func fetchServerCheckpoint(serverURL: URL, apiKey: String, deviceId: String) async throws -> (checkpoints: [String: String], totalRecords: Int)? {
        let url = serverURL.appendingPathComponent("/api/v1/health-sync/checkpoint")
        let request = makeRequest(url: url, method: "GET", apiKey: apiKey, deviceId: deviceId)

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

    func ping(url: URL, apiKey: String) async throws -> Bool {
        let request = makeRequest(
            url: url.appendingPathComponent("/api/v1/ping"), method: "GET", apiKey: apiKey)

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

    /// Uploads a payload and waits for the server to acknowledge it.
    ///
    /// Returns normally only when the server has stored the batch — either because it
    /// responded 2xx on this attempt, or because it acknowledged an earlier attempt of the
    /// same upload while the app was suspended or killed. The caller may then safely
    /// advance its anchor; anything else throws.
    ///
    /// Orphan bookkeeping is entirely internal: callers cannot forget a step and silently
    /// re-upload a batch the server already holds.
    func sync(payload: Data, serverURL: URL, apiKey: String,
              token: String? = nil,
              timeout: TimeInterval = 300) async throws {
        let uploadToken = token ?? UUID().uuidString

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

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // Bail out before creating the task if we were already cancelled —
                    // otherwise the upload starts and immediately orphans itself.
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let task = session.uploadTask(with: request, fromFile: fileURL)
                    // The key the delegate will use. Survives relaunch with the task.
                    task.taskDescription = uploadToken

                    let previousFile = withState { () -> URL? in
                        pendingUploads[uploadToken] = continuation
                        return payloadFiles.updateValue(fileURL, forKey: uploadToken)
                    }
                    if let previousFile, previousFile != fileURL {
                        try? FileManager.default.removeItem(at: previousFile)
                    }

                    DataDonorLogger.shared.log(
                        "Started upload \(uploadToken.prefix(12))… for payload size: \(payload.count) bytes", level: .info)
                    task.resume()
                }
            } onCancel: {
                // Cancellation from BackgroundSyncManager's expiration handler lands here.
                // Resume the waiter so `sync()` doesn't hang for the rest of the process
                // lifetime. The upload itself is left running: a background session is
                // allowed to finish after suspension, and if it lands a 2xx the delegate
                // records it as an acknowledged orphan and cleans up `payloadFiles`.
                let continuation = withState { pendingUploads.removeValue(forKey: uploadToken) }
                continuation?.resume(throwing: CancellationError())
            }
        } catch {
            // Only remove `fileURL` here if the URLSessionUploadTask was never created
            // (i.e., `payloadFiles[uploadToken]` was not registered for this file). Once
            // `task.resume()` has been called, `urlSession(_:task:didCompleteWithError:)`
            // owns deleting the file when the background transfer finishes.
            let wasHandedToSession = withState { () -> Bool in
                pendingUploads.removeValue(forKey: uploadToken)
                return payloadFiles[uploadToken] == fileURL
            }
            if !wasHandedToSession {
                try? FileManager.default.removeItem(at: fileURL)
            }
            throw error
        }
    }

    func fetchStats(serverURL: URL, apiKey: String, timeScale: String, deviceId: String) async throws -> Data {
        guard var components = URLComponents(url: serverURL.appendingPathComponent("/api/v1/health-sync/stats"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "timeScale", value: timeScale)]
        guard let url = components.url else { throw URLError(.badURL) }

        let request = makeRequest(url: url, method: "GET", apiKey: apiKey, deviceId: deviceId)

        let (data, response) = try await ephemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
