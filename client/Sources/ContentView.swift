import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var healthStoreManager: HealthStoreManager
    @EnvironmentObject var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject var healthQueryManager: HealthQueryManager
    @EnvironmentObject var syncEngine: SyncEngine
    @AppStorage("customServerURL") private var customServerURL = ""
    @AppStorage("cardCollapsed_server") private var isServerCardCollapsed = false

    @StateObject private var vitalsStore = HealthVitalsStore()

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.groupedBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppTheme.Layout.cardStackSpacing) {
                        headerBar
                            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)
                            .padding(.top, 10)

                        serverConnectionCard
                            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)

                        DashboardView()
                            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)

                        VitalsCardsSection(
                            vitalsStore: vitalsStore,
                            isAuthorized: healthStoreManager.isAuthorized
                        )
                        .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)

                        Spacer(minLength: 16)

                        actionButton
                            .padding(.horizontal, AppTheme.Layout.screenHorizontalPadding)
                            .padding(.bottom, 20)
                    }
                    .padding(.top, 10)
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
            }
            .onDisappear {
                vitalsStore.cancel()
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    serverDiscoveryManager.startDiscovery()
                    vitalsStore.refresh(
                        healthStore: healthStoreManager.healthStore,
                        isAuthorized: healthStoreManager.isAuthorized
                    )
                case .background:
                    serverDiscoveryManager.stopDiscovery()
                    BackgroundSyncManager.shared.scheduleAppRefresh()
                    BackgroundSyncManager.shared.scheduleProcessing()
                default:
                    break
                }
            }
            .onChange(of: healthStoreManager.isAuthorized) { authorized in
                if authorized {
                    vitalsStore.refresh(
                        healthStore: healthStoreManager.healthStore,
                        isAuthorized: true
                    )
                }
            }
            .onChange(of: serverDiscoveryManager.activeServerURL) { newURL in
                let currentKey = ServerResolver.loadApiKey()
                guard newURL != nil, !healthQueryManager.isSyncing, healthStoreManager.isAuthorized,
                      !currentKey.isEmpty else { return }
                Task {
                    await healthQueryManager.performSync(
                        syncEngine: syncEngine,
                        serverURL: ServerResolver.resolve(override: customServerURL, discovered: newURL),
                        apiKey: currentKey
                    )
                }
            }
            .onChange(of: healthQueryManager.isSyncing) { isSyncing in
                if !isSyncing {
                    vitalsStore.refresh(
                        healthStore: healthStoreManager.healthStore,
                        isAuthorized: healthStoreManager.isAuthorized
                    )
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
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)

            Text("DataDonor")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Spacer()

            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .background(AppTheme.Colors.cardSurface)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            }
        }
    }

    @ViewBuilder
    private var serverConnectionCard: some View {
        let resolvedURL = ServerResolver.resolve(
            override: customServerURL,
            discovered: serverDiscoveryManager.activeServerURL
        )

        CollapsibleCard(
            isCollapsed: $isServerCardCollapsed,
            accessibilityTitle: "Server Connection",
            contentSpacing: 10
        ) {
            if resolvedURL != nil {
                Text("Connected to Server")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
            } else if ServerResolver.overrideIsInvalid(customServerURL) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(AppTheme.Colors.warning)
                    Text("Invalid Server URL")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.secondary)
                    Text("Discovering Server...")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        } headerTrailing: {
            if resolvedURL != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(AppTheme.Colors.teal)
                    .padding(.top, 2)
            }
        } content: {
            if let url = resolvedURL {
                if let host = url.host, let port = url.port {
                    Text("\(host):\(String(port))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text(url.absoluteString)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if ServerResolver.overrideIsInvalid(customServerURL) {
                Text("Include a scheme, e.g. https://192.168.1.5:8443")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Searching local network for _datadonor._tcp")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if !healthStoreManager.isAuthorized {
            primaryActionButton(
                title: "Grant Health Access",
                systemImage: "heart.fill",
                tint: AppTheme.Colors.teal
            ) {
                healthStoreManager.requestAuthorization()
            }
        } else if healthQueryManager.isSyncing {
            primaryActionButton(
                title: "Stop Sync",
                systemImage: "stop.circle.fill",
                tint: AppTheme.Colors.destructive
            ) {
                healthQueryManager.cancelSync()
            }
        } else {
            primaryActionButton(
                title: "Sync Now",
                systemImage: "arrow.triangle.2.circlepath",
                tint: AppTheme.Colors.teal
            ) {
                let currentKey = ServerResolver.loadApiKey()
                Task {
                    await healthQueryManager.performSync(
                        syncEngine: syncEngine,
                        serverURL: ServerResolver.resolve(
                            override: customServerURL,
                            discovered: serverDiscoveryManager.activeServerURL),
                        apiKey: currentKey
                    )
                }
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

            ReadinessCardView(
                summary: vitalsStore.readiness,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )
        }
    }
}
