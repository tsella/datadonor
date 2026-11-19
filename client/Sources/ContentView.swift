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
    @State private var showSplash = true

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
                    vitalsStore.cancel()
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
        let isDisabled = isAuthorized && !isSyncing && resolvedURL == nil

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
            label = isDisabled ? "Sync unavailable (no server connected)" : "Sync Now"
        }

        return Button {
            if !isAuthorized {
                healthStoreManager.requestAuthorization()
            } else if isSyncing {
                healthQueryManager.cancelSync()
            } else if let serverURL = resolvedURL {
                let currentKey = ServerResolver.loadApiKey()
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

            EnergyCardView(
                summary: vitalsStore.energy,
                isAuthorized: isAuthorized,
                isLoading: vitalsStore.isLoading
            )
        }
    }
}
