import Foundation
// BGAppRefreshTask isn't Sendable in the SDK, but the scheduler hands it to us on a single
// queue and we only call setTaskCompleted on it.
@preconcurrency import BackgroundTasks
import HealthKit
import UIKit

/// Owns every wake source the app has.
///
/// There are three, and they are deliberately different:
///
///   * HealthKit observers, wrapped in a background task, sync the type that changed
///     straight away. This is the only low-latency path, and the callback's own runtime is
///     seconds, so it has to do the work instead of asking for a later window.
///   * `BGAppRefreshTask` for the periodic delta.
///   * `BGProcessingTask` for a full sweep, when short refresh windows keep expiring
///     before the 46 sample types are done.
///
/// iOS decides when a background task runs. The `earliestBeginDate` values below are
/// floors, not a cadence, which is why the observers matter: they are the only trigger
/// that arrives while the phone is simply being used.
@MainActor
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    let syncTaskIdentifier = "la.tsel.datadonor.backgroundSync"
    let processingTaskIdentifier = "la.tsel.datadonor.fullSync"

    /// Set once at launch. Held here rather than captured in the scheduler closure so the
    /// observer path and the task path run the same code.
    private var syncEngine: SyncEngine?
    private var healthQueryManager: HealthQueryManager?

    private init() {}

    func configure(syncEngine: SyncEngine, healthQueryManager: HealthQueryManager) {
        self.syncEngine = syncEngine
        self.healthQueryManager = healthQueryManager
    }

    // MARK: - Registration

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: syncTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // The task is not Sendable; the box carries it across the actor hop.
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
        // A floor, not a promise. iOS weighs app usage, battery and network before it
        // honours this, and often runs it hours later.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            DataDonorLogger.shared.log("Scheduled next background sync.", level: .debug)
        } catch {
            // Code 1: the identifier is missing from BGTaskSchedulerPermittedIdentifiers.
            // Code 3: a request for this identifier is already pending.
            DataDonorLogger.shared.log("Could not schedule app refresh: \(error.localizedDescription)", level: .warn)
        }
    }

    /// A long window for the sweep. `processing` is already declared in UIBackgroundModes;
    /// until now nothing used it, so every sweep competed for a 30-second refresh window.
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
        // Re-arm before doing anything: if this run is killed, the next one must already
        // be queued, or the chain stops until the app is opened by hand.
        scheduleAppRefresh()
        scheduleProcessing()

        let complete = appRefreshCompleter(for: task)
        let manager = healthQueryManager
        let work = Task { @MainActor in
            let ok = await self.runSync(types: nil, reconcileAnchors: false, origin: "app refresh")
            complete(ok)
        }

        task.expirationHandler = {
            // iOS is reclaiming our runtime. Stop cleanly so the anchor logic doesn't
            // advance past a batch we can no longer confirm.
            DataDonorLogger.shared.log("Background sync expired; cancelling.", level: .warn)
            work.cancel()
            Task { @MainActor in manager?.cancelSync() }
        }
    }

    private func handleProcessing(task: BGProcessingTask) {
        scheduleProcessing()

        let complete = processingCompleter(for: task)
        let manager = healthQueryManager
        let work = Task { @MainActor in
            let ok = await self.runSync(types: nil, reconcileAnchors: true, origin: "processing sweep")
            complete(ok)
        }

        task.expirationHandler = {
            DataDonorLogger.shared.log("Processing sweep expired; cancelling.", level: .warn)
            work.cancel()
            Task { @MainActor in manager?.cancelSync() }
        }
    }

    /// One-shot completion, so an expiry that races the finish cannot call
    /// `setTaskCompleted` twice.
    private func appRefreshCompleter(for task: BGAppRefreshTask) -> @Sendable (Bool) -> Void {
        let gate = CompletionGate()
        return { success in
            gate.fire { task.setTaskCompleted(success: success) }
        }
    }

    private func processingCompleter(for task: BGProcessingTask) -> @Sendable (Bool) -> Void {
        let gate = CompletionGate()
        return { success in
            gate.fire { task.setTaskCompleted(success: success) }
        }
    }

    // MARK: - Sync paths

    /// Reads credentials at execution time: the user may have changed the key or the
    /// server while the app was suspended, and a stale key 403s every request.
    private func credentials() -> (serverURL: URL, apiKey: String)? {
        let apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
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

    @discardableResult
    private func runSync(types: [HKSampleType]?, reconcileAnchors: Bool, origin: String) async -> Bool {
        guard let syncEngine, let healthQueryManager else {
            DataDonorLogger.shared.log("Sync skipped (\(origin)): app not configured.", level: .warn)
            return false
        }
        guard let resolved = credentials() else { return false }

        DataDonorLogger.shared.log("Sync start (\(origin)).", level: .info)
        let ok = await healthQueryManager.performSync(
            syncEngine: syncEngine,
            serverURL: resolved.serverURL,
            apiKey: resolved.apiKey,
            types: types,
            reconcileAnchors: reconcileAnchors
        )
        DataDonorLogger.shared.log("Sync end (\(origin)): \(ok ? "ok" : "incomplete").", level: .info)
        return ok
    }

    // MARK: - HealthKit observers

    /// Wakes on new data and syncs it inside the callback's own runtime window.
    ///
    /// Two mistakes are avoided here. The callback used to only submit a refresh request,
    /// which put the work back into the discretionary queue it had just escaped. And only
    /// steps, heart rate and active energy were observed, so a workout, a weigh-in or a
    /// night of sleep produced no wake at all.
    ///
    /// Observers are process-bound: they die with the app (jetsam, crash, force-quit,
    /// reboot) and must be registered again on every launch.
    nonisolated func setupObserverQueries(healthStore: HKHealthStore) {
        var observedTypes: [HKSampleType] = []

        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .stepCount, .heartRate, .activeEnergyBurned, .restingHeartRate, .bodyMass,
            .heartRateVariabilitySDNN,
        ]
        for identifier in quantityIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                observedTypes.append(type)
            }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            observedTypes.append(sleep)
        }
        observedTypes.append(HKObjectType.workoutType())

        for sampleType in observedTypes {
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                if let error = error {
                    DataDonorLogger.shared.log(
                        "Observer query error for \(sampleType.identifier): \(error.localizedDescription)",
                        level: .warn)
                    completionHandler()
                    return
                }

                DataDonorLogger.shared.log(
                    "HealthKit reported new \(sampleType.identifier) data.", level: .debug)

                // The completion handler must be called exactly once, from either side of
                // the actor hop, so it travels in a box.
                let completion = SendableBox(value: completionHandler)
                Task { @MainActor in
                    self?.syncFromObserver(types: [sampleType], completion: completion)
                }
            }

            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { success, error in
                if !success {
                    DataDonorLogger.shared.log(
                        "Failed to enable background delivery for \(sampleType.identifier): \(error?.localizedDescription ?? "unknown error")",
                        level: .warn)
                }
            }
        }
    }

    /// Syncs in the observer's own window, borrowing a background task so the process is
    /// not suspended the moment the callback returns.
    private func syncFromObserver(types: [HKSampleType], completion: SendableBox<() -> Void>) {
        guard let healthQueryManager else {
            completion.value()
            return
        }
        // Do not start a second sync behind a running one: the anchors are shared state.
        guard !healthQueryManager.isSyncing else {
            DataDonorLogger.shared.log("Observer sync skipped: another sync is running.", level: .info)
            completion.value()
            return
        }

        let token = BackgroundTaskToken()
        token.begin(name: "DataDonorObserverSync")

        Task { @MainActor in
            _ = await self.runSync(types: types, reconcileAnchors: false, origin: "observer")
            completion.value()
            token.end()
        }
    }
}

// MARK: - Concurrency helpers

/// Carries a non-Sendable closure across an actor hop. The observer completion handler is
/// only ever invoked, never stored or shared, and iOS delivers the callback on one queue.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Guards `setTaskCompleted` so a race between the work finishing and the expiration
/// handler cannot complete the same task twice.
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

/// `beginBackgroundTask` returns an identifier that must be ended exactly once, and the
/// expiration handler may end it first. The identifier lives here so both sides can check.
@MainActor
private final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
