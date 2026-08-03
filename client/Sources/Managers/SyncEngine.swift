import Foundation

class SyncEngine: NSObject, URLSessionDelegate, ObservableObject, URLSessionTaskDelegate {
    private var session: URLSession!
    private var ephemeralSession: URLSession!
    var backgroundCompletionHandler: (() -> Void)?
    
    // A mapping of task identifiers to their completion handlers if needed
    
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
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            // Automatically trust the self-signed certificate (User verified in settings)
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DataDonorLogger.shared.log("SyncEngine: All background events finished.", level: .info)
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DataDonorLogger.shared.log("SyncEngine: Task \(task.taskIdentifier) failed with error: \(error.localizedDescription)", level: .error)
        } else if let response = task.response as? HTTPURLResponse {
            if response.statusCode == 200 || response.statusCode == 201 {
                DataDonorLogger.shared.log("SyncEngine: Task \(task.taskIdentifier) completed successfully (Status: \(response.statusCode))", level: .info)
            } else {
                DataDonorLogger.shared.log("SyncEngine: Task \(task.taskIdentifier) returned unexpected status code: \(response.statusCode)", level: .warn)
            }
        }
    }
    
    // MARK: - Async Stubs & Sync
    
    func fetchServerCheckpoint(serverURL: URL, apiKey: String, deviceId: String) async throws -> [String: String]? {
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
                return checkpoints
            }
        }
        return nil
    }
    
    func ping(url: URL, apiKey: String) async throws -> Bool {
        var request = URLRequest(url: url.appendingPathComponent("/api/v1/ping"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }
    
    // For background uploading, we must upload from a file, so we write the payload to a temp file first.
    func sync(payload: Data, serverURL: URL, apiKey: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".json")
        try payload.write(to: fileURL)
        
        var request = URLRequest(url: serverURL.appendingPathComponent("/api/v1/health-sync/post"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.resume()
        
        DataDonorLogger.shared.log("Started background upload task for payload size: \(payload.count) bytes", level: .info)
        // Background sessions do not support async/await for upload tasks elegantly if the app suspends. 
        // We let the session delegate handle completion or we just let it fire and forget in the background.
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
