import Foundation

class SyncEngine: NSObject, URLSessionDelegate, ObservableObject, URLSessionTaskDelegate {
    private var session: URLSession!
    var backgroundCompletionHandler: (() -> Void)?
    
    // A mapping of task identifiers to their completion handlers if needed
    
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "la.tsel.datadonor.sync")
        configuration.isDiscretionary = false // Try to sync immediately when triggered
        configuration.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
    
    // MARK: - Async Stubs & Sync
    
    func ping(url: URL, apiKey: String) async throws -> Bool {
        var request = URLRequest(url: url.appendingPathComponent("/api/v1/ping"))
        request.httpMethod = "GET"
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
}
