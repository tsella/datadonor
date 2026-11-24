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
    let energy: Energy7dSummary
    let cardioFitness: CardioFitness30dSummary
    let overnightVitals: OvernightVitals7dSummary
    let gait: GaitBiomechanics30dSummary

    /// Builds all vitals card summaries from one deduplicated set of HealthKit samples so
    /// Heart Rate, Sleep, Overnight Vitals, Readiness, Energy, Cardio Fitness, and Gait
    /// share identical figures without redundant HealthKit queries or MainActor work.
    static func build(
        heartRate24h: [HeartRateSamplePoint],
        workouts36h: [HeartRateWorkoutWindow] = [],
        rhr14d: [TimedQuantitySample],
        hrv14d: [TimedQuantitySample],
        sleep36h: [RawSleepSample],
        wristTemp14d: [TimedQuantitySample],
        respiratoryRate14d: [TimedQuantitySample] = [],
        bloodOxygen14d: [TimedQuantitySample] = [],
        breathingDisturbances14d: [TimedQuantitySample] = [],
        dailyBasal7d: [Date: Double] = [:],
        dailyActive7d: [Date: Double] = [:],
        vo2Max30d: [TimedQuantitySample] = [],
        heartRateRecovery30d: [TimedQuantitySample] = [],
        walkingHeartRate30d: [TimedQuantitySample] = [],
        walkingSpeed30d: [TimedQuantitySample] = [],
        stepLength30d: [TimedQuantitySample] = [],
        asymmetry30d: [TimedQuantitySample] = [],
        doubleSupport30d: [TimedQuantitySample] = [],
        steadiness30d: [TimedQuantitySample] = [],
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

        let sleepSummary = Sleep24hSummary.build(
            samples: sleep36h,
            windowEnd: windowEnd
        )

        let heartRateSummary = HeartRate24hSummary.build(
            samples: heartRate24h,
            workouts: workouts36h,
            sleepWindows: HeartRateSleepWindow.windows(from: sleepSummary.segments),
            restingHeartRateBPM: rhrLatest,
            hrvSamples24h: hrvRecent24,
            fallbackHRV: hrvFallback48,
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

        let energySummary = Energy7dSummary.build(
            dailyBasal: dailyBasal7d,
            dailyActive: dailyActive7d,
            now: windowEnd
        )

        let cardioFitnessSummary = CardioFitness30dSummary.build(
            vo2Max30d: vo2Max30d,
            heartRateRecovery30d: heartRateRecovery30d,
            walkingHeartRate30d: walkingHeartRate30d,
            windowEnd: windowEnd
        )

        let overnightVitalsSummary = OvernightVitals7dSummary.build(
            wristTemp14d: wristTemp14d,
            respiratoryRate14d: respiratoryRate14d,
            bloodOxygen14d: bloodOxygen14d,
            breathingDisturbances14d: breathingDisturbances14d,
            now: windowEnd
        )

        let gaitSummary = GaitBiomechanics30dSummary.build(
            walkingSpeed30d: walkingSpeed30d,
            stepLength30d: stepLength30d,
            asymmetry30d: asymmetry30d,
            doubleSupport30d: doubleSupport30d,
            steadiness30d: steadiness30d,
            windowEnd: windowEnd
        )

        return HealthVitalsSnapshot(
            heartRate: heartRateSummary,
            sleep: sleepSummary,
            readiness: readinessSummary,
            energy: energySummary,
            cardioFitness: cardioFitnessSummary,
            overnightVitals: overnightVitalsSummary,
            gait: gaitSummary
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
    private static let writeQueue = DispatchQueue(label: "la.tsel.datadonor.vitalscache", qos: .utility)

    private struct Envelope: Codable {
        static let currentSchemaVersion = 10
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
              envelope.schemaVersion == Envelope.currentSchemaVersion else {
            return nil
        }
        // Reject stale snapshots and far-future clock-skewed timestamps (allow 5m NTP drift).
        let age = now.timeIntervalSince(envelope.cachedAt)
        guard age >= -300, age <= maxAge else {
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

    /// Serializes background disk writes on one utility queue so rapid refreshes cannot
    /// overwrite a newer snapshot with an older one out of order.
    func saveAsync(_ snapshot: HealthVitalsSnapshot, now: Date = Date()) {
        Self.writeQueue.async {
            self.save(snapshot, now: now)
        }
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
    @Published private(set) var energy: Energy7dSummary?
    @Published private(set) var cardioFitness: CardioFitness30dSummary?
    @Published private(set) var overnightVitals: OvernightVitals7dSummary?
    @Published private(set) var gait: GaitBiomechanics30dSummary?
    @Published private(set) var isLoading = false

    private let cache: VitalsSnapshotCache
    private let fetcher: @Sendable (HKHealthStore) async throws -> HealthVitalsSnapshot
    private var fetchTask: Task<Void, Never>?
    private var fetchGuard = FetchGenerationGuard()

    init(
        cache: VitalsSnapshotCache = VitalsSnapshotCache(),
        fetcher: @escaping @Sendable (HKHealthStore) async throws -> HealthVitalsSnapshot = { store in
            try await HealthVitalsStore.fetchAndCompute(healthStore: store)
        }
    ) {
        self.cache = cache
        self.fetcher = fetcher
        if let cached = cache.load() {
            self.heartRate = cached.heartRate
            self.sleep = cached.sleep
            self.readiness = cached.readiness
            self.energy = cached.energy
            self.cardioFitness = cached.cardioFitness
            self.overnightVitals = cached.overnightVitals
            self.gait = cached.gait
        }
    }

    func refresh(healthStore: HKHealthStore, isAuthorized: Bool) {
        guard isAuthorized, HKHealthStore.isHealthDataAvailable() else { return }

        fetchTask?.cancel()
        let generation = fetchGuard.beginNext()
        let hadData = (heartRate != nil || sleep != nil || readiness != nil || energy != nil || cardioFitness != nil || overnightVitals != nil || gait != nil)
        let cache = self.cache
        let fetcher = self.fetcher

        fetchTask = Task { @MainActor in
            if !hadData {
                isLoading = true
            }
            defer {
                if fetchGuard.isCurrent(generation) {
                    isLoading = false
                }
            }

            do {
                let snapshot = try await fetcher(healthStore)
                guard !Task.isCancelled, fetchGuard.isCurrent(generation) else { return }

                cache.saveAsync(snapshot)
                apply(snapshot, animated: UIApplication.shared.applicationState == .active)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                // Preserve any existing cached snapshot rather than wiping the UI with empty
                // data if HealthKit is momentarily locked or returns a transient read error.
                DataDonorLogger.shared.log(
                    "Vitals refresh failed (preserving cached state): \(error.localizedDescription)",
                    level: .debug)
            }
        }
    }

    internal func apply(_ snapshot: HealthVitalsSnapshot, animated: Bool) {
        let heartChanged = (heartRate != snapshot.heartRate)
        let sleepChanged = (sleep != snapshot.sleep)
        let readinessChanged = (readiness != snapshot.readiness)
        let energyChanged = (energy != snapshot.energy)
        let cardioChanged = (cardioFitness != snapshot.cardioFitness)
        let overnightChanged = (overnightVitals != snapshot.overnightVitals)
        let gaitChanged = (gait != snapshot.gait)
        guard heartChanged || sleepChanged || readinessChanged || energyChanged || cardioChanged || overnightChanged || gaitChanged else { return }

        let updates = {
            if heartChanged { self.heartRate = snapshot.heartRate }
            if sleepChanged { self.sleep = snapshot.sleep }
            if readinessChanged { self.readiness = snapshot.readiness }
            if energyChanged { self.energy = snapshot.energy }
            if cardioChanged { self.cardioFitness = snapshot.cardioFitness }
            if overnightChanged { self.overnightVitals = snapshot.overnightVitals }
            if gaitChanged { self.gait = snapshot.gait }
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
        _ = fetchGuard.beginNext()
        fetchTask?.cancel()
        fetchTask = nil
        isLoading = false
    }

    // MARK: - Deduplicated HealthKit Queries

    private static func isDatabaseInaccessible(_ error: Error) -> Bool {
        if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == HKErrorDomain &&
            nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }

    private static func fetchAndCompute(healthStore: HKHealthStore) async throws -> HealthVitalsSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let start7d = calendar.date(byAdding: .day, value: -6, to: todayStart)
            ?? todayStart.addingTimeInterval(-6 * 86_400)
        let start24h = now.addingTimeInterval(-24 * 60 * 60)
        let start36h = now.addingTimeInterval(-36 * 60 * 60)
        let start14d = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let start30d = now.addingTimeInterval(-30 * 24 * 60 * 60)

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let msUnit = HKUnit.secondUnit(with: .milli)
        let celsiusUnit = HKUnit.degreeCelsius()
        let vo2Unit = HKUnit(from: "ml/(kg*min)")
        let percentUnit = HKUnit.percent()
        let countUnit = HKUnit.count()
        let meterUnit = HKUnit.meter()
        let speedUnit = HKUnit.meter().unitDivided(by: .second())

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
        async let workouts36h = queryWorkouts(
            healthStore: healthStore, start: start36h, end: now
        )
        async let temp14d = queryWristTempSamples(
            healthStore: healthStore, start: start14d, end: now, unit: celsiusUnit
        )
        async let resp14d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .respiratoryRate,
            start: start14d, end: now, unit: bpmUnit
        )
        async let spo2_14d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .oxygenSaturation,
            start: start14d, end: now, unit: percentUnit
        )
        async let breathing14d = queryBreathingDisturbanceSamples(
            healthStore: healthStore, start: start14d, end: now, unit: countUnit
        )
        async let basal7d = queryDailyEnergy(
            healthStore: healthStore, identifier: .basalEnergyBurned,
            start: start7d, end: now
        )
        async let active7d = queryDailyEnergy(
            healthStore: healthStore, identifier: .activeEnergyBurned,
            start: start7d, end: now
        )
        async let vo2_30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .vo2Max,
            start: start30d, end: now, unit: vo2Unit
        )
        async let hrr_30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .heartRateRecoveryOneMinute,
            start: start30d, end: now, unit: bpmUnit
        )
        async let walkHR_30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .walkingHeartRateAverage,
            start: start30d, end: now, unit: bpmUnit
        )
        async let walkSpeed30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .walkingSpeed,
            start: start30d, end: now, unit: speedUnit
        )
        async let stepLen30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .walkingStepLength,
            start: start30d, end: now, unit: meterUnit
        )
        async let asym30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .walkingAsymmetryPercentage,
            start: start30d, end: now, unit: percentUnit
        )
        async let doubleSup30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .walkingDoubleSupportPercentage,
            start: start30d, end: now, unit: percentUnit
        )
        async let steadiness30d = queryOptionalQuantitySamples(
            healthStore: healthStore, identifier: .appleWalkingSteadiness,
            start: start30d, end: now, unit: percentUnit
        )

        let (hr, rhr, hrv, sleep, workouts, temp, resp, spo2) = try await (
            hr24h, rhr14d, hrv14d, sleep36h, workouts36h, temp14d, resp14d, spo2_14d
        )
        let (breathing, basal, active, vo2, hrr, walkHR) = try await (
            breathing14d, basal7d, active7d, vo2_30d, hrr_30d, walkHR_30d
        )
        let (walkSpeed, stepLen, asym, doubleSup, steadiness) = try await (
            walkSpeed30d, stepLen30d, asym30d, doubleSup30d, steadiness30d
        )

        // Run bucketing, interval union-merging, and readiness scoring off the MainActor.
        return await Task.detached(priority: .userInitiated) {
            let hrPoints = hr.map { HeartRateSamplePoint(date: $0.date, bpm: $0.value) }
            return HealthVitalsSnapshot.build(
                heartRate24h: hrPoints,
                workouts36h: workouts,
                rhr14d: rhr,
                hrv14d: hrv,
                sleep36h: sleep,
                wristTemp14d: temp,
                respiratoryRate14d: resp,
                bloodOxygen14d: spo2,
                breathingDisturbances14d: breathing,
                dailyBasal7d: basal,
                dailyActive7d: active,
                vo2Max30d: vo2,
                heartRateRecovery30d: hrr,
                walkingHeartRate30d: walkHR,
                walkingSpeed30d: walkSpeed,
                stepLength30d: stepLen,
                asymmetry30d: asym,
                doubleSupport30d: doubleSup,
                steadiness30d: steadiness,
                windowEnd: now
            )
        }.value
    }

    private static func queryBreathingDisturbanceSamples(
        healthStore: HKHealthStore,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async throws -> [TimedQuantitySample] {
        if #available(iOS 18.0, *) {
            return try await queryOptionalQuantitySamples(
                healthStore: healthStore,
                identifier: .appleSleepingBreathingDisturbances,
                start: start,
                end: end,
                unit: unit
            )
        }
        return []
    }

    private static func queryOptionalQuantitySamples(
        healthStore: HKHealthStore,
        identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async throws -> [TimedQuantitySample] {
        do {
            return try await queryQuantitySamples(
                healthStore: healthStore,
                identifier: identifier,
                start: start,
                end: end,
                unit: unit
            )
        } catch {
            if isDatabaseInaccessible(error) { throw error }
            return []
        }
    }

    private static func queryDailyEnergy(
        healthStore: HKHealthStore,
        identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date
    ) async throws -> [Date: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }
        // Omit `.strictStartDate` so HealthKit proportionally splits basal/active samples that
        // straddle the leading midnight boundary of the 7-day window.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let interval = DateComponents(day: 1)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var daily: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    if let kcal = stats.sumQuantity()?.doubleValue(for: .kilocalorie()), kcal > 0 {
                        daily[stats.startDate] = kcal
                    }
                }
                continuation.resume(returning: daily)
            }
            healthStore.execute(query)
        }
    }

    private static func queryWorkouts(
        healthStore: HKHealthStore,
        start: Date,
        end: Date
    ) async throws -> [HeartRateWorkoutWindow] {
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let activeEnergyType = HKQuantityType(.activeEnergyBurned)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let mapped: [HeartRateWorkoutWindow] = (samples as? [HKWorkout] ?? []).compactMap { workout in
                    guard workout.endDate > workout.startDate else { return nil }
                    let descriptor = HeartRateWorkoutWindow.descriptor(for: workout.workoutActivityType)
                    let durationMinutes = max(1, Int((workout.duration / 60.0).rounded()))
                    let kcal = workout.statistics(for: activeEnergyType)?
                        .sumQuantity()?
                        .doubleValue(for: .kilocalorie())
                        .rounded()
                    return HeartRateWorkoutWindow(
                        start: workout.startDate,
                        end: workout.endDate,
                        activityName: descriptor.name,
                        symbolName: descriptor.symbol,
                        durationMinutes: durationMinutes,
                        activeKilocalories: kcal.map(Int.init)
                    )
                }
                continuation.resume(returning: mapped)
            }
            healthStore.execute(query)
        }
    }

    private static func queryWristTempSamples(
        healthStore: HKHealthStore,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async throws -> [TimedQuantitySample] {
        if #available(iOS 16.0, *) {
            do {
                return try await queryQuantitySamples(
                    healthStore: healthStore,
                    identifier: .appleSleepingWristTemperature,
                    start: start,
                    end: end,
                    unit: unit
                )
            } catch {
                // Propagate locked-database errors so we preserve the cache, but treat
                // unsupported/unavailable wrist temperature hardware as an optional empty channel.
                if isDatabaseInaccessible(error) { throw error }
                return []
            }
        }
        return []
    }

    private static func queryQuantitySamples(
        healthStore: HKHealthStore,
        identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async throws -> [TimedQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
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
    ) async throws -> [RawSleepSample] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
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
