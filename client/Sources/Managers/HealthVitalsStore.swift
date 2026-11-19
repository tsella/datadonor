import Foundation
import HealthKit
import SwiftUI
import UIKit

struct TimedQuantitySample: Equatable, Sendable {
    let date: Date
    let value: Double
}

struct HealthVitalsSnapshot: Equatable, Sendable, Codable {
    let heartRate: HeartRate24hSummary
    let sleep: Sleep24hSummary
    let readiness: ReadinessSummary

    /// Builds all three card summaries from one deduplicated set of HealthKit samples so
    /// Heart Rate, Sleep, and Readiness share identical RHR, HRV, and sleep figures without
    /// redundant HealthKit queries or MainActor work.
    static func build(
        heartRate24h: [HeartRateSamplePoint],
        rhr14d: [TimedQuantitySample],
        hrv14d: [TimedQuantitySample],
        sleep36h: [RawSleepSample],
        wristTemp14d: [TimedQuantitySample],
        windowEnd: Date
    ) -> HealthVitalsSnapshot {
        let start24h = windowEnd.addingTimeInterval(-24 * 60 * 60)
        let start48h = windowEnd.addingTimeInterval(-48 * 60 * 60)

        let rhrLatest = rhr14d.filter { $0.date >= start48h }.last?.value
        let rhrPrior = rhr14d.filter { $0.date < start24h }.map(\.value)
        let rhrBaseline = mean(rhrPrior.count >= 3 ? rhrPrior : rhr14d.map(\.value))

        let hrvRecent24 = hrv14d.filter { $0.date >= start24h }.map(\.value)
        let hrvFallback48 = hrv14d.filter { $0.date >= start48h }.last?.value
        let hrvToday: Double? = hrvRecent24.isEmpty
            ? hrvFallback48
            : (hrvRecent24.reduce(0, +) / Double(hrvRecent24.count))
        let hrvPrior = hrv14d.filter { $0.date < start24h }.map(\.value)
        let hrvBaseline = mean(hrvPrior.count >= 3 ? hrvPrior : hrv14d.map(\.value))

        let tempToday = wristTemp14d.filter { $0.date >= start48h }.last?.value
        let tempPrior = wristTemp14d.filter { $0.date < start24h }.map(\.value)
        let tempBaseline = mean(tempPrior.count >= 3 ? tempPrior : wristTemp14d.map(\.value))

        let heartRateSummary = HeartRate24hSummary.build(
            samples: heartRate24h,
            restingHeartRateBPM: rhrLatest,
            hrvSamples24h: hrvRecent24,
            fallbackHRV: hrvFallback48,
            windowEnd: windowEnd
        )

        let sleepSummary = Sleep24hSummary.build(
            samples: sleep36h,
            windowEnd: windowEnd
        )

        let sleepHours: Double? = sleepSummary.totalAsleepSeconds > 0 ? sleepSummary.totalAsleepHours : nil
        let readinessSummary = ReadinessSummary.build(
            hrvToday: hrvToday,
            hrvBaseline14d: hrvBaseline,
            rhrToday: rhrLatest,
            rhrBaseline14d: rhrBaseline,
            sleepHours24h: sleepHours,
            restorativeSleepShare: sleepSummary.restorativeShare,
            wristTempTodayC: tempToday,
            wristTempBaseline14dC: tempBaseline
        )

        return HealthVitalsSnapshot(
            heartRate: heartRateSummary,
            sleep: sleepSummary,
            readiness: readinessSummary
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// File-backed encrypted cache for computed vitals summaries (`Library/Caches/vitals_snapshot_cache.json`).
///
/// Uses `NSFileProtectionComplete` (matching HealthKit's own device-lock encryption) and
/// expires snapshots older than 48 hours so cold launches never flash stale multi-day charts.
struct VitalsSnapshotCache: Sendable {
    private struct Envelope: Codable {
        static let currentSchemaVersion = 1
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: HealthVitalsSnapshot
    }

    let fileURL: URL
    let maxAge: TimeInterval

    init(fileURL: URL? = nil, maxAge: TimeInterval = 48 * 60 * 60) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = caches.appendingPathComponent("vitals_snapshot_cache.json")
        }
        self.maxAge = maxAge
    }

    func load(now: Date = Date()) -> HealthVitalsSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == Envelope.currentSchemaVersion,
              now.timeIntervalSince(envelope.cachedAt) <= maxAge else {
            return nil
        }
        return envelope.snapshot
    }

    func save(_ snapshot: HealthVitalsSnapshot, now: Date = Date()) {
        let envelope = Envelope(
            schemaVersion: Envelope.currentSchemaVersion,
            cachedAt: now,
            snapshot: snapshot
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// Shared loader for all on-device HealthKit vitals cards (Heart Rate, Sleep, Readiness).
///
/// Seeds immediately from `VitalsSnapshotCache` so cold launches render every chart on the
/// first frame, then runs one deduplicated parallel HealthKit fetch + off-MainActor
/// aggregation and smoothly animates any refreshed values into place.
@MainActor
final class HealthVitalsStore: ObservableObject {
    @Published private(set) var heartRate: HeartRate24hSummary?
    @Published private(set) var sleep: Sleep24hSummary?
    @Published private(set) var readiness: ReadinessSummary?
    @Published private(set) var isLoading = false

    private let cache: VitalsSnapshotCache
    private var fetchTask: Task<Void, Never>?
    private var fetchGuard = FetchGenerationGuard()

    init(cache: VitalsSnapshotCache = VitalsSnapshotCache()) {
        self.cache = cache
        if let cached = cache.load() {
            self.heartRate = cached.heartRate
            self.sleep = cached.sleep
            self.readiness = cached.readiness
        }
    }

    func refresh(healthStore: HKHealthStore, isAuthorized: Bool) {
        guard isAuthorized, HKHealthStore.isHealthDataAvailable() else { return }

        fetchTask?.cancel()
        let generation = fetchGuard.beginNext()
        let hadData = (heartRate != nil || sleep != nil || readiness != nil)
        let cache = self.cache

        fetchTask = Task { @MainActor in
            if !hadData {
                isLoading = true
            }
            defer { isLoading = false }

            let snapshot = await Self.fetchAndCompute(healthStore: healthStore)
            guard !Task.isCancelled, fetchGuard.isCurrent(generation) else { return }

            Task.detached(priority: .utility) {
                cache.save(snapshot)
            }

            apply(snapshot, animated: UIApplication.shared.applicationState == .active)
        }
    }

    internal func apply(_ snapshot: HealthVitalsSnapshot, animated: Bool) {
        let heartChanged = (heartRate != snapshot.heartRate)
        let sleepChanged = (sleep != snapshot.sleep)
        let readinessChanged = (readiness != snapshot.readiness)
        guard heartChanged || sleepChanged || readinessChanged else { return }

        let updates = {
            if heartChanged { self.heartRate = snapshot.heartRate }
            if sleepChanged { self.sleep = snapshot.sleep }
            if readinessChanged { self.readiness = snapshot.readiness }
        }

        if animated {
            withAnimation(AppTheme.Animations.chartUpdate) {
                updates()
            }
        } else {
            updates()
        }
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    // MARK: - Deduplicated HealthKit Queries

    private static func fetchAndCompute(healthStore: HKHealthStore) async -> HealthVitalsSnapshot {
        let now = Date()
        let start24h = now.addingTimeInterval(-24 * 60 * 60)
        let start36h = now.addingTimeInterval(-36 * 60 * 60)
        let start14d = now.addingTimeInterval(-14 * 24 * 60 * 60)

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let msUnit = HKUnit.secondUnit(with: .milli)
        let celsiusUnit = HKUnit.degreeCelsius()

        async let hr24h = queryQuantitySamples(
            healthStore: healthStore, identifier: .heartRate,
            start: start24h, end: now, unit: bpmUnit
        )
        async let rhr14d = queryQuantitySamples(
            healthStore: healthStore, identifier: .restingHeartRate,
            start: start14d, end: now, unit: bpmUnit
        )
        async let hrv14d = queryQuantitySamples(
            healthStore: healthStore, identifier: .heartRateVariabilitySDNN,
            start: start14d, end: now, unit: msUnit
        )
        async let sleep36h = querySleepSamples(
            healthStore: healthStore, start: start36h, end: now
        )
        async let temp14d = queryWristTempSamples(
            healthStore: healthStore, start: start14d, end: now, unit: celsiusUnit
        )

        let (hr, rhr, hrv, sleep, temp) = await (hr24h, rhr14d, hrv14d, sleep36h, temp14d)

        // Run bucketing, interval union-merging, and readiness scoring off the MainActor.
        return await Task.detached(priority: .userInitiated) {
            let hrPoints = hr.map { HeartRateSamplePoint(date: $0.date, bpm: $0.value) }
            return HealthVitalsSnapshot.build(
                heartRate24h: hrPoints,
                rhr14d: rhr,
                hrv14d: hrv,
                sleep36h: sleep,
                wristTemp14d: temp,
                windowEnd: now
            )
        }.value
    }

    private static func queryWristTempSamples(
        healthStore: HKHealthStore,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async -> [TimedQuantitySample] {
        if #available(iOS 16.0, *) {
            return await queryQuantitySamples(
                healthStore: healthStore,
                identifier: .appleSleepingWristTemperature,
                start: start,
                end: end,
                unit: unit
            )
        }
        return []
    }

    private static func queryQuantitySamples(
        healthStore: HKHealthStore,
        identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async -> [TimedQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let mapped: [TimedQuantitySample] = (samples as? [HKQuantitySample] ?? []).compactMap { sample in
                    guard sample.quantity.is(compatibleWith: unit) else { return nil }
                    return TimedQuantitySample(
                        date: sample.startDate,
                        value: sample.quantity.doubleValue(for: unit)
                    )
                }
                continuation.resume(returning: mapped)
            }
            healthStore.execute(query)
        }
    }

    private static func querySleepSamples(
        healthStore: HKHealthStore,
        start: Date,
        end: Date
    ) async -> [RawSleepSample] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let mapped: [RawSleepSample] = (samples as? [HKCategorySample] ?? []).map { sample in
                    let sourceName = sample.sourceRevision.source.name
                    let product = sample.sourceRevision.productType ?? ""
                    let isWatch = product.hasPrefix("Watch") || sourceName.localizedCaseInsensitiveContains("watch")
                    return RawSleepSample(
                        startDate: sample.startDate,
                        endDate: sample.endDate,
                        categoryValue: sample.value,
                        sourceKey: sourceName,
                        isWatchSource: isWatch
                    )
                }
                continuation.resume(returning: mapped)
            }
            healthStore.execute(query)
        }
    }
}
