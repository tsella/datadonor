import Foundation

enum LogLevel: String, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel: Int] = [.debug: 0, .info: 1, .warn: 2]
        return order[lhs]! < order[rhs]!
    }
}

class DataDonorLogger {
    static let shared = DataDonorLogger()
    
    private let logQueue = DispatchQueue(label: "la.tsel.datadonor.logger")
    private let maxDaysToKeep = 7
    
    private var logsDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let docsDirectory = paths[0]
        let logsDir = docsDirectory.appendingPathComponent("Logs", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: logsDir.path) {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir
    }
    
    private var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    private var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    private init() {
        cleanOldLogs()
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        let date = Date()
        let dateString = dateFormatter.string(from: date)
        let timestamp = timestampFormatter.string(from: date)
        let logLine = "[\(level.rawValue)] [\(timestamp)] \(message)\n"
        
        #if DEBUG
        print(logLine, terminator: "")
        #endif
        
        logQueue.async {
            let fileURL = self.logsDirectory.appendingPathComponent("log_\(dateString).txt")
            if let data = logLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        fileHandle.closeFile()
                    }
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }
    
    private func cleanOldLogs() {
        logQueue.async {
            let calendar = Calendar.current
            let cutoffDate = calendar.date(byAdding: .day, value: -self.maxDaysToKeep, to: Date())!
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: self.logsDirectory, includingPropertiesForKeys: [.creationDateKey])
                for file in files where file.pathExtension == "txt" {
                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let creationDate = attrs[.creationDate] as? Date {
                        if creationDate < cutoffDate {
                            try FileManager.default.removeItem(at: file)
                        }
                    }
                }
            } catch {
                print("Failed to clean old logs: \(error)")
            }
        }
    }
    
    func readAllLogs() -> [String] {
        // Run synchronously on the queue to ensure all pending writes finish
        return logQueue.sync {
            var allLines: [String] = []
            do {
                let files = try FileManager.default.contentsOfDirectory(at: self.logsDirectory, includingPropertiesForKeys: [.creationDateKey])
                // Sort files chronologically by filename (which includes the date)
                let sortedFiles = files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                
                for file in sortedFiles {
                    if let content = try? String(contentsOf: file, encoding: .utf8) {
                        allLines.append(contentsOf: content.components(separatedBy: .newlines).filter { !$0.isEmpty })
                    }
                }
            } catch {
                print("Failed to read logs: \(error)")
            }
            return allLines
        }
    }
}
