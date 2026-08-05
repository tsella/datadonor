import Foundation
import zlib

/// Result of a completed upload, surfaced to the caller so it can decide
/// whether advancing the HealthKit anchor is safe.
enum UploadOutcome {
    case success(recordsAccepted: Int)
    case failed(Error)
}

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

    func fetchServerCheckpoint(serverURL: URL, apiKey: String, deviceId: String) async throws -> (checkpoints: [String: String], totalRecords: Int)? {
        let url = serverURL.appendingPathComponent("/api/v1/health-sync/checkpoint")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

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
        var request = URLRequest(url: url.appendingPathComponent("/api/v1/ping"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

    /// Upload token for a batch, so the caller can check `wasAcknowledgedWhileDetached`
    /// after a relaunch.
    func makeUploadToken() -> String { UUID().uuidString }

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
              timeout: TimeInterval = 300) async throws {
        let uploadToken = UUID().uuidString
        // However this ends, the token's record ends with it — otherwise a failed upload
        // leaves an entry sitting in the store until the staleness prune.
        defer { orphanStore.forget(token: uploadToken) }

        do {
            try await upload(payload: payload, serverURL: serverURL, apiKey: apiKey,
                             token: uploadToken, timeout: timeout)
        } catch {
            // A background session keeps uploading across app death, so the server may have
            // stored this batch with nobody left waiting. Only a recorded 2xx counts — never
            // a merely started upload, which may never have arrived.
            guard orphanStore.wasAcknowledged(token: uploadToken) else { throw error }
            DataDonorLogger.shared.log(
                "Upload \(uploadToken) was acknowledged by the server while detached; " +
                "treating as delivered instead of resending.", level: .info)
        }
    }

    /// Performs one upload attempt. Background uploads must be file-backed, so the payload
    /// is staged in a temp file that is removed once the task completes.
    private func upload(payload: Data, serverURL: URL, apiKey: String, token uploadToken: String,
                        timeout: TimeInterval) async throws {
        let tempDir = FileManager.default.temporaryDirectory

        // This JSON repeats `type` and `source` verbatim on every record, so it compresses
        // heavily. Fall back to the raw body if compression fails for any reason — the
        // server accepts both, keyed off Content-Encoding. Log the fallback: degrading
        // silently would hide a build where compression is broken, which looks healthy
        // while sending ~40x more bytes than it should.
        let compressed = Self.gzip(payload)
        if compressed == nil {
            DataDonorLogger.shared.log(
                "Compression failed for a \(payload.count)-byte payload; uploading uncompressed.",
                level: .warn)
        }
        let bodyData = compressed ?? payload
        let fileURL = tempDir.appendingPathComponent(uploadToken + (compressed == nil ? ".json" : ".json.gz"))
        try bodyData.write(to: fileURL)

        var request = URLRequest(url: serverURL.appendingPathComponent("/api/v1/health-sync/post"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if compressed != nil {
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

                    withState {
                        pendingUploads[uploadToken] = continuation
                        payloadFiles[uploadToken] = fileURL
                    }

                    DataDonorLogger.shared.log(
                        "Started upload \(uploadToken) for payload size: \(payload.count) bytes", level: .info)
                    task.resume()
                }
            } onCancel: {
                // Cancellation from BackgroundSyncManager's expiration handler lands here.
                // Resume the waiter so `sync()` doesn't hang for the rest of the process
                // lifetime. The upload itself is left running: a background session is
                // allowed to finish after suspension, and if it lands a 2xx the delegate
                // records it as an acknowledged orphan.
                let continuation = withState { pendingUploads.removeValue(forKey: uploadToken) }
                continuation?.resume(throwing: CancellationError())
            }
        } catch {
            // The delegate cleans up on completion; this covers the case where the task
            // never started and no delegate callback will arrive.
            let stillPending = withState { () -> URL? in
                pendingUploads.removeValue(forKey: uploadToken)
                return payloadFiles.removeValue(forKey: uploadToken)
            }
            if stillPending != nil {
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

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        let (data, response) = try await ephemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
