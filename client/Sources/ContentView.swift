import SwiftUI

/// Verified server connection status displayed on the front page.
///
/// Never reports `.connected` solely from a cached URL in `UserDefaults`: requires a non-empty
/// API key and a live `200 OK` from `/api/v1/ping`.
enum ServerConnectionStatus: Equatable, Sendable {
    case invalidURL
    case discovering
    case missingApiKey(URL)
    case checking(URL)
    case connected(URL)
    case unauthorized(URL)
    case unreachable(URL, String)

    /// Resolves states that can be determined synchronously before making a network call.
    static func preliminary(
        overrideRaw: String,
        discovered: URL?,
        apiKey: String
    ) -> (status: ServerConnectionStatus?, urlToProbe: URL?) {
        guard let resolved = ServerResolver.resolve(override: overrideRaw, discovered: discovered) else {
            let status: ServerConnectionStatus = ServerResolver.overrideIsInvalid(overrideRaw)
                ? .invalidURL
                : .discovering
            return (status, nil)
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.missingApiKey(resolved), nil)
        }
        return (nil, resolved)
    }

    static func from(pingResult: SyncEngine.PingResult, url: URL) -> ServerConnectionStatus {
        switch pingResult {
        case .ok:
            return .connected(url)
        case .unauthorized:
            return .unauthorized(url)
        case .serverError(let code):
            return .unreachable(url, "Server returned HTTP \(code).")
        case .unreachable(let reason):
            return .unreachable(url, reason)
        }
    }

    var canInitiateSync: Bool {
        switch self {
        case .connected, .checking, .unreachable:
            return true
        case .invalidURL, .discovering, .missingApiKey, .unauthorized:
            return false
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var healthStoreManager: HealthStoreManager
    @EnvironmentObject var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject var healthQueryManager: HealthQueryManager
    @EnvironmentObject var syncEngine: SyncEngine
    @AppStorage("customServerURL") private var customServerURL = ""
    @AppStorage("cardCollapsed_server") private var isServerCardCollapsed = false

    @StateObject private var vitalsStore = HealthVitalsStore()
    @State private var showSplash = true
    @State private var connectionStatus: ServerConnectionStatus = .discovering
    @State private var connectionCheckTask: Task<Void, Never>?
    @State private var connectionCheckGuard = FetchGenerationGuard()

    var body: some View {
        ZStack {
            NavigationStack {
            ZStack {
                AppTheme.Colors.groupedBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppTheme.Layout.cardStackSpacing) {
                        serverConnectionCard
                            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)

                        DashboardView()
                            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)

                        VitalsCardsSection(
                            vitalsStore: vitalsStore,
                            isAuthorized: healthStoreManager.isAuthorized
                        )
                        .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)

                        if !healthStoreManager.isAuthorized {
                            primaryActionButton(
                                title: "Grant Health Access",
                                systemImage: "heart.fill",
                                tint: AppTheme.Colors.teal
                            ) {
                                healthStoreManager.requestAuthorization()
                            }
                            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    pinnedHeaderBar
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .task {
                vitalsStore.refresh(
                    healthStore: healthStoreManager.healthStore,
                    isAuthorized: healthStoreManager.isAuthorized
                )
            }
            .onAppear {
                serverDiscoveryManager.startDiscovery()
                refreshConnectionStatus()
            }
            .onChange(of: customServerURL) {
                refreshConnectionStatus()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    serverDiscoveryManager.startDiscovery()
                    vitalsStore.refresh(
                        healthStore: healthStoreManager.healthStore,
                        isAuthorized: healthStoreManager.isAuthorized
                    )
                    refreshConnectionStatus()
                case .background:
                    serverDiscoveryManager.stopDiscovery()
                    vitalsStore.cancel()
                    cancelConnectionCheck()
                    BackgroundSyncManager.shared.scheduleAppRefresh()
                    BackgroundSyncManager.shared.scheduleProcessing()
                default:
                    break
                }
            }
            .onChange(of: healthStoreManager.isAuthorized) { _, authorized in
                if authorized {
                    vitalsStore.refresh(
                        healthStore: healthStoreManager.healthStore,
                        isAuthorized: true
                    )
                }
            }
            .onChange(of: serverDiscoveryManager.activeServerURL) { _, newURL in
                refreshConnectionStatus(autoSyncIfConnected: newURL != nil)
            }
            .onChange(of: healthQueryManager.isSyncing) { _, isSyncing in
                if !isSyncing {
                    vitalsStore.refresh(
                        healthStore: healthStoreManager.healthStore,
                        isAuthorized: healthStoreManager.isAuthorized
                    )
                    refreshConnectionStatus()
                }
                // Defer out of SwiftUI's CoreAnimation commit handler phase so UIKit's
                // idle-timer transaction doesn't trigger CA::Transaction::add_commit_handler errors.
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled =
                        isSyncing && UIApplication.shared.applicationState == .active
                }
            }
            .alert("New Server Discovered", isPresented: Binding(
                get: { serverDiscoveryManager.pendingApprovalURL != nil },
                set: { if !$0 { serverDiscoveryManager.pendingApprovalURL = nil } }
            )) {
                Button("Approve") {
                    serverDiscoveryManager.approvePendingServer()
                }
                Button("Decline", role: .cancel) {
                    serverDiscoveryManager.pendingApprovalURL = nil
                }
            } message: {
                if let url = serverDiscoveryManager.pendingApprovalURL {
                    Text("Would you like to connect and sync with \(url.absoluteString)?")
                } else {
                    Text("Would you like to connect to this new server?")
                }
            }
            }

            if showSplash {
                SplashScreenView(isReady: !vitalsStore.isLoading) {
                    showSplash = false
                }
                .zIndex(1)
            }
        }
    }

    // MARK: - Subviews

    private var pinnedHeaderBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous))
                    .shadow(color: AppTheme.Colors.cardShadow, radius: 4, x: 0, y: 2)

                Text("DataDonor")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Spacer()

                syncCircleButton

                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.Colors.cardSurface)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(AppTheme.Colors.subtleBorder, lineWidth: 0.75)
                        )
                        .shadow(color: AppTheme.Colors.cardShadow, radius: 5, x: 0, y: 2)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)
            .padding(.vertical, 10)

            Divider()
                .opacity(0.4)
        }
        .background(.bar)
    }

    private var syncCircleButton: some View {
        let isAuthorized = healthStoreManager.isAuthorized
        let isSyncing = healthQueryManager.isSyncing
        let resolvedURL = ServerResolver.resolve(
            override: customServerURL,
            discovered: serverDiscoveryManager.activeServerURL
        )
        let isDisabled = isAuthorized && !isSyncing && (resolvedURL == nil || !connectionStatus.canInitiateSync)

        let iconName: String
        let fillColor: Color
        let label: String
        if !isAuthorized {
            iconName = "heart.fill"
            fillColor = AppTheme.Colors.teal
            label = "Grant Health Access"
        } else if isSyncing {
            iconName = "stop.fill"
            fillColor = AppTheme.Colors.destructive
            label = "Stop Sync"
        } else {
            iconName = "arrow.triangle.2.circlepath"
            fillColor = AppTheme.Colors.teal
            switch connectionStatus {
            case .missingApiKey:
                label = "Sync unavailable (API key required)"
            case .unauthorized:
                label = "Sync unavailable (invalid API key)"
            default:
                label = isDisabled ? "Sync unavailable (no server connected)" : "Sync Now"
            }
        }

        return Button {
            if !isAuthorized {
                healthStoreManager.requestAuthorization()
            } else if isSyncing {
                healthQueryManager.cancelSync()
            } else if let serverURL = resolvedURL {
                let currentKey = ServerResolver.loadApiKey()
                guard !currentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    refreshConnectionStatus()
                    return
                }
                Task {
                    await healthQueryManager.performSync(
                        syncEngine: syncEngine,
                        serverURL: serverURL,
                        apiKey: currentKey
                    )
                }
            }
        } label: {
            Image(systemName: iconName)
                .font(.system(size: isSyncing ? 15 : 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(fillColor)
                .clipShape(Circle())
                .shadow(color: fillColor.opacity(isDisabled ? 0.12 : 0.32), radius: 6, x: 0, y: 3)
                .opacity(isDisabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(AppTheme.Animations.readoutUpdate, value: isSyncing)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var serverConnectionCard: some View {
        CollapsibleCard(
            isCollapsed: $isServerCardCollapsed,
            accessibilityTitle: "Server Connection",
            contentSpacing: 10
        ) {
            switch connectionStatus {
            case .connected:
                Text("Connected to Server")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.secondary)
                    Text("Connecting to Server...")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.secondary)
                }
            case .missingApiKey:
                Text("API Key Required")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
            case .unauthorized:
                Text("Authentication Failed")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
            case .unreachable:
                Text("Server Unreachable")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
            case .invalidURL:
                Text("Invalid Server URL")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
            case .discovering:
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.secondary)
                    Text("Discovering Server...")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        } headerTrailing: {
            switch connectionStatus {
            case .connected:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(AppTheme.Colors.teal)
                    .padding(.top, 2)
            case .missingApiKey:
                Image(systemName: "key.fill")
                    .font(.title3)
                    .foregroundColor(AppTheme.Colors.warning)
                    .padding(.top, 2)
            case .unauthorized:
                Image(systemName: "xmark.octagon.fill")
                    .font(.title3)
                    .foregroundColor(AppTheme.Colors.destructive)
                    .padding(.top, 2)
            case .unreachable:
                Image(systemName: "wifi.exclamationmark")
                    .font(.title3)
                    .foregroundColor(AppTheme.Colors.warning)
                    .padding(.top, 2)
            case .invalidURL:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundColor(AppTheme.Colors.warning)
                    .padding(.top, 2)
            case .checking, .discovering:
                EmptyView()
            }
        } content: {
            switch connectionStatus {
            case .connected(let url), .checking(let url):
                Text(Self.formatServerAddress(url))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            case .missingApiKey(let url):
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Self.formatServerAddress(url)) · Set or scan your API key in Settings to connect and sync.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    serverCardSettingsLink
                }
            case .unauthorized(let url):
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Self.formatServerAddress(url)) · Server rejected the API key. Update it in Settings.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        serverCardSettingsLink
                        serverCardRetryButton
                    }
                }
            case .unreachable(let url, let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Self.formatServerAddress(url)) · \(reason)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                    serverCardRetryButton
                }
            case .invalidURL:
                Text("Include a scheme, e.g. https://192.168.1.5:8443")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            case .discovering:
                Text("Searching local network for _datadonor._tcp")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var serverCardSettingsLink: some View {
        NavigationLink(destination: SettingsView()) {
            Label("Open Settings", systemImage: "gearshape.fill")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.Colors.teal)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.teal.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    private var serverCardRetryButton: some View {
        Button {
            refreshConnectionStatus()
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.insetSurface)
                )
        }
        .buttonStyle(.plain)
    }

    private static func formatServerAddress(_ url: URL) -> String {
        if let host = url.host, let port = url.port {
            return "\(host):\(String(port))"
        }
        return url.absoluteString
    }

    private func cancelConnectionCheck() {
        _ = connectionCheckGuard.beginNext()
        connectionCheckTask?.cancel()
        connectionCheckTask = nil
    }

    private func refreshConnectionStatus(autoSyncIfConnected: Bool = false) {
        connectionCheckTask?.cancel()
        let generation = connectionCheckGuard.beginNext()
        let apiKey = ServerResolver.loadApiKey()
        let preliminary = ServerConnectionStatus.preliminary(
            overrideRaw: customServerURL,
            discovered: serverDiscoveryManager.activeServerURL,
            apiKey: apiKey
        )

        if let immediate = preliminary.status {
            connectionStatus = immediate
            return
        }
        guard let urlToProbe = preliminary.urlToProbe else { return }

        // Keep showing `.connected` while silently re-verifying the same URL so foreground
        // returns don't flicker a spinner.
        if connectionStatus != .connected(urlToProbe) {
            connectionStatus = .checking(urlToProbe)
        }

        let engine = syncEngine
        let queryManager = healthQueryManager
        let storeManager = healthStoreManager
        connectionCheckTask = Task { @MainActor in
            let result = await engine.checkConnection(url: urlToProbe, apiKey: apiKey)
            guard !Task.isCancelled, connectionCheckGuard.isCurrent(generation) else { return }
            let nextStatus = ServerConnectionStatus.from(pingResult: result, url: urlToProbe)
            connectionStatus = nextStatus

            if autoSyncIfConnected,
               nextStatus == .connected(urlToProbe),
               !queryManager.isSyncing,
               storeManager.isAuthorized {
                await queryManager.performSync(
                    syncEngine: engine,
                    serverURL: urlToProbe,
                    apiKey: apiKey
                )
            }
        }
    }

    private func primaryActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(.system(.headline, design: .rounded))
            .foregroundColor(.white)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.buttonCornerRadius, style: .continuous))
            .shadow(color: tint.opacity(0.3), radius: 10, x: 0, y: 5)
        }
    }
}

/// Isolates vitals cards from `HealthQueryManager` observation so rapid `totalRecordsSynced`
/// updates during a sync never trigger unnecessary chart re-renders.
private struct VitalsCardsSection: View {
    @ObservedObject var vitalsStore: HealthVitalsStore
    let isAuthorized: Bool

    var body: some View {
        VStack(spacing: AppTheme.Layout.cardStackSpacing) {
            HeartRateCardView(
                summary: vitalsStore.heartRate,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )

            SleepCardView(
                summary: vitalsStore.sleep,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )

            OvernightVitalsCardView(
                summary: vitalsStore.overnightVitals,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )

            ReadinessCardView(
                summary: vitalsStore.readiness,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )

            EnergyCardView(
                summary: vitalsStore.energy,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )

            CardioFitnessCardView(
                summary: vitalsStore.cardioFitness,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )

            GaitBiomechanicsCardView(
                summary: vitalsStore.gait,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )
        }
    }
}
