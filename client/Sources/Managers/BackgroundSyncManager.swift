import Foundation
// BGAppRefreshTask isn't Sendable in the SDK, but the scheduler hands it to us on a single
// queue and we only call setTaskCompleted on it.
@preconcurrency import BackgroundTasks
import HealthKit
import Network
import UIKit

/// Owns every background wake source the app has:
///
///   * A multi-type `HKObserverQuery` with `.immediate` background delivery. This is the
///     highest-value wake path because HealthKit delays delivery until the device is
///     unlocked (when the HealthKit database is readable). Each wake syncs the changed
///     types immediately via a non-discretionary `URLSession` and opportunistically sweeps
///     the rest of the catalog if due or previously deferred.
///   * `UIApplication.protectedDataDidBecomeAvailableNotification`, which drains any sync
///     that was deferred while the device was locked if the process is still resident on
///     unlock.
///   * `BGAppRefreshTask` (15-minute floor) for periodic delta sweeps.
///   * `BGProcessingTask` (1-hour floor) for full sweeps with server checkpoint reconciliation.
@MainActor
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    let syncTaskIdentifier = "la.tsel.datadonor.backgroundSync"
    let processingTaskIdentifier = "la.tsel.datadonor.fullSync"

    private static let pendingDeferredSyncKey = "pendingDeferredBackgroundSync"
    /// Minimum interval between opportunistic full-catalog sweeps piggybacked onto observer wakes.
    private static let opportunisticSweepInterval: TimeInterval = 30 * 60

    internal enum BackgroundRunResult: Equatable {
        /// Every targeted type synced cleanly.
        case completed
        /// Intentionally deferred (locked device, offline, or away from home LAN).
        /// Not a task failure — keeps iOS's DAS scheduling budget healthy.
        case deferred
        /// Cancelled due to background window expiry or user action.
        case cancelled
        /// Reachable server returned an error or a HealthKit read failed.
        case failed
    }

    /// Set once at launch. Held here rather than captured in the scheduler closure so the
    /// observer path and the task path run the same code.
    private let defaults: UserDefaults
    private var syncEngine: SyncEngine?
    private var healthQueryManager: HealthQueryManager?
    private var activeObserverQueries: [HKObserverQuery] = []
    private var observedSampleTypes: [HKSampleType] = []

    private var pendingObservedTypes: Set<HKSampleType> = []
    private var pendingObserverCompletions: [OneShotCompletion] = []
    private var inFlightObserverCompletions: [OneShotCompletion] = []
    internal var isDrainingObservers = false
    private var isObserverDrainExpiring = false
    private var observerDrainTask: Task<Void, Never>?
    private var unlockSyncTask: Task<Void, Never>?
    private var unlockObserver: NSObjectProtocol?

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "la.tsel.datadonor.netmonitor")
    private let latestPathBox = LockedBox<NWPath?>(nil)
    private var isMonitoringNetwork = false

    internal var hasPendingDeferredSync: Bool {
        get { defaults.bool(forKey: Self.pendingDeferredSyncKey) }
        set { defaults.set(newValue, forKey: Self.pendingDeferredSyncKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(syncEngine: SyncEngine, healthQueryManager: HealthQueryManager) {
        self.syncEngine = syncEngine
        self.healthQueryManager = healthQueryManager
        startNetworkMonitorIfNeeded()
        registerProtectedDataObserverIfNeeded()
    }

    private func startNetworkMonitorIfNeeded() {
        guard !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        let box = latestPathBox
        pathMonitor.pathUpdateHandler = { path in
            box.set(path)
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func registerProtectedDataObserverIfNeeded() {
        guard unlockObserver == nil else { return }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleProtectedDataBecameAvailable()
            }
        }
    }

    private func handleProtectedDataBecameAvailable() {
        guard let healthQueryManager, !healthQueryManager.isSyncing, !isDrainingObservers else { return }
        let isStale = Date().timeIntervalSince(healthQueryManager.lastFullSweepDate) >= Self.opportunisticSweepInterval
        guard hasPendingDeferredSync || isStale else { return }
        guard unlockSyncTask == nil else { return }

        DataDonorLogger.shared.log(
            "Device unlocked with pending/stale background sync; running catch-up sweep.",
            level: .info)

        let token = BackgroundTaskToken()
        token.begin(name: "DataDonorUnlockSync") { [weak self] in
            self?.unlockSyncTask?.cancel()
            self?.healthQueryManager?.cancelSync()
            token.end()
        }

        unlockSyncTask = Task { @MainActor in
            defer {
                self.unlockSyncTask = nil
                token.end()
            }
            let result = await self.runBackgroundSync(
                types: nil,
                reconcileAnchors: false,
                origin: "unlock catch-up"
            )
            if result == .completed {
                self.hasPendingDeferredSync = false
            }
        }
    }

    // MARK: - Registration

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: syncTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let boxed = SendableBox(value: refreshTask)
            Task { @MainActor in
                self.handleAppRefresh(task: boxed.value)
            }
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let boxed = SendableBox(value: processingTask)
            Task { @MainActor in
                self.handleProcessing(task: boxed.value)
            }
        }
    }

    // MARK: - Scheduling

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: syncTaskIdentifier)
        // 15 minutes matches iOS's documented minimum refresh interval; requesting shorter
        // floors doesn't speed up execution and can hurt DAS scheduling priority.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            DataDonorLogger.shared.log("Scheduled next background sync.", level: .debug)
        } catch {
            DataDonorLogger.shared.log("Could not schedule app refresh: \(error.localizedDescription)", level: .warn)
        }
    }

    /// A longer window for full reconciliation sweeps.
    func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            DataDonorLogger.shared.log("Scheduled next processing sweep.", level: .debug)
        } catch {
            DataDonorLogger.shared.log("Could not schedule processing sweep: \(error.localizedDescription)", level: .warn)
        }
    }

    // MARK: - Task handlers

    private func handleAppRefresh(task: BGAppRefreshTask) {
        handle(task: task, reconcileAnchors: false, origin: "app refresh") {
            self.scheduleAppRefresh()
            self.scheduleProcessing()
        }
    }

    private func handleProcessing(task: BGProcessingTask) {
        handle(task: task, reconcileAnchors: true, origin: "processing sweep") {
            self.scheduleProcessing()
        }
    }

    private func handle(
        task: BGTask,
        reconcileAnchors: Bool,
        origin: String,
        rearm: @escaping () -> Void
    ) {
        // Re-arm before doing anything: if this run is killed, the next one must already be
        // queued, or the chain stops until the app is opened by hand.
        rearm()

        let complete = completer(for: task)
        let manager = healthQueryManager
        let work = Task { @MainActor in
            let result = await self.runBackgroundSync(
                types: nil,
                reconcileAnchors: reconcileAnchors,
                origin: origin
            )
            let taskSuccess = self.applyBGTaskResult(result)
            complete(taskSuccess)
        }

        task.expirationHandler = {
            DataDonorLogger.shared.log("\(origin) expired; cancelling.", level: .warn)
            work.cancel()
            Task { @MainActor in
                self.hasPendingDeferredSync = true
                manager?.cancelSync()
            }
            // Signal completion promptly so iOS does not watchdog-kill the process.
            complete(false)
        }
    }

    /// Maps a full-sweep `BGTask` result to `setTaskCompleted(success:)` while keeping
    /// `hasPendingDeferredSync` accurate so any incomplete sweep triggers catch-up on the
    /// next unlocked wake.
    internal func applyBGTaskResult(_ result: BackgroundRunResult) -> Bool {
        switch result {
        case .completed:
            hasPendingDeferredSync = false
            return true
        case .deferred:
            // Intentionally skipped because the phone is locked, away from LAN, or busy
            // with a narrower sync. Completing cleanly keeps DAS healthy while flagging
            // a catch-up full sweep for the next unlocked wake.
            hasPendingDeferredSync = true
            return true
        case .cancelled, .failed:
            hasPendingDeferredSync = true
            return false
        }
    }

    private func completer(for task: BGTask) -> @Sendable (Bool) -> Void {
        let gate = CompletionGate()
        return { success in
            gate.fire { task.setTaskCompleted(success: success) }
        }
    }

    // MARK: - Pre-flight & sync execution

    private func credentials() -> (serverURL: URL, apiKey: String)? {
        let apiKey = ServerResolver.loadApiKey()
        guard !apiKey.isEmpty else {
            DataDonorLogger.shared.log("Background sync skipped: no API key configured.", level: .warn)
            return nil
        }
        guard let serverURL = ServerResolver.resolveFromDefaults() else {
            DataDonorLogger.shared.log("Background sync skipped: no server URL available.", level: .warn)
            return nil
        }
        return (serverURL, apiKey)
    }

    /// Fast pre-flight that avoids burning a 30s background window when the device is offline,
    /// on cellular targeting a LAN host, or away from home. Falls back to the cached server IP
    /// if background mDNS (`.local`/`.lan`) resolution stalls.
    private func resolveReachableServerURL(
        primaryURL: URL,
        apiKey: String,
        syncEngine: SyncEngine
    ) async -> URL? {
        let currentPath = latestPathBox.get()

        if let path = currentPath {
            if path.status != .satisfied {
                DataDonorLogger.shared.log("Background sync deferred: network unavailable.", level: .debug)
                return nil
            }
            if ServerResolver.isLocalOnlyHost(primaryURL) {
                let canReachLANOrTunnel =
                    path.usesInterfaceType(.wifi) ||
                    path.usesInterfaceType(.wiredEthernet) ||
                    path.usesInterfaceType(.other)
                if !canReachLANOrTunnel {
                    DataDonorLogger.shared.log(
                        "Background sync deferred: local server unreachable over cellular.",
                        level: .debug)
                    return nil
                }
            }
        }

        switch await syncEngine.checkConnection(url: primaryURL, apiKey: apiKey, timeout: 3.0) {
        case .ok:
            return primaryURL
        case .unauthorized:
            DataDonorLogger.shared.log(
                "Background sync deferred: server rejected API key.",
                level: .warn)
            return nil
        case .serverError, .unreachable:
            break
        }

        if Task.isCancelled { return nil }

        // If mDNS resolution stalled in the background, try the last resolved LAN IP directly.
        // TLS pinning still validates against the approved hostname's existing public key pin.
        if let fallbackURL = ServerResolver.cachedFallbackURL(for: primaryURL) {
            let allowDirectIP = currentPath.map {
                $0.usesInterfaceType(.wifi) || $0.usesInterfaceType(.wiredEthernet)
            } ?? true

            if allowDirectIP {
                DataDonorLogger.shared.log(
                    "Primary host \(primaryURL.host ?? "") did not answer ping; trying cached IP \(fallbackURL.host ?? "").",
                    level: .debug)
                switch await syncEngine.checkConnection(url: fallbackURL, apiKey: apiKey, timeout: 3.0) {
                case .ok:
                    return fallbackURL
                case .unauthorized:
                    DataDonorLogger.shared.log(
                        "Background sync deferred: server rejected API key over cached IP.",
                        level: .warn)
                    return nil
                case .serverError, .unreachable:
                    break
                }
            }
        }

        DataDonorLogger.shared.log("Background sync deferred: server unreachable.", level: .info)
        return nil
    }

    private func runBackgroundSync(
        types: [HKSampleType]?,
        reconcileAnchors: Bool,
        origin: String,
        sendHeartbeatWhenEmpty: Bool = true,
        precheckedServerURL: URL? = nil
    ) async -> BackgroundRunResult {
        guard let syncEngine, let healthQueryManager else {
            DataDonorLogger.shared.log("Sync skipped (\(origin)): app not configured.", level: .warn)
            return .deferred
        }

        // HealthKit encrypts its database while locked (NSFileProtectionComplete). Bail out
        // immediately before touching the network or HealthKit.
        guard UIApplication.shared.isProtectedDataAvailable else {
            hasPendingDeferredSync = true
            DataDonorLogger.shared.log(
                "Sync deferred (\(origin)): device is locked (protected data unavailable).",
                level: .debug)
            return .deferred
        }

        guard let resolved = credentials() else { return .deferred }

        let targetURL: URL
        if let precheckedServerURL {
            targetURL = precheckedServerURL
        } else {
            guard let reachable = await resolveReachableServerURL(
                primaryURL: resolved.serverURL,
                apiKey: resolved.apiKey,
                syncEngine: syncEngine
            ) else {
                hasPendingDeferredSync = true
                return .deferred
            }
            targetURL = reachable
        }

        if Task.isCancelled { return .cancelled }

        DataDonorLogger.shared.log("Sync start (\(origin)).", level: .info)
        let outcome = await healthQueryManager.performSync(
            syncEngine: syncEngine,
            serverURL: targetURL,
            apiKey: resolved.apiKey,
            types: types,
            reconcileAnchors: reconcileAnchors,
            transport: .immediate,
            sendHeartbeatWhenEmpty: sendHeartbeatWhenEmpty
        )
        DataDonorLogger.shared.log("Sync end (\(origin)): \(outcome).", level: .info)

        switch outcome {
        case .completed:
            return .completed
        case .databaseLocked:
            hasPendingDeferredSync = true
            return .deferred
        case .skipped:
            return .deferred
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }

    // MARK: - HealthKit observers

    /// Registers a multi-type `HKObserverQuery` and enables `.immediate` background delivery.
    ///
    /// MUST be called synchronously before `application(_:didFinishLaunchingWithOptions:)`
    /// returns so HealthKit cold-launch wakes deliver their updates into the active query.
    func setupObserverQueries(healthStore: HKHealthStore) {
        guard activeObserverQueries.isEmpty else { return }

        var observedTypes: [HKSampleType] = []

        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .stepCount, .heartRate, .activeEnergyBurned, .restingHeartRate,
            .bodyMass, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate,
            .dietaryEnergyConsumed, .dietaryWater, .bloodGlucose, .bloodPressureSystolic
        ]
        for identifier in quantityIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                observedTypes.append(type)
            }
        }

        let categoryIdentifiers: [HKCategoryTypeIdentifier] = [
            .sleepAnalysis, .mindfulSession, .menstrualFlow
        ]
        for identifier in categoryIdentifiers {
            if let type = HKObjectType.categoryType(forIdentifier: identifier) {
                observedTypes.append(type)
            }
        }
        observedTypes.append(HKObjectType.workoutType())

        observedSampleTypes = observedTypes
        let descriptors = observedTypes.map { HKQueryDescriptor(sampleType: $0, predicate: nil) }

        let query = HKObserverQuery(queryDescriptors: descriptors) { [weak self] _, updatedTypes, completionHandler, error in
            let oneShot = OneShotCompletion(completionHandler)

            if let error = error {
                DataDonorLogger.shared.log(
                    "Observer query error: \(error.localizedDescription)",
                    level: .warn)
                oneShot.fire()
                return
            }

            let changed = updatedTypes.map(Array.init) ?? []
            let changedNames = changed.map(\.identifier).joined(separator: ", ")
            DataDonorLogger.shared.log(
                "HealthKit observer fired for \(changed.isEmpty ? "observed types" : changedNames).",
                level: .debug)

            let typesBox = SendableBox(value: changed)
            Task { @MainActor in
                guard let self else {
                    oneShot.fire()
                    return
                }
                let typesToSync = typesBox.value.isEmpty ? self.observedSampleTypes : typesBox.value
                self.syncFromObserver(types: typesToSync, completion: oneShot)
            }
        }

        activeObserverQueries.append(query)
        healthStore.execute(query)

        for sampleType in observedTypes {
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                if !success {
                    DataDonorLogger.shared.log(
                        "Failed to enable background delivery for \(sampleType.identifier): \(error?.localizedDescription ?? "unknown error")",
                        level: .warn)
                }
            }
        }
    }

    /// Syncs changed types inside the observer's unlocked runtime window, then opportunistically
    /// runs a batched full sweep if the last full sweep is stale or a previous wake was deferred.
    private func syncFromObserver(types: [HKSampleType], completion: OneShotCompletion) {
        guard let healthQueryManager, let syncEngine else {
            completion.fire()
            return
        }

        // Fast-exit when locked so we never stall HealthKit's completion handler.
        guard UIApplication.shared.isProtectedDataAvailable else {
            hasPendingDeferredSync = true
            DataDonorLogger.shared.log("Observer wake deferred: device is locked.", level: .debug)
            completion.fire()
            return
        }

        // If the current observer drain is already expiring, don't enqueue onto a dying task
        // whose defer block is about to discard pending types — mark deferred and release
        // HealthKit's completion handler immediately.
        guard !isObserverDrainExpiring else {
            hasPendingDeferredSync = true
            DataDonorLogger.shared.log(
                "Observer wake arrived during expiration teardown; deferring for next unlocked wake.",
                level: .info)
            completion.fire()
            return
        }

        pendingObservedTypes.formUnion(types)
        pendingObserverCompletions.append(completion)

        guard !isDrainingObservers else { return }

        // If another sync is already running, it may have already moved past these types.
        // Mark `hasPendingDeferredSync` so the next unlocked wake runs a catch-up sweep,
        // and release HealthKit's completion handler promptly.
        guard !healthQueryManager.isSyncing else {
            hasPendingDeferredSync = true
            DataDonorLogger.shared.log(
                "Observer wake arrived during active sync; flagged catch-up sweep and released completion.",
                level: .info)
            flushAllObserverCompletions()
            pendingObservedTypes.removeAll()
            return
        }

        isDrainingObservers = true
        isObserverDrainExpiring = false
        let token = BackgroundTaskToken()
        token.begin(name: "DataDonorObserverSync") { [weak self] in
            self?.handleObserverExpiration(token: token)
        }

        observerDrainTask = Task { @MainActor in
            defer {
                if !self.pendingObservedTypes.isEmpty || Task.isCancelled {
                    self.hasPendingDeferredSync = true
                }
                self.isDrainingObservers = false
                self.isObserverDrainExpiring = false
                self.observerDrainTask = nil
                self.flushAllObserverCompletions()
                self.pendingObservedTypes.removeAll()
                token.end()
            }

            // Resolve reachability once for the whole observer drain + optional sweep.
            guard let resolved = self.credentials(),
                  let reachableURL = await self.resolveReachableServerURL(
                    primaryURL: resolved.serverURL,
                    apiKey: resolved.apiKey,
                    syncEngine: syncEngine
                  ) else {
                self.hasPendingDeferredSync = true
                return
            }

            var lastObservedResult: BackgroundRunResult = .completed
            while !self.pendingObservedTypes.isEmpty && !Task.isCancelled {
                let batchTypes = Array(self.pendingObservedTypes)
                self.pendingObservedTypes.removeAll()
                let batchCompletions = self.pendingObserverCompletions
                self.pendingObserverCompletions.removeAll()
                self.inFlightObserverCompletions.append(contentsOf: batchCompletions)

                lastObservedResult = await self.runBackgroundSync(
                    types: batchTypes,
                    reconcileAnchors: false,
                    origin: "observer",
                    sendHeartbeatWhenEmpty: false,
                    precheckedServerURL: reachableURL
                )

                for item in batchCompletions { item.fire() }
                self.inFlightObserverCompletions.removeAll()

                if lastObservedResult == .deferred || lastObservedResult == .cancelled {
                    break
                }
            }

            // Piggyback a full-catalog batched sweep onto this unlocked window when due or
            // when an earlier wake was deferred (e.g. overnight lock or away from LAN).
            guard !Task.isCancelled, lastObservedResult == .completed else { return }
            let sweepAge = Date().timeIntervalSince(healthQueryManager.lastFullSweepDate)
            let shouldRunOpportunisticSweep =
                self.hasPendingDeferredSync || sweepAge >= Self.opportunisticSweepInterval

            if shouldRunOpportunisticSweep {
                let sweepResult = await self.runBackgroundSync(
                    types: nil,
                    reconcileAnchors: false,
                    origin: "observer sweep",
                    sendHeartbeatWhenEmpty: true,
                    precheckedServerURL: reachableURL
                )
                if sweepResult == .completed {
                    self.hasPendingDeferredSync = false
                }
            }
        }
    }

    private func handleObserverExpiration(token: BackgroundTaskToken?) {
        DataDonorLogger.shared.log("Observer background window expiring; flushing completions.", level: .warn)
        isObserverDrainExpiring = true
        hasPendingDeferredSync = true
        observerDrainTask?.cancel()
        healthQueryManager?.cancelSync()
        flushAllObserverCompletions()
        pendingObservedTypes.removeAll()
        token?.end()
    }

    internal func triggerObserverWakeForTesting(types: [HKSampleType], completion: @escaping () -> Void) {
        syncFromObserver(types: types, completion: OneShotCompletion(completion))
    }

    internal func simulateObserverExpirationForTesting() {
        handleObserverExpiration(token: nil)
    }

    private func flushAllObserverCompletions() {
        let inFlight = inFlightObserverCompletions
        inFlightObserverCompletions.removeAll()
        for item in inFlight { item.fire() }

        let pending = pendingObserverCompletions
        pendingObserverCompletions.removeAll()
        for item in pending { item.fire() }
    }
}

// MARK: - Concurrency helpers

/// Carries a non-Sendable value across an actor hop.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Thread-safe value container for `NWPath` updates delivered on the monitor's queue.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) {
        self.value = initial
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Guards `setTaskCompleted` or an observer completion handler so races between finishing
/// and expiration cannot invoke the closure twice.
private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        lock.lock()
        let alreadyFired = fired
        fired = true
        lock.unlock()
        if !alreadyFired { body() }
    }
}

/// Guarantees an `HKObserverQueryCompletionHandler` is called at most once across
/// normal completion and background-task expiration paths.
private final class OneShotCompletion: @unchecked Sendable {
    private let gate = CompletionGate()
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func fire() {
        gate.fire(handler)
    }
}

/// `beginBackgroundTask` returns an identifier that must be ended exactly once, and the
/// expiration handler may end it first. The identifier lives here so both sides can check.
@MainActor
private final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String, onExpire: (@MainActor () -> Void)? = nil) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                if let onExpire {
                    onExpire()
                } else {
                    self?.end()
                }
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
