import Foundation
// BGAppRefreshTask isn't Sendable in the SDK, but the scheduler hands it to us on a single
// queue and we only call setTaskCompleted on it.
@preconcurrency import BackgroundTasks
import HealthKit

/// Stateless coordinator, so it is safe to reach from the background task and HealthKit
/// observer callbacks alike.
final class BackgroundSyncManager: Sendable {
    static let shared = BackgroundSyncManager()

    let syncTaskIdentifier = "la.tsel.datadonor.backgroundSync"

    private init() {}

    func registerBackgroundTasks(syncEngine: SyncEngine, healthQueryManager: HealthQueryManager) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: syncTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(task: refreshTask, syncEngine: syncEngine, healthQueryManager: healthQueryManager)
        }
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: syncTaskIdentifier)
        // Schedule to run loosely every 15 minutes, iOS permitting
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            DataDonorLogger.shared.log("Scheduled next background sync.", level: .debug)
        } catch {
            // BGTaskSchedulerErrorDomain code 1 means the identifier isn't in
            // BGTaskSchedulerPermittedIdentifiers; code 3 means too many pending requests.
            DataDonorLogger.shared.log("Could not schedule app refresh: \(error.localizedDescription)", level: .warn)
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask, syncEngine: SyncEngine, healthQueryManager: HealthQueryManager) {
        // Reschedule for the next cycle
        scheduleAppRefresh()

        // Completion is routed through a sendable closure so the BGTask itself never has to
        // cross an actor boundary.
        let complete: @Sendable (Bool) -> Void = { success in
            task.setTaskCompleted(success: success)
        }

        // Runs on the main actor: healthQueryManager is main-actor isolated.
        let syncTask = Task { @MainActor in
            // Read configuration now rather than at launch: the user may have changed the
            // API key or server since the app started, and a stale key 403s every request.
            let apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
            let serverURL = ServerResolver.resolveFromDefaults()

            guard !apiKey.isEmpty else {
                DataDonorLogger.shared.log("Background sync skipped: no API key configured.", level: .warn)
                complete(false)
                return
            }
            guard let serverURL = serverURL else {
                DataDonorLogger.shared.log("Background sync skipped: no server URL available.", level: .warn)
                complete(false)
                return
            }

            await healthQueryManager.performSync(syncEngine: syncEngine, serverURL: serverURL, apiKey: apiKey)
            complete(true)
        }

        task.expirationHandler = {
            // iOS is reclaiming our runtime. Stop cleanly so the anchor logic doesn't
            // advance past a batch we can no longer confirm.
            DataDonorLogger.shared.log("Background sync expired; cancelling.", level: .warn)
            Task { @MainActor in healthQueryManager.cancelSync() }
            syncTask.cancel()
        }
    }

    /// Wakes the app when new health data lands so syncs aren't limited to the 15-minute
    /// refresh cadence. Requires the HealthKit background-delivery entitlement.
    func setupObserverQueries(healthStore: HKHealthStore) {
        let observedTypes: [HKQuantityTypeIdentifier] = [.stepCount, .heartRate, .activeEnergyBurned]

        for identifier in observedTypes {
            guard let sampleType = HKObjectType.quantityType(forIdentifier: identifier) else { continue }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                if let error = error {
                    DataDonorLogger.shared.log("Observer query error for \(identifier.rawValue): \(error.localizedDescription)", level: .warn)
                    completionHandler()
                    return
                }
                // New data arrived. Ask for a refresh window rather than syncing inline:
                // observer callbacks get very little runtime.
                DataDonorLogger.shared.log("HealthKit reported new \(identifier.rawValue) data.", level: .debug)
                self.scheduleAppRefresh()
                completionHandler()
            }

            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { success, error in
                if !success {
                    DataDonorLogger.shared.log(
                        "Failed to enable background delivery for \(identifier.rawValue): \(error?.localizedDescription ?? "unknown error")",
                        level: .warn)
                }
            }
        }
    }
}
