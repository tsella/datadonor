import SwiftUI

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let level: LogLevel
    let message: String
    let raw: String
}

struct LogViewer: View {
    @State private var entries: [LogEntry] = []
    @State private var searchText = ""
    
    @State private var showDebug = true
    @State private var showInfo = true
    @State private var showWarn = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Filters
            HStack(spacing: 15) {
                Toggle("DEBUG", isOn: $showDebug)
                    .toggleStyle(.button)
                    .tint(.gray)
                Toggle("INFO", isOn: $showInfo)
                    .toggleStyle(.button)
                    .tint(.blue)
                Toggle("WARN", isOn: $showWarn)
                    .toggleStyle(.button)
                    .tint(.orange)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            
            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if filteredEntries.isEmpty {
                        Text("No logs found.")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                    
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top) {
                            Text(entry.level.rawValue)
                                .font(.system(.caption2, design: .monospaced).bold())
                                .foregroundColor(color(for: entry.level))
                                .frame(width: 45, alignment: .leading)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.timestamp)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal)
                        
                        Divider()
                    }
                }
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search logs...")
        .onAppear {
            loadLogs()
            
            // Generate dummy logs for demonstration if empty
            if entries.isEmpty {
                DataDonorLogger.shared.log("Initialized DataDonorLogger", level: .info)
                DataDonorLogger.shared.log("Checking HealthKit permissions...", level: .debug)
                DataDonorLogger.shared.log("Waiting for network connection.", level: .warn)
                
                // Allow time for async file writing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    loadLogs()
                }
            }
        }
    }
    
    private var filteredEntries: [LogEntry] {
        entries.filter { entry in
            let matchesLevel = (entry.level == .debug && showDebug) ||
                               (entry.level == .info && showInfo) ||
                               (entry.level == .warn && showWarn)
            
            let matchesSearch = searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
            
            return matchesLevel && matchesSearch
        }
    }
    
    private func loadLogs() {
        let lines = DataDonorLogger.shared.readAllLogs()
        var parsed: [LogEntry] = []
        
        for line in lines {
            if line.hasPrefix("[") {
                let parts = line.split(separator: "]", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count >= 3 {
                    let levelStr = parts[0].dropFirst().trimmingCharacters(in: .whitespaces)
                    let timeStr = parts[1].dropFirst().trimmingCharacters(in: .whitespaces)
                    let msgStr = parts[2].trimmingCharacters(in: .whitespaces)
                    
                    let level = LogLevel(rawValue: levelStr) ?? .info
                    parsed.append(LogEntry(timestamp: timeStr, level: level, message: msgStr, raw: line))
                }
            }
        }
        
        // Reverse to show newest logs at the top
        self.entries = parsed.reversed()
    }
    
    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        }
    }
}
