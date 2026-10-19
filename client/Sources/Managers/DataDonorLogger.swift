import Foundation

enum LogLevel: String, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel: Int] = [.debug: 0, .info: 1, .warn: 2, .error: 3]
        return order[lhs]! < order[rhs]!
    }
}

final class DataDonorLogger: @unchecked Sendable {
    static let shared = DataDonorLogger()
    
    private let logQueue = DispatchQueue(label: "la.tsel.datadonor.logger")
    private let maxDaysToKeep = 7
    
    private var currentLogDateString: String?
    private var currentFileHandle: FileHandle?
    
    private var logsDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let docsDirectory = paths[0]
        let logsDir = docsDirectory.appendingPathComponent("Logs", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: logsDir.path) {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir
    }
    
    // Accessed exclusively on `logQueue` (DateFormatter is not thread-safe).
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    private init() {
        cleanOldLogs()
    }
    
    private func fileHandle(for dateString: String) -> FileHandle? {
        if currentLogDateString == dateString, let handle = currentFileHandle {
            return handle
        }
        
        try? currentFileHandle?.close()
        currentFileHandle = nil
        currentLogDateString = nil
        
        let fileURL = logsDirectory.appendingPathComponent("log_\(dateString).txt")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return nil
        }
        _ = try? handle.seekToEnd()
        currentLogDateString = dateString
        currentFileHandle = handle
        return handle
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        let date = Date()
        
        logQueue.async { [self] in
            let dateString = dateFormatter.string(from: date)
            let timestamp = timestampFormatter.string(from: date)
            let logLine = "[\(level.rawValue)] [\(timestamp)] \(message)\n"
            
            #if DEBUG
            print(logLine, terminator: "")
            #endif
            
            guard let data = logLine.data(using: .utf8) else { return }
            if let handle = fileHandle(for: dateString) {
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    // Handle may have been invalidated if the file was removed; reopen once.
                    try? currentFileHandle?.close()
                    currentFileHandle = nil
                    currentLogDateString = nil
                    if let retryHandle = fileHandle(for: dateString) {
                        try? retryHandle.write(contentsOf: data)
                    }
                }
            }
        }
    }
    
    private func cleanOldLogs() {
        logQueue.async {
            let calendar = Calendar.current
            guard let cutoffDate = calendar.date(byAdding: .day, value: -self.maxDaysToKeep, to: Date()) else {
                return
            }
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: self.logsDirectory, includingPropertiesForKeys: [.creationDateKey])
                for file in files where file.pathExtension == "txt" {
                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let creationDate = attrs[.creationDate] as? Date, creationDate < cutoffDate {
                        try FileManager.default.removeItem(at: file)
                    }
                }
            } catch {
                print("Failed to clean old logs: \(error)")
            }
        }
    }
    
    func readAllLogs() async -> [String] {
        return await withCheckedContinuation { continuation in
            logQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                try? self.currentFileHandle?.synchronize()
                var allLines: [String] = []
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: self.logsDirectory, includingPropertiesForKeys: [.creationDateKey])
                    let sortedFiles = files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    
                    for file in sortedFiles {
                        if let content = try? String(contentsOf: file, encoding: .utf8) {
                            allLines.append(contentsOf: content.components(separatedBy: .newlines).filter { !$0.isEmpty })
                        }
                    }
                } catch {
                    print("Failed to read logs: \(error)")
                }
                continuation.resume(returning: allLines)
            }
        }
    }
}
