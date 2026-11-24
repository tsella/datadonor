import SwiftUI

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: String
    let level: LogLevel
    let message: String
    let raw: String
}

struct LogViewer: View {
    @State private var entries: [LogEntry] = []
    @State private var filteredEntries: [LogEntry] = []
    @State private var searchText = ""
    
    @State private var showDebug = true
    @State private var showInfo = true
    @State private var showWarn = true
    @State private var showError = true
    
    var body: some View {
        return VStack(spacing: 0) {
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
                Toggle("ERROR", isOn: $showError)
                    .toggleStyle(.button)
                    .tint(.red)
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
        .task {
            await loadLogs()
        }
        .task(id: searchText) {
            if !searchText.isEmpty {
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            applyFilter()
        }
        .onChange(of: showDebug) { applyFilter() }
        .onChange(of: showInfo) { applyFilter() }
        .onChange(of: showWarn) { applyFilter() }
        .onChange(of: showError) { applyFilter() }
        .refreshable {
            await loadLogs()
        }
    }

    @MainActor
    private func applyFilter() {
        filteredEntries = Self.filterEntries(
            entries,
            searchText: searchText,
            showDebug: showDebug,
            showInfo: showInfo,
            showWarn: showWarn,
            showError: showError
        )
    }

    nonisolated internal static func filterEntries(
        _ entries: [LogEntry],
        searchText: String,
        showDebug: Bool,
        showInfo: Bool,
        showWarn: Bool,
        showError: Bool
    ) -> [LogEntry] {
        entries.filter { entry in
            let matchesLevel: Bool
            switch entry.level {
            case .debug: matchesLevel = showDebug
            case .info: matchesLevel = showInfo
            case .warn: matchesLevel = showWarn
            case .error: matchesLevel = showError
            }
            guard matchesLevel else { return false }
            return searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    @MainActor
    private func loadLogs() async {
        guard !Task.isCancelled else { return }
        let lines = await DataDonorLogger.shared.readAllLogs()
        guard !Task.isCancelled else { return }

        let parseTask = Task.detached(priority: .userInitiated) {
            Self.parseLines(lines)
        }
        let parsed = await withTaskCancellationHandler {
            await parseTask.value
        } onCancel: {
            parseTask.cancel()
        }
        guard !Task.isCancelled else { return }
        self.entries = parsed
        applyFilter()
    }

    nonisolated internal static func parseLines(_ lines: [String]) -> [LogEntry] {
        var parsed: [LogEntry] = []
        parsed.reserveCapacity(lines.count)
        let brackets = CharacterSet(charactersIn: " [")

        for (index, line) in lines.enumerated() {
            if index & 0xFF == 0, Task.isCancelled {
                return []
            }
            if line.hasPrefix("[") {
                let parts = line.split(separator: "]", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count >= 3 {
                    // Lines look like "[LEVEL] [TIMESTAMP] message". Trim both the space and
                    // the bracket — trimming whitespace alone left a stray "[" on timestamps.
                    let levelStr = parts[0].trimmingCharacters(in: brackets)
                    let timeStr = parts[1].trimmingCharacters(in: brackets)
                    let msgStr = parts[2].trimmingCharacters(in: .whitespaces)

                    let level = LogLevel(rawValue: levelStr) ?? .info
                    parsed.append(LogEntry(timestamp: timeStr, level: level, message: msgStr, raw: line))
                }
            }
        }

        // Reverse to show newest logs at the top
        return parsed.reversed()
    }
    
    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}
