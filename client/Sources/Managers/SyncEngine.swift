import Foundation

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

    /// Continuations for in-flight uploads, keyed by task identifier. Guarded by `stateLock`
    /// because URLSession delegate callbacks arrive on its own operation queue.
    private var pendingUploads: [Int: CheckedContinuation<Void, Error>] = [:]
    /// Response bodies accumulated per task, so we can report server-side errors.
    private var responseBodies: [Int: Data] = [:]
    /// Temp payload files to clean up once their task finishes.
    private var payloadFiles: [Int: URL] = [:]
    private let stateLock = NSLock()

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
        stateLock.lock()
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
        stateLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier

        stateLock.lock()
        let continuation = pendingUploads.removeValue(forKey: identifier)
        let body = responseBodies.removeValue(forKey: identifier)
        let payloadFile = payloadFiles.removeValue(forKey: identifier)
        stateLock.unlock()

        if let payloadFile = payloadFile {
            try? FileManager.default.removeItem(at: payloadFile)
        }

        if let error = error {
            DataDonorLogger.shared.log(
                "SyncEngine: Task \(identifier) failed with error: \(error.localizedDescription)", level: .error)
            continuation?.resume(throwing: error)
            return
        }

        guard let response = task.response as? HTTPURLResponse else {
            let err = SyncError(message: "Upload finished with no HTTP response")
            DataDonorLogger.shared.log("SyncEngine: Task \(identifier) \(err.message)", level: .error)
            continuation?.resume(throwing: err)
            return
        }

        if (200...299).contains(response.statusCode) {
            DataDonorLogger.shared.log(
                "SyncEngine: Task \(identifier) completed successfully (Status: \(response.statusCode))", level: .info)
            continuation?.resume(returning: ())
        } else {
            let detail = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let err = SyncError(message: "Server returned status \(response.statusCode). \(detail)")
            DataDonorLogger.shared.log("SyncEngine: Task \(identifier) \(err.message)", level: .error)
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

    /// Uploads a payload and waits for the server to acknowledge it.
    ///
    /// Background uploads must be file-backed, so the payload is staged in a temp file
    /// that is removed once the task completes. This call only returns normally when the
    /// server responded 2xx — the caller may then safely advance its anchor.
    func sync(payload: Data, serverURL: URL, apiKey: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".json")
        try payload.write(to: fileURL)

        var request = URLRequest(url: serverURL.appendingPathComponent("/api/v1/health-sync/post"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.uploadTask(with: request, fromFile: fileURL)
                stateLock.lock()
                pendingUploads[task.taskIdentifier] = continuation
                payloadFiles[task.taskIdentifier] = fileURL
                stateLock.unlock()

                DataDonorLogger.shared.log(
                    "Started upload task \(task.taskIdentifier) for payload size: \(payload.count) bytes", level: .info)
                task.resume()
            }
        } catch {
            // The delegate cleans up on completion; this covers the case where the task
            // never started and no delegate callback will arrive.
            try? FileManager.default.removeItem(at: fileURL)
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
