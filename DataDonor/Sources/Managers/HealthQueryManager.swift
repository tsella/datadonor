import Foundation
import HealthKit

class HealthQueryManager: ObservableObject {
    let healthStore = HKHealthStore()
    
    /// Local cache of anchors. If the server checkpoint returns null for a type, we start from nil.
    private var anchors: [String: HKQueryAnchor] = [:]
    
    /// Converts a generic HKSample into our strict JSON specification model
    private func mapSample(_ sample: HKSample) -> HealthDataPoint? {
        let formatter = ISO8601DateFormatter()
        
        if let quantitySample = sample as? HKQuantitySample {
            // In a complete implementation, the unit would dynamically match the quantityType.
            // Using a default generic unit conversion for the scaffold.
            let fallbackUnit = HKUnit.count() 
            let value = quantitySample.quantity.is(compatibleWith: fallbackUnit) ? quantitySample.quantity.doubleValue(for: fallbackUnit) : 0.0
            
            return HealthDataPoint(
                type: sample.sampleType.identifier,
                value: .double(value),
                unit: "generic",
                startDate: formatter.string(from: sample.startDate),
                endDate: formatter.string(from: sample.endDate),
                source: sample.sourceRevision.source.name
            )
        } else if let categorySample = sample as? HKCategorySample {
            return HealthDataPoint(
                type: sample.sampleType.identifier,
                value: .string("\(categorySample.value)"),
                unit: nil,
                startDate: formatter.string(from: sample.startDate),
                endDate: formatter.string(from: sample.endDate),
                source: sample.sourceRevision.source.name
            )
        }
        return nil
    }
    
    /// Executes the full sync pipeline: Checkpoint -> Query -> Post
    func performSync(syncEngine: SyncEngine, networkMonitor: NetworkMonitor, apiKey: String) async {
        guard networkMonitor.isConnectedToTargetSSID else {
            print("Skipping sync: Not connected to target Wi-Fi SSID.")
            return
        }
        
        // 1. Inquire server checkpoints (Placeholder for the GET /api/v1/health-sync/checkpoint logic)
        // let serverCheckpoints = try await syncEngine.fetchCheckpoints(...)
        
        let sampleType = HKObjectType.quantityType(forIdentifier: .stepCount)!
        let anchor = anchors[sampleType.identifier]
        
        // 2. Execute Anchored Object Query to get incremental historical data
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let query = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) { [weak self] (query, samples, deletedObjects, newAnchor, error) in
                guard let self = self, let samples = samples, !samples.isEmpty else {
                    continuation.resume()
                    return
                }
                
                let dataPoints = samples.compactMap { self.mapSample($0) }
                let payload = HealthDataPayload(
                    deviceId: "D9B91278-BA82-4FE8-9E11-23F1A7A78C90",
                    syncTimestamp: ISO8601DateFormatter().string(from: Date()),
                    data: dataPoints
                )
                
                // 3. Transmit to server
                Task {
                    do {
                        let data = try JSONEncoder().encode(payload)
                        try await syncEngine.sync(payload: data)
                        // 4. Update anchor locally upon 200 OK success
                        self.anchors[sampleType.identifier] = newAnchor
                    } catch {
                        NotificationManager.shared.sendSyncErrorNotification(message: "Failed to upload health data.")
                    }
                }
                continuation.resume()
            }
            self.healthStore.execute(query)
        }
    }
}
