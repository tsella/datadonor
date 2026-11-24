import XCTest
import HealthKit
@testable import DataDonor

final class StateMachineRegressionTests: XCTestCase {

    private var suiteNamesToClean: [String] = []

    override func tearDown() {
        for name in suiteNamesToClean {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNamesToClean.removeAll()
        super.tearDown()
    }

    private func makeIsolatedDefaults(function: String = #function) -> UserDefaults {
        let suite = "la.tsel.datadonor.tests.\(UUID().uuidString)"
        suiteNamesToClean.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dd-test-\(UUID().uuidString).json.gz")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeArchivedAnchorData(value: Int = 42) throws -> Data {
        let anchor = HKQueryAnchor(fromValue: value)
        return try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    // MARK: - Issue 1 (P0): SyncEngine per-attempt isolation & cancellation race

    func testIssue1_UploadTaskIdentityParsesCurrentAndLegacyFormats() {
        let current = SyncEngine.UploadTaskIdentity(batchToken: "abc123", attemptId: "att-1")
        XCTAssertEqual(
            SyncEngine.UploadTaskIdentity(taskDescription: current.taskDescription),
            current
        )

        let legacy = SyncEngine.UploadTaskIdentity(taskDescription: "legacy-batch-token")
        XCTAssertEqual(legacy?.batchToken, "legacy-batch-token")
        XCTAssertEqual(legacy?.attemptId, "legacy-batch-token")
        XCTAssertNil(SyncEngine.UploadTaskIdentity(taskDescription: nil))
        XCTAssertNil(SyncEngine.UploadTaskIdentity(taskDescription: ""))
    }

    func testIssue1_RetryDoesNotDeleteInFlightAttemptFileOrStealContinuation() async throws {
        let defaults = makeIsolatedDefaults()
        let orphanStore = OrphanedUploadStore(defaults: defaults)
        let engine = SyncEngine(
            sessionIdentifier: "test-\(UUID().uuidString)",
            orphanStore: orphanStore,
            createBackgroundSession: false
        )

        let batchToken = "deterministic-batch-token"
        let attempt1 = SyncEngine.UploadTaskIdentity(batchToken: batchToken, attemptId: "attempt-1")
        let attempt2 = SyncEngine.UploadTaskIdentity(batchToken: batchToken, attemptId: "attempt-2")
        let file1 = try makeTempFile("payload-1")
        let file2 = try makeTempFile("payload-2")
        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        // Start attempt #1 and wait deterministically until its continuation is registered
        // before cancelling its waiter (leaving attempt #1 detached in-flight).
        let attempt1Registered = expectation(description: "attempt 1 registered")
        let task1 = Task {
            try await withCheckedThrowingContinuation { continuation in
                let registered = engine.registerUploadAttempt(
                    identity: attempt1,
                    fileURL: file1,
                    continuation: continuation,
                    isTaskCancelled: false
                )
                if !registered {
                    continuation.resume(throwing: CancellationError())
                }
                XCTAssertTrue(registered)
                attempt1Registered.fulfill()
            }
        }
        await fulfillment(of: [attempt1Registered], timeout: 2.0)
        engine.cancelUploadAttempt(attemptId: attempt1.attemptId)
        do {
            try await task1.value
            XCTFail("Expected CancellationError for cancelled attempt #1")
        } catch is CancellationError {
            // Expected
        }

        // Retry #2 starts for the exact same deterministic batchToken.
        let attempt2Registered = expectation(description: "attempt 2 registered")
        let task2 = Task {
            try await withCheckedThrowingContinuation { continuation in
                let registered = engine.registerUploadAttempt(
                    identity: attempt2,
                    fileURL: file2,
                    continuation: continuation,
                    isTaskCancelled: false
                )
                if !registered {
                    continuation.resume(throwing: CancellationError())
                }
                XCTAssertTrue(registered)
                attempt2Registered.fulfill()
            }
        }
        await fulfillment(of: [attempt2Registered], timeout: 2.0)

        // Retry #2 MUST NOT delete attempt #1's staging file while attempt #1 is still in flight.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))

        // Interleave response bodies for both attempts, then fail attempt #1.
        engine.handleUploadData(Data("attempt-1-err".utf8), for: attempt1)
        engine.handleUploadData(Data("attempt-2-ok".utf8), for: attempt2)
        engine.handleUploadCompletion(
            for: attempt1,
            httpResponse: nil,
            error: URLError(.networkConnectionLost)
        )

        // Attempt #1's file is cleaned up, but attempt #2's file AND continuation remain untouched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))

        // Now attempt #2 completes with 201 Created and succeeds cleanly.
        let okResponse = HTTPURLResponse(
            url: URL(string: "https://mac.lan:8443/api/v1/health-sync/post")!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: nil
        )
        engine.handleUploadCompletion(for: attempt2, httpResponse: okResponse, error: nil)

        try await task2.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2.path))
    }

    func testIssue1_DetachedAttempt2xxRecordedUnderBatchToken() async throws {
        let defaults = makeIsolatedDefaults()
        let orphanStore = OrphanedUploadStore(defaults: defaults)
        let engine = SyncEngine(
            sessionIdentifier: "test-\(UUID().uuidString)",
            orphanStore: orphanStore,
            createBackgroundSession: false
        )

        let batchToken = "batch-xyz"
        let attempt = SyncEngine.UploadTaskIdentity(batchToken: batchToken, attemptId: "detached-1")
        let file = try makeTempFile("payload")
        defer { try? FileManager.default.removeItem(at: file) }

        let registeredExp = expectation(description: "detached attempt registered")
        let waiter = Task {
            try await withCheckedThrowingContinuation { continuation in
                let registered = engine.registerUploadAttempt(
                    identity: attempt,
                    fileURL: file,
                    continuation: continuation,
                    isTaskCancelled: false
                )
                if !registered {
                    continuation.resume(throwing: CancellationError())
                }
                XCTAssertTrue(registered)
                registeredExp.fulfill()
            }
        }
        await fulfillment(of: [registeredExp], timeout: 2.0)
        engine.cancelUploadAttempt(attemptId: attempt.attemptId)
        _ = try? await waiter.value

        let okResponse = HTTPURLResponse(
            url: URL(string: "https://mac.lan:8443/api/v1/health-sync/post")!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: nil
        )
        engine.handleUploadCompletion(for: attempt, httpResponse: okResponse, error: nil)

        XCTAssertTrue(orphanStore.consumeAcknowledgement(token: batchToken))
        XCTAssertFalse(orphanStore.consumeAcknowledgement(token: batchToken))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testIssue1_CancelBeforeRegistrationAbortsWithoutHanging() async throws {
        let defaults = makeIsolatedDefaults()
        let engine = SyncEngine(
            sessionIdentifier: "test-\(UUID().uuidString)",
            orphanStore: OrphanedUploadStore(defaults: defaults),
            createBackgroundSession: false
        )

        let identity = SyncEngine.UploadTaskIdentity(batchToken: "batch-race", attemptId: "race-attempt")
        let file = try makeTempFile("payload")
        defer { try? FileManager.default.removeItem(at: file) }

        // Simulate onCancel firing BEFORE registerUploadAttempt acquires stateLock.
        engine.cancelUploadAttempt(attemptId: identity.attemptId)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registered = engine.registerUploadAttempt(
                    identity: identity,
                    fileURL: file,
                    continuation: continuation,
                    isTaskCancelled: false
                )
                XCTAssertFalse(registered)
                continuation.resume(throwing: CancellationError())
            }
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Aborted immediately without hanging.
        }
    }

    // MARK: - Issue 2 (P0): Reset Sync State survives reconciliation & refuses mid-sync reset

    @MainActor
    func testIssue2_ResetAllAnchorsSurvivesServerCheckpointReconciliation() throws {
        let defaults = makeIsolatedDefaults()
        let manager = HealthQueryManager(defaults: defaults)
        let stepType = HKQuantityTypeIdentifier.stepCount.rawValue
        let anchorData = try makeArchivedAnchorData(value: 99)

        manager.storeAnchorData(anchorData, for: stepType)
        XCTAssertEqual(manager.anchorKeys().count, 1)

        // User taps "Reset Sync State".
        XCTAssertTrue(manager.resetAllAnchors())
        XCTAssertTrue(manager.isPendingFullResync)
        XCTAssertTrue(manager.anchorKeys().isEmpty)
        XCTAssertEqual(manager.totalRecordsSynced, 0)

        // Next Sync Now fetches old checkpoints from server — must NOT undo the reset!
        manager.applyServerCheckpoints(
            [stepType: anchorData.base64EncodedString()],
            totalRecords: 12_345
        )

        XCTAssertTrue(manager.anchorKeys().isEmpty, "Server checkpoints must not be re-seeded while full resync is pending")
        XCTAssertEqual(manager.totalRecordsSynced, 0)
        XCTAssertTrue(manager.isPendingFullResync)
    }

    @MainActor
    func testIssue2_FreshInstallWithoutResetStillSeedsServerCheckpoints() throws {
        let defaults = makeIsolatedDefaults()
        let manager = HealthQueryManager(defaults: defaults)
        let stepType = HKQuantityTypeIdentifier.stepCount.rawValue
        let anchorData = try makeArchivedAnchorData(value: 7)

        XCTAssertFalse(manager.isPendingFullResync)
        XCTAssertTrue(manager.anchorKeys().isEmpty)

        manager.applyServerCheckpoints(
            [stepType: anchorData.base64EncodedString()],
            totalRecords: 500
        )

        XCTAssertEqual(manager.anchorKeys(), ["anchor_\(stepType)"])
        XCTAssertEqual(manager.totalRecordsSynced, 500)
    }

    @MainActor
    func testIssue2_ResetAllAnchorsRefusesToMutateWhileSyncing() throws {
        let defaults = makeIsolatedDefaults()
        let manager = HealthQueryManager(defaults: defaults)
        let stepType = HKQuantityTypeIdentifier.stepCount.rawValue
        let anchorData = try makeArchivedAnchorData(value: 15)

        manager.storeAnchorData(anchorData, for: stepType)
        manager.isSyncing = true

        XCTAssertFalse(manager.resetAllAnchors())
        XCTAssertEqual(manager.anchorKeys(), ["anchor_\(stepType)"])
        XCTAssertFalse(manager.isPendingFullResync)
    }

    // MARK: - Issue 3 (P1): Ordered persistence & backgroundCompletionHandler races

    func testIssue3_OrphanedUploadStoreConcurrentRecordAndConsumeNeverResurrectsTokens() {
        let defaults = makeIsolatedDefaults()
        let store = OrphanedUploadStore(defaults: defaults)
        let group = DispatchGroup()

        for i in 0..<40 {
            let token = "tok-\(i)"
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                store.recordSuccess(token: token)
                group.leave()
            }
        }
        group.wait()

        // Consume all even tokens from main thread while odd tokens are re-recorded from background.
        for i in 0..<40 where i % 2 == 0 {
            XCTAssertTrue(store.consumeAcknowledgement(token: "tok-\(i)"))
        }

        // Reload from UserDefaults: persisted state must match in-memory state immediately.
        let reloaded = OrphanedUploadStore(defaults: defaults)
        for i in 0..<40 {
            if i % 2 == 0 {
                XCTAssertFalse(reloaded.wasAcknowledged(token: "tok-\(i)"), "Consumed token \(i) was resurrected")
            } else {
                XCTAssertTrue(reloaded.wasAcknowledged(token: "tok-\(i)"), "Unconsumed token \(i) was lost")
            }
        }
    }

    func testIssue3_ServerTrustStoreForgetPersistsSynchronouslyWithoutAsyncClobber() {
        let defaults = makeIsolatedDefaults()
        let store = ServerTrustStore(defaults: defaults)

        let bgDone = expectation(description: "background pin store")
        DispatchQueue.global(qos: .userInitiated).async {
            store.storePinForTesting("pin-hash-abc", for: "Mac.lan")
            bgDone.fulfill()
        }
        wait(for: [bgDone], timeout: 2.0)

        // Immediately forget on main thread; no queued async snapshot may restore it.
        store.forget(host: "mac.lan")

        let reloaded = ServerTrustStore(defaults: defaults)
        XCTAssertNil(reloaded.storedPin(for: "mac.lan"))
    }

    func testIssue3_BackgroundCompletionHandlerInvokedRegardlessOfOrder() {
        let defaults = makeIsolatedDefaults()
        let engine = SyncEngine(
            sessionIdentifier: "test-\(UUID().uuidString)",
            orphanStore: OrphanedUploadStore(defaults: defaults),
            createBackgroundSession: false
        )

        // Order A: urlSessionDidFinishEvents arrives BEFORE setBackgroundCompletionHandler.
        let expA = expectation(description: "handler invoked when attached after finish")
        engine.handleBackgroundEventsFinished()
        engine.setBackgroundCompletionHandler { expA.fulfill() }
        wait(for: [expA], timeout: 2.0)

        // Order B: handler1 replaced by handler2 -> handler1 invoked immediately (no leak),
        // handler2 invoked when events finish.
        let expB1 = expectation(description: "prior handler flushed on replace")
        let expB2 = expectation(description: "active handler invoked on finish")
        engine.setBackgroundCompletionHandler { expB1.fulfill() }
        engine.setBackgroundCompletionHandler { expB2.fulfill() }
        engine.handleBackgroundEventsFinished()
        wait(for: [expB1, expB2], timeout: 2.0)
    }

    // MARK: - Issue 4 (P1): BackgroundSyncManager coalescing, expiration & BGTask tracking

    @MainActor
    func testIssue4_ObserverWakeDuringActiveSyncSetsPendingDeferredAndFiresCompletion() {
        let defaults = makeIsolatedDefaults()
        let queryManager = HealthQueryManager(defaults: defaults)
        let syncEngine = SyncEngine(
            sessionIdentifier: "test-\(UUID().uuidString)",
            orphanStore: OrphanedUploadStore(defaults: defaults),
            createBackgroundSession: false
        )
        let bg = BackgroundSyncManager(defaults: defaults)
        bg.configure(syncEngine: syncEngine, healthQueryManager: queryManager)

        queryManager.isSyncing = true
        bg.hasPendingDeferredSync = false

        var completionCount = 0
        let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
        bg.triggerObserverWakeForTesting(types: [stepType]) {
            completionCount += 1
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(bg.hasPendingDeferredSync, "Observer updates arriving mid-sync must flag a catch-up sweep")
    }

    @MainActor
    func testIssue4_ObserverWakeDuringExpirationTeardownSetsPendingDeferredAndFiresImmediately() {
        let defaults = makeIsolatedDefaults()
        let queryManager = HealthQueryManager(defaults: defaults)
        let syncEngine = SyncEngine(
            sessionIdentifier: "test-\(UUID().uuidString)",
            orphanStore: OrphanedUploadStore(defaults: defaults),
            createBackgroundSession: false
        )
        let bg = BackgroundSyncManager(defaults: defaults)
        bg.configure(syncEngine: syncEngine, healthQueryManager: queryManager)

        bg.isDrainingObservers = true
        bg.simulateObserverExpirationForTesting()
        bg.hasPendingDeferredSync = false

        var completionCount = 0
        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        bg.triggerObserverWakeForTesting(types: [hrType]) {
            completionCount += 1
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(bg.hasPendingDeferredSync)
    }

    @MainActor
    func testIssue4_BGTaskOutcomesTrackPendingDeferredSyncAndDASStatus() {
        let defaults = makeIsolatedDefaults()
        let bg = BackgroundSyncManager(defaults: defaults)

        XCTAssertTrue(bg.applyBGTaskResult(.deferred))
        XCTAssertTrue(bg.hasPendingDeferredSync)

        bg.hasPendingDeferredSync = false
        XCTAssertFalse(bg.applyBGTaskResult(.failed))
        XCTAssertTrue(bg.hasPendingDeferredSync)

        bg.hasPendingDeferredSync = false
        XCTAssertFalse(bg.applyBGTaskResult(.cancelled))
        XCTAssertTrue(bg.hasPendingDeferredSync)

        XCTAssertTrue(bg.applyBGTaskResult(.completed))
        XCTAssertFalse(bg.hasPendingDeferredSync)
    }

    // MARK: - Issue 5 (P2): ServerDiscoveryManager explicit state machine & post-stop guard

    @MainActor
    func testIssue5_StopThenStartWaitsForDidStopSearchBeforeRestarting() {
        let discovery = ServerDiscoveryManager()
        let dummyBrowser = NetServiceBrowser()

        XCTAssertEqual(discovery.state, .idle)

        discovery.startDiscovery()
        XCTAssertEqual(discovery.state, .searching)

        discovery.stopDiscovery()
        XCTAssertEqual(discovery.state, .stopping)

        // Rapid foreground return before NetServiceBrowser delivers didStopSearch.
        discovery.startDiscovery()
        XCTAssertEqual(discovery.state, .restarting)

        // When stop completes, discovery resumes cleanly into .searching (not .idle).
        discovery.netServiceBrowserDidStopSearch(dummyBrowser)
        XCTAssertEqual(discovery.state, .searching)

        // Normal stop -> idle.
        discovery.stopDiscovery()
        XCTAssertEqual(discovery.state, .stopping)
        discovery.netServiceBrowserDidStopSearch(dummyBrowser)
        XCTAssertEqual(discovery.state, .idle)
    }

    @MainActor
    func testIssue5_LateResolutionAfterStopDoesNotPublishServer() {
        let discovery = ServerDiscoveryManager()
        discovery.startDiscovery()
        discovery.stopDiscovery()
        XCTAssertEqual(discovery.state, .stopping)

        discovery.handleResolvedEndpoint(hostName: "late-host.lan.", port: 8443, resolvedIP: "192.168.1.50")

        XCTAssertNil(discovery.activeServerURL)
        XCTAssertNil(discovery.pendingApprovalURL)
    }

    // MARK: - Issue 6 (P2): Partial observer success does not reset full-sweep failure streak

    private final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ initial: Date) { self.now = initial }
    }

    @MainActor
    func testIssue6_PartialObserverSuccessDoesNotResetFullSweepFailureStreak() {
        let defaults = makeIsolatedDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let notifications = NotificationManager(defaults: defaults, now: { clock.now })
        let manager = HealthQueryManager(defaults: defaults, notificationManager: notifications)

        // Two failing full sweeps build streak to 2 (no alert yet).
        XCTAssertFalse(manager.recordCompletionOutcome(failedTypeCount: 1, isFullSweep: true))
        XCTAssertFalse(manager.recordCompletionOutcome(failedTypeCount: 1, isFullSweep: true))
        XCTAssertEqual(notifications.currentFailureStreak, 2)

        // A single-type observer wake succeeds — must NOT wipe out the full-sweep streak!
        XCTAssertFalse(manager.recordCompletionOutcome(failedTypeCount: 0, isFullSweep: false))
        XCTAssertEqual(notifications.currentFailureStreak, 2)

        // Third failing full sweep triggers the alert.
        XCTAssertTrue(manager.recordCompletionOutcome(failedTypeCount: 1, isFullSweep: true))
        XCTAssertEqual(notifications.currentFailureStreak, 3)

        // Fourth failing full sweep within 1 hour is throttled.
        clock.now = clock.now.addingTimeInterval(600)
        XCTAssertFalse(manager.recordCompletionOutcome(failedTypeCount: 1, isFullSweep: true))

        // After >1 hour, failing full sweep alerts again.
        clock.now = clock.now.addingTimeInterval(3100)
        XCTAssertTrue(manager.recordCompletionOutcome(failedTypeCount: 1, isFullSweep: true))

        // Only a clean FULL sweep clears the streak.
        XCTAssertFalse(manager.recordCompletionOutcome(failedTypeCount: 0, isFullSweep: true))
        XCTAssertEqual(notifications.currentFailureStreak, 0)
    }

    // MARK: - Issue 7 (P2): QRScannerView single emission

    @MainActor
    func testIssue7_ScannerEmitsScannedCodeAtMostOnce() {
        let scanner = ScannerViewController()
        var received: [String] = []
        scanner.onResult = { received.append($0) }

        XCTAssertFalse(scanner.handleScannedCode(nil))
        XCTAssertFalse(scanner.handleScannedCode(""))
        XCTAssertTrue(scanner.handleScannedCode("api-key-123"))
        XCTAssertEqual(scanner.scannerState, .scanned)

        // Consecutive camera frames arriving before stopRunning completes are ignored.
        XCTAssertFalse(scanner.handleScannedCode("api-key-123"))
        XCTAssertFalse(scanner.handleScannedCode("api-key-456"))
        XCTAssertEqual(received, ["api-key-123"])
    }

    // MARK: - Issue 8 (P3): DashboardView monotonic fetch generation guard

    func testIssue8_FetchGenerationGuardRejectsSupersededRequests() {
        var guardState = FetchGenerationGuard()
        let gen1 = guardState.beginNext()
        XCTAssertTrue(guardState.isCurrent(gen1))

        let gen2 = guardState.beginNext()
        XCTAssertFalse(guardState.isCurrent(gen1), "Older request must not overwrite newer refresh")
        XCTAssertTrue(guardState.isCurrent(gen2))
    }

    // MARK: - Supporting Phase 1 Invariant: Cached LAN IP fallback & host matching

    func testServerResolverLocalHostAndCachedIPFallbackLifecycle() {
        let hostURL = URL(string: "https://TestHost-\(UUID().uuidString.prefix(6)).lan:8443")!
        let host = ServerResolver.canonicalHost(hostURL.host!)
        defer { ServerResolver.revokeApproval(matchingHost: host) }

        XCTAssertTrue(ServerResolver.isLocalOnlyHost(hostURL))
        XCTAssertTrue(ServerResolver.isLocalOnlyHost(URL(string: "https://192.168.1.10:8443")!))
        XCTAssertFalse(ServerResolver.isLocalOnlyHost(URL(string: "https://sync.example.com:8443")!))
        XCTAssertFalse(ServerResolver.isLocalOnlyHost(URL(string: "https://100.64.0.5:8443")!))

        ServerResolver.approve(hostURL)
        ServerResolver.rememberResolvedIP("192.168.1.77", for: hostURL)

        let fallback = ServerResolver.cachedFallbackURL(for: hostURL)
        XCTAssertEqual(fallback?.absoluteString, "https://192.168.1.77:8443")

        let match = ServerResolver.approvedHost(forChallengeHost: "192.168.1.77")
        XCTAssertEqual(match?.logicalHost, host)
        XCTAssertEqual(match?.viaCachedIP, true)

        ServerResolver.revokeApproval(matchingHost: host)
        XCTAssertNil(ServerResolver.cachedFallbackURL(for: hostURL))
        XCTAssertNil(ServerResolver.approvedHost(forChallengeHost: "192.168.1.77"))
    }

    // MARK: - 24h Heart Rate Summary Bucketing & Indicators

    func testHeartRate24hSummaryBucketsRangesGapsAndIndicators() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let samples: [HeartRateSamplePoint] = [
            // Outside 24h window — must be excluded.
            HeartRateSamplePoint(date: now.addingTimeInterval(-25 * 3600), bpm: 199),
            // Two samples inside the same 15-min bucket.
            HeartRateSamplePoint(date: now.addingTimeInterval(-4 * 3600 + 60), bpm: 60),
            HeartRateSamplePoint(date: now.addingTimeInterval(-4 * 3600 + 300), bpm: 80),
            // Next contiguous bucket (within 45-min threshold) -> same segmentId (0).
            HeartRateSamplePoint(date: now.addingTimeInterval(-3 * 3600 - 1800), bpm: 75),
            // After a 2-hour gap -> increments segmentId (1).
            HeartRateSamplePoint(date: now.addingTimeInterval(-30 * 60), bpm: 110),
        ]

        let summary = HeartRate24hSummary.build(
            samples: samples,
            restingHeartRateBPM: 52,
            hrvSamples24h: [40, 60, 80],
            fallbackHRV: 35,
            windowEnd: now
        )

        XCTAssertEqual(summary.buckets.count, 3)
        XCTAssertEqual(summary.buckets[0].minBPM, 60)
        XCTAssertEqual(summary.buckets[0].maxBPM, 80)
        XCTAssertEqual(summary.buckets[0].avgBPM, 70)
        XCTAssertEqual(summary.buckets[0].segmentId, 0)
        XCTAssertEqual(summary.buckets[1].segmentId, 0)
        XCTAssertEqual(summary.buckets[2].segmentId, 1)
        XCTAssertEqual(summary.latestBPM, 110)
        XCTAssertEqual(summary.minBPM, 60)
        XCTAssertEqual(summary.maxBPM, 110)
        XCTAssertEqual(summary.restingHeartRateBPM, 52)
        XCTAssertEqual(summary.hrvMilliseconds, 60)
        XCTAssertTrue(summary.hrvIs24hAverage)
        XCTAssertLessThanOrEqual(summary.yAxisDomain.lowerBound, 52)
        XCTAssertGreaterThanOrEqual(summary.yAxisDomain.upperBound, 110)

        // When 24h HRV is empty, falls back to latest 48h HRV and flags hrvIs24hAverage = false.
        let fallbackSummary = HeartRate24hSummary.build(
            samples: [],
            restingHeartRateBPM: nil,
            hrvSamples24h: [],
            fallbackHRV: 48,
            windowEnd: now
        )
        XCTAssertEqual(fallbackSummary.hrvMilliseconds, 48)
        XCTAssertFalse(fallbackSummary.hrvIs24hAverage)
    }

    // MARK: - 24h Sleep Deduplication, Union-Merge & Stage Breakdown

    func testSleep24hSummaryDeduplicatesMultiWriterSourcesAndMergesOverlaps() {
        let now = Date(timeIntervalSince1970: 1_700_200_000)
        let bed = now.addingTimeInterval(-10 * 3600)

        let samples: [RawSleepSample] = [
            // Apple Watch granular stages (with an overlapping deep/core boundary)
            RawSleepSample(
                startDate: bed,
                endDate: bed.addingTimeInterval(2 * 3600),
                categoryValue: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceKey: "Tom's Apple Watch",
                isWatchSource: true
            ),
            RawSleepSample(
                startDate: bed.addingTimeInterval(1.5 * 3600), // 30m overlap with Core above
                endDate: bed.addingTimeInterval(3.5 * 3600),
                categoryValue: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                sourceKey: "Tom's Apple Watch",
                isWatchSource: true
            ),
            RawSleepSample(
                startDate: bed.addingTimeInterval(3.5 * 3600),
                endDate: bed.addingTimeInterval(4.0 * 3600),
                categoryValue: HKCategoryValueSleepAnalysis.awake.rawValue,
                sourceKey: "Tom's Apple Watch",
                isWatchSource: true
            ),
            RawSleepSample(
                startDate: bed.addingTimeInterval(4.0 * 3600),
                endDate: bed.addingTimeInterval(6.0 * 3600),
                categoryValue: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                sourceKey: "Tom's Apple Watch",
                isWatchSource: true
            ),
            // Duplicate inBed sample (must be ignored)
            RawSleepSample(
                startDate: bed,
                endDate: bed.addingTimeInterval(6.0 * 3600),
                categoryValue: HKCategoryValueSleepAnalysis.inBed.rawValue,
                sourceKey: "Tom's Apple Watch",
                isWatchSource: true
            ),
            // Competing iPhone Clock writer (must NOT double-count sleep!)
            RawSleepSample(
                startDate: bed,
                endDate: bed.addingTimeInterval(7.0 * 3600),
                categoryValue: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                sourceKey: "Clock",
                isWatchSource: false
            ),
        ]

        let summary = Sleep24hSummary.build(samples: samples, windowEnd: now)

        XCTAssertEqual(summary.selectedSourceName, "Tom's Apple Watch")
        // Total asleep union-merged: [0..3.5h] + [4.0..6.0h] = 5.5h (NOT 6.0h or 12.5h!)
        XCTAssertEqual(summary.totalAsleepHours, 5.5, accuracy: 0.001)
        XCTAssertEqual(summary.awakeSeconds, 1800, accuracy: 1)
        XCTAssertEqual(summary.deepSeconds, 7200, accuracy: 1)
        XCTAssertEqual(summary.remSeconds, 7200, accuracy: 1)
        XCTAssertEqual(summary.coreSeconds, 7200, accuracy: 1)
        XCTAssertEqual(Sleep24hSummary.formatDuration(summary.totalAsleepSeconds), "5h 30m")
    }

    // MARK: - Readiness Score Baseline Calibration & Weight Normalization

    func testReadinessSummaryScoresOptimalAndStrainedStatesAndNormalizesMissingSensors() {
        // Strong recovery across all 4 signals -> Optimal (85-100)
        let optimal = ReadinessSummary.build(
            hrvToday: 75,
            hrvBaseline14d: 60,
            rhrToday: 49,
            rhrBaseline14d: 52,
            sleepHours24h: 8.0,
            restorativeSleepShare: 0.42,
            wristTempTodayC: 36.5,
            wristTempBaseline14dC: 36.45
        )
        XCTAssertNotNil(optimal.score)
        XCTAssertEqual(optimal.tier, .optimal)
        XCTAssertEqual(optimal.availableFactorCount, 4)
        XCTAssertGreaterThanOrEqual(optimal.score ?? 0, 85)

        // Elevated RHR, low HRV, short sleep, feverish wrist temp -> Take It Easy (<55)
        let strained = ReadinessSummary.build(
            hrvToday: 34,
            hrvBaseline14d: 60,
            rhrToday: 60,
            rhrBaseline14d: 52,
            sleepHours24h: 4.5,
            restorativeSleepShare: 0.20,
            wristTempTodayC: 37.5,
            wristTempBaseline14dC: 36.5
        )
        XCTAssertEqual(strained.tier, .recover)
        XCTAssertLessThan(strained.score ?? 100, 55)

        // Missing wrist temp & HRV still produces a normalized score from RHR + Sleep.
        let partial = ReadinessSummary.build(
            hrvToday: nil,
            hrvBaseline14d: nil,
            rhrToday: 52,
            rhrBaseline14d: 52,
            sleepHours24h: 7.5,
            restorativeSleepShare: 0.38,
            wristTempTodayC: nil,
            wristTempBaseline14dC: nil
        )
        XCTAssertEqual(partial.availableFactorCount, 2)
        XCTAssertNotNil(partial.score)
        XCTAssertGreaterThanOrEqual(partial.score ?? 0, 80)

        // No signals -> nil score
        let empty = ReadinessSummary.build(
            hrvToday: nil,
            hrvBaseline14d: nil,
            rhrToday: nil,
            rhrBaseline14d: nil,
            sleepHours24h: nil,
            restorativeSleepShare: nil,
            wristTempTodayC: nil,
            wristTempBaseline14dC: nil
        )
        XCTAssertNil(empty.score)
        XCTAssertTrue(empty.factors.isEmpty)
    }

    // MARK: - SyncHistoryIndex & Unified HealthVitalsSnapshot

    func testSyncHistoryIndexPrecomputesTotalsCategoriesAndBinarySearchNearestMonth() {
        let jan = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
        let feb = Date(timeIntervalSince1970: 1_706_745_600) // 2024-02-01
        let mar = Date(timeIntervalSince1970: 1_709_251_200) // 2024-03-01

        let points = [
            SyncDataPoint(date: jan, type: "Heart Rate", count: 1000),
            SyncDataPoint(date: jan, type: "Steps", count: 500),
            SyncDataPoint(date: feb, type: "Heart Rate", count: 2000),
            SyncDataPoint(date: mar, type: "Sleep", count: 300)
        ]

        let allIndex = SyncHistoryIndex.build(from: points, selectedCategory: nil)
        XCTAssertEqual(allIndex.sortedMonths, [jan, feb, mar])
        XCTAssertEqual(allIndex.total(for: jan), 1500)
        XCTAssertEqual(allIndex.count(for: jan, category: "Steps"), 500)
        XCTAssertEqual(allIndex.nearestMonth(to: feb.addingTimeInterval(-3 * 86400)), feb)
        XCTAssertEqual(allIndex.nearestMonth(to: jan.addingTimeInterval(-86400)), jan)
        XCTAssertEqual(allIndex.nearestMonth(to: mar.addingTimeInterval(10 * 86400)), mar)

        let hrOnly = SyncHistoryIndex.build(from: points, selectedCategory: "Heart Rate")
        XCTAssertEqual(hrOnly.sortedMonths, [jan, feb])
        XCTAssertEqual(hrOnly.total(for: jan), 1000)
        XCTAssertEqual(hrOnly.visiblePoints.count, 2)
        // Category breakdown still preserves all categories for scrubbing pills.
        XCTAssertEqual(hrOnly.count(for: jan, category: "Steps"), 500)
    }

    func testHealthVitalsSnapshotProducesConsistentHeartRateSleepAndReadiness() {
        let now = Date(timeIntervalSince1970: 1_700_300_000)
        let hr = [
            HeartRateSamplePoint(date: now.addingTimeInterval(-2 * 3600), bpm: 64),
            HeartRateSamplePoint(date: now.addingTimeInterval(-30 * 60), bpm: 72)
        ]
        let rhr = [
            TimedQuantitySample(date: now.addingTimeInterval(-5 * 86400), value: 54),
            TimedQuantitySample(date: now.addingTimeInterval(-3 * 86400), value: 54),
            TimedQuantitySample(date: now.addingTimeInterval(-2 * 86400), value: 54),
            TimedQuantitySample(date: now.addingTimeInterval(-6 * 3600), value: 51)
        ]
        let hrv = [
            TimedQuantitySample(date: now.addingTimeInterval(-5 * 86400), value: 55),
            TimedQuantitySample(date: now.addingTimeInterval(-3 * 86400), value: 55),
            TimedQuantitySample(date: now.addingTimeInterval(-2 * 86400), value: 55),
            TimedQuantitySample(date: now.addingTimeInterval(-6 * 3600), value: 66)
        ]
        let sleep = [
            RawSleepSample(
                startDate: now.addingTimeInterval(-10 * 3600),
                endDate: now.addingTimeInterval(-2 * 3600),
                categoryValue: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceKey: "Apple Watch",
                isWatchSource: true
            )
        ]

        let snapshot = HealthVitalsSnapshot.build(
            heartRate24h: hr,
            rhr14d: rhr,
            hrv14d: hrv,
            sleep36h: sleep,
            wristTemp14d: [],
            windowEnd: now
        )

        // Heart Rate card and Readiness card agree on exact RHR, HRV, and Sleep values.
        XCTAssertEqual(snapshot.heartRate.restingHeartRateBPM, 51)
        XCTAssertEqual(snapshot.heartRate.hrvMilliseconds, 66)
        XCTAssertEqual(snapshot.heartRate.sleepWindows.count, 1)
        XCTAssertEqual(snapshot.heartRate.sleepWindows[0].asleepSeconds, 8 * 3600, accuracy: 1.0)
        XCTAssertEqual(snapshot.sleep.totalAsleepHours, 8.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.readiness.availableFactorCount, 3)
        XCTAssertEqual(snapshot.readiness.tier, .optimal)
    }

    @MainActor
    func testVitalsSnapshotCacheSavesReloadsAndExpiresStaleSnapshots() {
        let tempCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitals-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCacheURL) }

        let now = Date()
        let snapshot = HealthVitalsSnapshot.build(
            heartRate24h: [HeartRateSamplePoint(date: now.addingTimeInterval(-1800), bpm: 68)],
            rhr14d: [TimedQuantitySample(date: now.addingTimeInterval(-3600), value: 53)],
            hrv14d: [TimedQuantitySample(date: now.addingTimeInterval(-3600), value: 64)],
            sleep36h: [
                RawSleepSample(
                    startDate: now.addingTimeInterval(-9 * 3600),
                    endDate: now.addingTimeInterval(-2 * 3600),
                    categoryValue: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    sourceKey: "Apple Watch",
                    isWatchSource: true
                )
            ],
            wristTemp14d: [],
            windowEnd: now
        )

        let cache = VitalsSnapshotCache(fileURL: tempCacheURL, maxAge: 48 * 3600)
        cache.save(snapshot, now: now)

        // Fresh load within 48h restores exact snapshot immediately.
        XCTAssertEqual(cache.load(now: now.addingTimeInterval(3600)), snapshot)

        // Stale cache older than maxAge is ignored cleanly.
        XCTAssertNil(cache.load(now: now.addingTimeInterval(49 * 3600)))

        // Store seeds immediately from valid cache on init, then transitions cleanly on refresh.
        let store = HealthVitalsStore(cache: cache)
        XCTAssertEqual(store.heartRate, snapshot.heartRate)
        XCTAssertEqual(store.sleep, snapshot.sleep)
        XCTAssertEqual(store.readiness, snapshot.readiness)

        let refreshed = HealthVitalsSnapshot.build(
            heartRate24h: [HeartRateSamplePoint(date: now.addingTimeInterval(-60), bpm: 74)],
            rhr14d: [TimedQuantitySample(date: now.addingTimeInterval(-3600), value: 52)],
            hrv14d: [TimedQuantitySample(date: now.addingTimeInterval(-3600), value: 70)],
            sleep36h: [],
            wristTemp14d: [],
            windowEnd: now
        )
        store.apply(refreshed, animated: false)
        XCTAssertEqual(store.heartRate, refreshed.heartRate)
        XCTAssertEqual(store.readiness, refreshed.readiness)
    }

    func testReviewFinding2_NonStagedSleepDoesNotPenalizeReadinessWithZeroRestorativeShare() {
        let now = Date()
        let sleepSamples = [
            RawSleepSample(
                startDate: now.addingTimeInterval(-9 * 3600),
                endDate: now.addingTimeInterval(-1 * 3600), // 8 hours asleepUnspecified
                categoryValue: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                sourceKey: "Clock",
                isWatchSource: false
            )
        ]

        let snapshot = HealthVitalsSnapshot.build(
            heartRate24h: [],
            rhr14d: [],
            hrv14d: [],
            sleep36h: sleepSamples,
            wristTemp14d: [],
            windowEnd: now
        )

        XCTAssertFalse(snapshot.sleep.hasGranularStages)
        XCTAssertNil(snapshot.sleep.restorativeShare, "Non-staged sleep must not report 0% restorative share")
        let sleepFactor = snapshot.readiness.factors.first(where: { $0.id == "sleep" })
        XCTAssertEqual(sleepFactor?.detailText, "Last 24h")
        XCTAssertEqual(snapshot.readiness.score, 100)
    }

    @MainActor
    func testReviewFinding3_VitalsStorePreservesCachedSnapshotOnQueryError() async {
        let tempCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitals-err-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCacheURL) }

        let now = Date()
        let cachedSnapshot = HealthVitalsSnapshot.build(
            heartRate24h: [HeartRateSamplePoint(date: now.addingTimeInterval(-600), bpm: 66)],
            rhr14d: [TimedQuantitySample(date: now.addingTimeInterval(-3600), value: 52)],
            hrv14d: [TimedQuantitySample(date: now.addingTimeInterval(-3600), value: 65)],
            sleep36h: [],
            wristTemp14d: [],
            windowEnd: now
        )
        let cache = VitalsSnapshotCache(fileURL: tempCacheURL)
        cache.save(cachedSnapshot, now: now)

        let fetchAttempted = expectation(description: "failing fetch executed")
        let store = HealthVitalsStore(cache: cache, fetcher: { _ in
            fetchAttempted.fulfill()
            throw HKError(.errorDatabaseInaccessible)
        })

        // Seeded from cache immediately.
        XCTAssertEqual(store.heartRate, cachedSnapshot.heartRate)

        store.refresh(healthStore: HKHealthStore(), isAuthorized: true)
        await fulfillment(of: [fetchAttempted], timeout: 2.0)
        // Give MainActor catch block a turn to finish.
        await Task.yield()

        // Cached state and disk file remain intact despite locked-database error.
        XCTAssertEqual(store.heartRate, cachedSnapshot.heartRate)
        XCTAssertEqual(store.readiness, cachedSnapshot.readiness)
        XCTAssertEqual(cache.load(), cachedSnapshot)
    }

    func testHeartRate24hSummaryClipsWorkoutsAndMatchesScrubbedTimestamp() {
        let now = Date()
        let runStart = now.addingTimeInterval(-3 * 3600)
        let runEnd = now.addingTimeInterval(-2 * 3600 - 15 * 60) // 45m run
        let oldStart = now.addingTimeInterval(-28 * 3600)
        let oldEnd = now.addingTimeInterval(-27 * 3600) // outside 24h window

        let workouts = [
            HeartRateWorkoutWindow(
                start: oldStart,
                end: oldEnd,
                activityName: "Walk",
                symbolName: "figure.walk",
                durationMinutes: 60,
                activeKilocalories: 220
            ),
            HeartRateWorkoutWindow(
                start: runStart,
                end: runEnd,
                activityName: "Run",
                symbolName: "figure.run",
                durationMinutes: 45,
                activeKilocalories: nil
            ),
            HeartRateWorkoutWindow(
                start: runStart,
                end: runEnd,
                activityName: "Run",
                symbolName: "figure.run",
                durationMinutes: 45,
                activeKilocalories: 480
            )
        ]

        let summary = HeartRate24hSummary.build(
            samples: [HeartRateSamplePoint(date: runStart.addingTimeInterval(600), bpm: 158)],
            workouts: workouts,
            restingHeartRateBPM: 52,
            hrvSamples24h: [64],
            fallbackHRV: nil,
            windowEnd: now
        )

        // Identical duplicate workouts from multiple writers collapse to one entry, preferring kcal.
        XCTAssertEqual(summary.workouts.count, 1)
        XCTAssertEqual(summary.totalActivitySeconds, 45 * 60, accuracy: 1.0)
        XCTAssertEqual(summary.workouts[0].activityName, "Run")
        XCTAssertEqual(summary.workouts[0].activeKilocalories, 480)
        XCTAssertEqual(summary.workout(at: runStart.addingTimeInterval(600))?.activityName, "Run")
        XCTAssertNil(summary.workout(at: now.addingTimeInterval(-30 * 60)))
    }

    func testHeartRate24hSummaryGroupsSleepWindowsAcrossBriefAwakeningsAndSplitsNaps() {
        let now = Date()
        // Overnight sleep: 14h..11h ago (core), 15m awake gap, 10h45m..7h ago (deep/REM) -> 1 merged window
        // Afternoon nap: 3h..2h15m ago (45m core) -> separate 2nd window (> 45m gap from overnight)
        let overnightStart = now.addingTimeInterval(-14 * 3600)
        let awakeStart = now.addingTimeInterval(-11 * 3600)
        let awakeEnd = now.addingTimeInterval(-10 * 3600 - 45 * 60)
        let overnightEnd = now.addingTimeInterval(-7 * 3600)
        let napStart = now.addingTimeInterval(-3 * 3600)
        let napEnd = now.addingTimeInterval(-2 * 3600 - 15 * 60)

        let segments = [
            SleepSegment(start: overnightStart, end: awakeStart, stage: .core),
            SleepSegment(start: awakeStart, end: awakeEnd, stage: .awake),
            SleepSegment(start: awakeEnd, end: overnightEnd, stage: .deep),
            SleepSegment(start: napStart, end: napEnd, stage: .core)
        ]

        let windows = HeartRateSleepWindow.windows(from: segments)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, overnightStart)
        XCTAssertEqual(windows[0].end, overnightEnd)
        // 3h + 3h45m = 6h45m asleep (excluding the 15m awake gap)
        XCTAssertEqual(windows[0].asleepSeconds, 6.75 * 3600, accuracy: 1.0)
        XCTAssertEqual(windows[1].start, napStart)
        XCTAssertEqual(windows[1].end, napEnd)
        XCTAssertEqual(windows[1].asleepSeconds, 45 * 60, accuracy: 1.0)

        let summary = HeartRate24hSummary.build(
            samples: [HeartRateSamplePoint(date: overnightStart.addingTimeInterval(3600), bpm: 54)],
            sleepWindows: windows,
            restingHeartRateBPM: 52,
            hrvSamples24h: [64],
            fallbackHRV: nil,
            windowEnd: now
        )

        XCTAssertEqual(summary.sleepWindows.count, 2)
        XCTAssertEqual(summary.totalSleepSeconds, 7.5 * 3600, accuracy: 1.0)
        XCTAssertEqual(summary.sleepWindow(at: overnightStart.addingTimeInterval(3600))?.id, windows[0].id)
        XCTAssertEqual(summary.sleepWindow(at: napStart.addingTimeInterval(600))?.id, windows[1].id)
        XCTAssertNil(summary.sleepWindow(at: now.addingTimeInterval(-5 * 3600)))
    }

    func testEnergy7dSummaryComputesTDEECompletedDayAverageAndNearestDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_500_000) // arbitrary UTC date
        let todayStart = calendar.startOfDay(for: now)
        let dayMinus1 = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let dayMinus2 = calendar.date(byAdding: .day, value: -2, to: todayStart)!
        let dayMinus3 = calendar.date(byAdding: .day, value: -3, to: todayStart)!

        // 2 prior completed days + partial today; dayMinus3 deliberately empty (should not drag avg down)
        let dailyBasal: [Date: Double] = [
            dayMinus2: 1700,
            dayMinus1: 1800,
            todayStart: 900 // partial day
        ]
        let dailyActive: [Date: Double] = [
            dayMinus2: 500, // TDEE 2200
            dayMinus1: 800, // TDEE 2600
            todayStart: 300 // TDEE 1200
        ]

        let summary = Energy7dSummary.build(
            dailyBasal: dailyBasal,
            dailyActive: dailyActive,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.days.count, 7)
        XCTAssertTrue(summary.hasAnyData)
        XCTAssertEqual(summary.today?.basalKcal, 900)
        XCTAssertEqual(summary.today?.activeKcal, 300)
        XCTAssertEqual(summary.today?.tdeeKcal, 1200)
        XCTAssertEqual(summary.today?.basalShare ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(summary.today?.activeShare ?? 0, 0.25, accuracy: 0.001)

        // Average uses only the 2 prior completed days with data (2200 and 2600 -> 2400).
        XCTAssertEqual(summary.averagedDayCount, 2)
        XCTAssertEqual(summary.averageTDEE ?? 0, 2400, accuracy: 0.01)
        XCTAssertEqual(summary.averageBasal ?? 0, 1750, accuracy: 0.01)
        XCTAssertEqual(summary.averageActive ?? 0, 650, accuracy: 0.01)

        // Nearest-day scrubbing picks the right day bucket by midpoint.
        XCTAssertEqual(summary.nearestDay(to: dayMinus1.addingTimeInterval(14 * 3600))?.date, dayMinus1)
        XCTAssertEqual(summary.nearestDay(to: dayMinus3.addingTimeInterval(10 * 3600))?.date, dayMinus3)

        // When only today has data, average falls back cleanly to today and X-axis still spans 7 full days.
        let todayOnly = Energy7dSummary.build(
            dailyBasal: [todayStart: 1500],
            dailyActive: [todayStart: 400],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(todayOnly.averagedDayCount, 1)
        XCTAssertEqual(todayOnly.averageTDEE ?? 0, 1900, accuracy: 0.01)
        XCTAssertEqual(
            todayOnly.xAxisDomain.upperBound.timeIntervalSince(todayOnly.xAxisDomain.lowerBound),
            7 * 86_400,
            accuracy: 1.0
        )
    }

    func testSplashWaveformMathRPeakAlignmentAndLubDubScale() {
        XCTAssertEqual(SplashWaveformMath.ecgLUT.count, SplashWaveformMath.sampleCount + 1)

        // Flat baseline at edges, strong R-peak dead center (u = 0.50), S-wave dip right after.
        XCTAssertEqual(SplashWaveformMath.ecgAmplitude(at: 0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(SplashWaveformMath.ecgAmplitude(at: 1.0), 0.0, accuracy: 0.001)
        XCTAssertGreaterThan(SplashWaveformMath.ecgAmplitude(at: 0.50), 0.95)
        XCTAssertLessThan(SplashWaveformMath.ecgAmplitude(at: 0.535), -0.20)

        // Lub-dub beat peaks around 0.44s and 0.63s and rests at 1.0 outside the beat.
        XCTAssertEqual(SplashWaveformMath.lubDubScale(at: 0.0), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(SplashWaveformMath.lubDubScale(at: 0.44), 1.05)
        XCTAssertGreaterThan(SplashWaveformMath.lubDubScale(at: 0.63), 1.02)
        XCTAssertEqual(SplashWaveformMath.lubDubScale(at: 1.3), 1.0, accuracy: 0.001)
    }

    func testServerStatsResponseDecodesArchiveTotalAndLegacyFormat() throws {
        let modernJSON = Data("""
        {
          "stats": [
            { "date": "2026-09-01", "type": "Heart Rate", "count": 12000 },
            { "date": "2026-10-01", "type": "Sleep", "count": 450 }
          ],
          "total_records": 15000
        }
        """.utf8)
        let modern = try JSONDecoder().decode(ServerStatsResponse.self, from: modernJSON)
        XCTAssertEqual(modern.stats.count, 2)
        XCTAssertEqual(modern.totalRecords, 15000)

        let legacyJSON = Data("""
        {
          "stats": [
            { "date": "2026-09-01", "type": "Steps", "count": 3000 }
          ]
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(ServerStatsResponse.self, from: legacyJSON)
        XCTAssertEqual(legacy.stats.count, 1)
        XCTAssertNil(legacy.totalRecords)
    }

    @MainActor
    func testServerConnectionStatusRequiresApiKeyAndVerifiedPing() async {
        let serverURL = URL(string: "https://mac.lan:8443")!

        // Saved customServerURL in local storage WITHOUT an API key must never report connected.
        let noKey = ServerConnectionStatus.preliminary(
            overrideRaw: serverURL.absoluteString,
            discovered: nil,
            apiKey: "   "
        )
        XCTAssertEqual(noKey.status, .missingApiKey(serverURL))
        XCTAssertNil(noKey.urlToProbe)
        XCTAssertFalse(noKey.status!.canInitiateSync)

        // With an API key present, preliminary yields urlToProbe so the UI verifies via /ping.
        let withKey = ServerConnectionStatus.preliminary(
            overrideRaw: serverURL.absoluteString,
            discovered: nil,
            apiKey: "secret-key"
        )
        XCTAssertNil(withKey.status)
        XCTAssertEqual(withKey.urlToProbe, serverURL)

        // Ping results map to exact states and sync gating.
        let connected = ServerConnectionStatus.from(pingResult: .ok, url: serverURL)
        XCTAssertEqual(connected, .connected(serverURL))
        XCTAssertTrue(connected.canInitiateSync)

        let rejected = ServerConnectionStatus.from(pingResult: .unauthorized, url: serverURL)
        XCTAssertEqual(rejected, .unauthorized(serverURL))
        XCTAssertFalse(rejected.canInitiateSync)

        let offline = ServerConnectionStatus.from(pingResult: .unreachable("Timed out"), url: serverURL)
        XCTAssertEqual(offline, .unreachable(serverURL, "Timed out"))
        XCTAssertTrue(offline.canInitiateSync)

        // performSync must skip cleanly without hitting HealthKit or uploading when apiKey is empty.
        let suiteName = "test-empty-key-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = HealthQueryManager(defaults: defaults)
        let engine = SyncEngine(sessionIdentifier: "test-empty-key", createBackgroundSession: false)
        let outcome = await manager.performSync(syncEngine: engine, serverURL: serverURL, apiKey: "")
        XCTAssertEqual(outcome, .skipped)
    }

    func testCardioFitness30dSummaryAveragesPerDayComputesDeltaAndPreferredMetric() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        let vo2Samples = [
            // Outside 30-day window -> must be ignored
            TimedQuantitySample(date: now.addingTimeInterval(-35 * 86_400), value: 39.0),
            // Day -20: two readings on the same day -> averaged to 45.0
            TimedQuantitySample(date: now.addingTimeInterval(-20 * 86_400 - 3600), value: 44.0),
            TimedQuantitySample(date: now.addingTimeInterval(-20 * 86_400), value: 46.0),
            // Day -2: latest 47.4
            TimedQuantitySample(date: now.addingTimeInterval(-2 * 86_400), value: 47.4)
        ]
        let hrrSamples = [
            TimedQuantitySample(date: now.addingTimeInterval(-10 * 86_400), value: 28),
            TimedQuantitySample(date: now.addingTimeInterval(-1 * 86_400), value: 36)
        ]
        let walkingSamples = [
            TimedQuantitySample(date: now.addingTimeInterval(-15 * 86_400), value: 98),
            TimedQuantitySample(date: now.addingTimeInterval(-3 * 86_400), value: 92)
        ]

        let summary = CardioFitness30dSummary.build(
            vo2Max30d: vo2Samples,
            heartRateRecovery30d: hrrSamples,
            walkingHeartRate30d: walkingSamples,
            windowEnd: now,
            calendar: calendar
        )

        XCTAssertTrue(summary.hasAnyData)
        XCTAssertEqual(summary.preferredMetric, .vo2Max)
        XCTAssertEqual(summary.vo2Max.points.count, 2)
        XCTAssertEqual(summary.vo2Max.latest ?? 0, 47.4, accuracy: 0.01)
        XCTAssertEqual(summary.vo2Max.average ?? 0, 46.2, accuracy: 0.01)
        XCTAssertEqual(summary.vo2Max.delta ?? 0, 2.4, accuracy: 0.01)

        XCTAssertEqual(summary.heartRateRecovery.latest ?? 0, 36, accuracy: 0.01)
        XCTAssertEqual(summary.heartRateRecovery.delta ?? 0, 8, accuracy: 0.01)

        XCTAssertEqual(summary.walkingHeartRate.latest ?? 0, 92, accuracy: 0.01)
        XCTAssertEqual(summary.walkingHeartRate.delta ?? 0, -6, accuracy: 0.01)

        // Binary-search nearestPoint picks the closest measurement day.
        let nearFirst = summary.vo2Max.nearestPoint(to: now.addingTimeInterval(-18 * 86_400))
        XCTAssertEqual(nearFirst?.value ?? 0, 45.0, accuracy: 0.01)

        // Falls back to HRR when VO2 Max is absent.
        let hrrOnly = CardioFitness30dSummary.build(
            vo2Max30d: [],
            heartRateRecovery30d: hrrSamples,
            walkingHeartRate30d: [],
            windowEnd: now,
            calendar: calendar
        )
        XCTAssertEqual(hrrOnly.preferredMetric, .heartRateRecovery)
    }

    func testOvernightVitals7dSummaryDetectsOutliersNormalizesSpO2AndComputesWatchStatus() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_500_000))
        let now = baseDay.addingTimeInterval(10 * 3600) // 10:00 UTC, after 04:00 UTC overnight readings
        let todayStart = calendar.startOfDay(for: now)

        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: todayStart)!.addingTimeInterval(4 * 3600)
        }

        // Steady 10-day personal baseline
        let baselineTemp = (-10 ... -1).map { TimedQuantitySample(date: day($0), value: 36.2) }
        let baselineResp = (-10 ... -1).map { TimedQuantitySample(date: day($0), value: 14.2) }
        let baselineSpO2 = (-10 ... -1).map { TimedQuantitySample(date: day($0), value: 0.98) } // HealthKit 0..1 fraction

        // Case 1: All vitals inside baseline -> .typical
        let typical = OvernightVitals7dSummary.build(
            wristTemp14d: baselineTemp + [TimedQuantitySample(date: day(0), value: 36.3)],
            respiratoryRate14d: baselineResp + [TimedQuantitySample(date: day(0), value: 14.5)],
            bloodOxygen14d: baselineSpO2 + [TimedQuantitySample(date: day(0), value: 0.975)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(typical.watchStatus, .typical)
        XCTAssertEqual(typical.latestOutlierCount, 0)
        XCTAssertEqual(typical.availableChannelCount, 3)
        XCTAssertEqual(typical.displayKinds, [.wristTemp, .respiratoryRate, .bloodOxygen])
        XCTAssertEqual(typical.bloodOxygen.latest?.value ?? 0, 97.5, accuracy: 0.1)
        XCTAssertEqual(typical.wristTemp.points.count, 7)

        // Case 2: Multi-signal illness watch (elevated temp +0.7°C & elevated resp +2.6 br/m & SpO2 drop to 93%)
        let elevated = OvernightVitals7dSummary.build(
            wristTemp14d: baselineTemp + [TimedQuantitySample(date: day(0), value: 36.9)],
            respiratoryRate14d: baselineResp + [TimedQuantitySample(date: day(0), value: 16.8)],
            bloodOxygen14d: baselineSpO2 + [TimedQuantitySample(date: day(0), value: 0.93)],
            breathingDisturbances14d: [TimedQuantitySample(date: day(0), value: 3.0)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(elevated.watchStatus, .elevated)
        XCTAssertEqual(elevated.latestOutlierCount, 3)
        XCTAssertEqual(elevated.wristTemp.latest?.outlierState, .high)
        XCTAssertEqual(elevated.respiratoryRate.latest?.outlierState, .high)
        XCTAssertEqual(elevated.bloodOxygen.latest?.outlierState, .low)
        XCTAssertEqual(elevated.displayKinds.count, 4, "Includes breathing disturbances when present")
        XCTAssertTrue(elevated.series(for: elevated.preferredKind).isLatestOutlier)
    }

    func testGaitBiomechanics30dSummaryClassifiesZonesNormalizesUnitsAndComputesInclination() {
        let now = Date()
        let earlier = now.addingTimeInterval(-14 * 86_400)
        let recent = now.addingTimeInterval(-2 * 86_400)

        // Healthy balanced gait (HealthKit fractional percentages and meters)
        let balanced = GaitBiomechanics30dSummary.build(
            walkingSpeed30d: [
                TimedQuantitySample(date: earlier, value: 1.32),
                TimedQuantitySample(date: recent, value: 1.42)
            ],
            stepLength30d: [
                TimedQuantitySample(date: earlier, value: 0.70),
                TimedQuantitySample(date: recent, value: 0.74)
            ],
            asymmetry30d: [TimedQuantitySample(date: recent, value: 0.015)],
            doubleSupport30d: [TimedQuantitySample(date: recent, value: 0.27)],
            steadiness30d: [TimedQuantitySample(date: recent, value: 0.92)],
            windowEnd: now
        )
        XCTAssertTrue(balanced.hasAnyData)
        XCTAssertEqual(balanced.overallTier, .optimal)
        XCTAssertEqual(balanced.availableMetricCount, 5)
        XCTAssertEqual(balanced.stepLength.formattedValue, "74 cm")
        XCTAssertEqual(balanced.asymmetry.formattedValue, "1.5%")
        XCTAssertEqual(balanced.steadiness.formattedValue, "92%")
        XCTAssertEqual(balanced.doubleSupport.formattedValue, "27%")
        XCTAssertLessThan(balanced.visualInclination, 0.20)
        // 30-day trendlines for walkingSpeed (m/s) and walkingStepLength (cm)
        XCTAssertEqual(balanced.speedSeries.points.count, 2)
        XCTAssertEqual(balanced.speedSeries.delta ?? 0, 0.10, accuracy: 0.001)
        XCTAssertEqual(balanced.stepLengthSeries.points.count, 2)
        XCTAssertEqual(balanced.stepLengthSeries.delta ?? 0, 4.0, accuracy: 0.01)

        // Asymmetric / guarded gait -> caution tier & pronounced visual inclination
        let strained = GaitBiomechanics30dSummary.build(
            walkingSpeed30d: [TimedQuantitySample(date: recent, value: 0.92)],
            stepLength30d: [TimedQuantitySample(date: recent, value: 0.48)],
            asymmetry30d: [TimedQuantitySample(date: recent, value: 0.085)],
            doubleSupport30d: [TimedQuantitySample(date: recent, value: 0.36)],
            steadiness30d: [TimedQuantitySample(date: recent, value: 0.45)],
            windowEnd: now
        )
        XCTAssertEqual(strained.overallTier, .caution)
        XCTAssertEqual(strained.asymmetry.tier, .caution)
        XCTAssertEqual(strained.steadiness.tier, .caution)
        XCTAssertEqual(strained.speed.tier, .caution)
        XCTAssertEqual(strained.stepLength.tier, .caution)
        XCTAssertEqual(strained.doubleSupport.tier, .caution)
        XCTAssertGreaterThan(strained.visualInclination, 0.75)
    }

    @MainActor
    func testIssue9_SupersededVitalsRefreshDoesNotClearIsLoadingWhileNewerFetchInFlight() async {
        let tempCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitals-gen-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCacheURL) }

        final class GateBox: @unchecked Sendable {
            private let lock = NSLock()
            var callCount = 0
            var firstStarted: XCTestExpectation?
            var secondStarted: XCTestExpectation?
            var firstContinuation: CheckedContinuation<HealthVitalsSnapshot, Error>?
            var secondContinuation: CheckedContinuation<HealthVitalsSnapshot, Error>?

            func register(_ cont: CheckedContinuation<HealthVitalsSnapshot, Error>) {
                lock.lock()
                callCount += 1
                let idx = callCount
                if idx == 1 {
                    firstContinuation = cont
                    firstStarted?.fulfill()
                } else if idx == 2 {
                    secondContinuation = cont
                    secondStarted?.fulfill()
                }
                lock.unlock()
            }

            func finishFirst(throwing error: Error) {
                lock.lock()
                let cont = firstContinuation
                firstContinuation = nil
                lock.unlock()
                cont?.resume(throwing: error)
            }

            func finishSecond(returning snapshot: HealthVitalsSnapshot) {
                lock.lock()
                let cont = secondContinuation
                secondContinuation = nil
                lock.unlock()
                cont?.resume(returning: snapshot)
            }
        }

        let gate = GateBox()
        let firstStarted = expectation(description: "gen 1 started")
        let secondStarted = expectation(description: "gen 2 started")
        gate.firstStarted = firstStarted
        gate.secondStarted = secondStarted

        let cache = VitalsSnapshotCache(fileURL: tempCacheURL)
        let store = HealthVitalsStore(cache: cache, fetcher: { _ in
            try await withCheckedThrowingContinuation { cont in
                gate.register(cont)
            }
        })

        // Start generation #1 on an empty cache -> isLoading becomes true.
        store.refresh(healthStore: HKHealthStore(), isAuthorized: true)
        await fulfillment(of: [firstStarted], timeout: 2.0)
        XCTAssertTrue(store.isLoading)

        // Supersede with generation #2 before generation #1 finishes.
        store.refresh(healthStore: HKHealthStore(), isAuthorized: true)
        await fulfillment(of: [secondStarted], timeout: 2.0)
        XCTAssertTrue(store.isLoading)

        // Generation #1 now exits (cancelled/throwing) while generation #2 is STILL in flight.
        gate.finishFirst(throwing: CancellationError())
        await Task.yield()
        await Task.yield()

        // Invariant: superseded generation #1's defer MUST NOT clear isLoading for generation #2.
        XCTAssertTrue(store.isLoading, "Superseded refresh must not clear isLoading while newer fetch is active")

        // When generation #2 completes, snapshot applies and isLoading drops to false.
        let now = Date()
        let snapshot = HealthVitalsSnapshot.build(
            heartRate24h: [HeartRateSamplePoint(date: now.addingTimeInterval(-300), bpm: 64)],
            rhr14d: [],
            hrv14d: [],
            sleep36h: [],
            wristTemp14d: [],
            windowEnd: now
        )
        gate.finishSecond(returning: snapshot)
        for _ in 0..<20 where store.isLoading {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.heartRate, snapshot.heartRate)
    }

    func testIssue9_VitalsSnapshotCacheRejectsFarFutureClockSkewedSnapshots() {
        let tempCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitals-skew-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCacheURL) }

        let now = Date()
        let snapshot = HealthVitalsSnapshot.build(
            heartRate24h: [HeartRateSamplePoint(date: now.addingTimeInterval(-60), bpm: 70)],
            rhr14d: [],
            hrv14d: [],
            sleep36h: [],
            wristTemp14d: [],
            windowEnd: now
        )
        let cache = VitalsSnapshotCache(fileURL: tempCacheURL, maxAge: 48 * 3600)

        // Far-future cachedAt (2 hours ahead of current clock) must be rejected.
        cache.save(snapshot, now: now.addingTimeInterval(2 * 3600))
        XCTAssertNil(cache.load(now: now))

        // Small NTP drift (2 minutes ahead) is still accepted cleanly.
        cache.save(snapshot, now: now.addingTimeInterval(120))
        XCTAssertEqual(cache.load(now: now), snapshot)
    }

    func testIssue10_SyncEngineCheckConnectionRejectsEmptyApiKeyWithoutNetwork() async {
        let engine = SyncEngine(sessionIdentifier: "test-check-conn", createBackgroundSession: false)
        let unreachableURL = URL(string: "https://127.0.0.1:1")!
        let result = await engine.checkConnection(url: unreachableURL, apiKey: "   \n  ")
        XCTAssertEqual(result, .unauthorized)
    }

    func testChartSummariesFilterNonFiniteValuesAndClampDomains() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        // Early-morning timestamp (01:30 UTC) to verify daily noon points clamp inside windowStart...windowEnd.
        let morningNow = utc.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 1, minute: 30))!

        // HeartRate: NaN/inf samples dropped, edge bucket date clamped inside window.
        let hr = HeartRate24hSummary.build(
            samples: [
                HeartRateSamplePoint(date: morningNow.addingTimeInterval(-600), bpm: .nan),
                HeartRateSamplePoint(date: morningNow.addingTimeInterval(-300), bpm: .infinity),
                HeartRateSamplePoint(date: morningNow, bpm: 66)
            ],
            restingHeartRateBPM: 58,
            hrvSamples24h: [52],
            fallbackHRV: nil,
            windowEnd: morningNow
        )
        XCTAssertEqual(hr.buckets.count, 1)
        XCTAssertLessThanOrEqual(hr.buckets[0].date, hr.windowEnd)
        XCTAssertGreaterThanOrEqual(hr.buckets[0].date, hr.windowStart)
        XCTAssertTrue(hr.yAxisDomain.lowerBound.isFinite && hr.yAxisDomain.upperBound.isFinite)

        // CardioFitness: NaN/inf filtered, morning sample clamped to <= windowEnd.
        let cardio = CardioFitness30dSummary.build(
            vo2Max30d: [
                TimedQuantitySample(date: morningNow.addingTimeInterval(-1800), value: .nan),
                TimedQuantitySample(date: morningNow.addingTimeInterval(-900), value: 47.2)
            ],
            heartRateRecovery30d: [],
            walkingHeartRate30d: [],
            windowEnd: morningNow,
            calendar: utc
        )
        XCTAssertEqual(cardio.vo2Max.points.count, 1)
        XCTAssertLessThanOrEqual(cardio.vo2Max.points[0].date, cardio.windowEnd)
        XCTAssertGreaterThanOrEqual(cardio.vo2Max.points[0].date, cardio.windowStart)

        // OvernightVitals: extreme outlier baseline never produces inverted typicalRange, NaN ignored.
        let overnight = OvernightVitals7dSummary.build(
            wristTemp14d: [TimedQuantitySample(date: morningNow.addingTimeInterval(-3600), value: .nan)],
            respiratoryRate14d: [TimedQuantitySample(date: morningNow.addingTimeInterval(-3600), value: 2.0)],
            bloodOxygen14d: [TimedQuantitySample(date: morningNow.addingTimeInterval(-3600), value: 0.70)],
            now: morningNow,
            calendar: utc
        )
        XCTAssertTrue(overnight.wristTemp.isEmpty)
        if let respRange = overnight.respiratoryRate.typicalRange {
            XCTAssertLessThanOrEqual(respRange.lowerBound, respRange.upperBound)
        }
        if let spo2Range = overnight.bloodOxygen.typicalRange {
            XCTAssertLessThanOrEqual(spo2Range.lowerBound, spo2Range.upperBound)
        }

        // Energy: NaN/inf ignored.
        let energy = Energy7dSummary.build(
            dailyBasal: [morningNow: .nan],
            dailyActive: [morningNow: .infinity],
            now: morningNow,
            calendar: utc
        )
        XCTAssertFalse(energy.hasAnyData)
        XCTAssertTrue(energy.yAxisDomain.upperBound.isFinite)

        // Gait: NaN/inf filtered, visualInclination stays finite in 0...1.
        let gait = GaitBiomechanics30dSummary.build(
            walkingSpeed30d: [TimedQuantitySample(date: morningNow.addingTimeInterval(-600), value: .nan)],
            stepLength30d: [TimedQuantitySample(date: morningNow.addingTimeInterval(-600), value: .infinity)],
            asymmetry30d: [TimedQuantitySample(date: morningNow.addingTimeInterval(-600), value: 0.04)],
            doubleSupport30d: [],
            steadiness30d: [TimedQuantitySample(date: morningNow.addingTimeInterval(-600), value: .nan)],
            windowEnd: morningNow
        )
        XCTAssertTrue(gait.visualInclination.isFinite)
        XCTAssertGreaterThanOrEqual(gait.visualInclination, 0.0)
        XCTAssertLessThanOrEqual(gait.visualInclination, 1.0)
    }

    // MARK: - Audit Issue #4 (P0): Workout active energy extraction without deprecated totalEnergyBurned

    func testAuditIssue4_WorkoutActiveEnergyHelperConvertsUnitsAndRejectsInvalidQuantities() {
        let kcalQty = HKQuantity(unit: .kilocalorie(), doubleValue: 325.5)
        XCTAssertEqual(
            HealthQueryManager.workoutActiveEnergyKilocalories(activeEnergyQuantity: kcalQty) ?? -1,
            325.5,
            accuracy: 0.001
        )

        // 4184 J == 1 kcal
        let jouleQty = HKQuantity(unit: .joule(), doubleValue: 4184.0)
        XCTAssertEqual(
            HealthQueryManager.workoutActiveEnergyKilocalories(activeEnergyQuantity: jouleQty) ?? -1,
            1.0,
            accuracy: 0.01
        )

        // Incompatible unit, nil, and non-finite quantities must return nil cleanly.
        let incompatibleQty = HKQuantity(unit: .meter(), doubleValue: 100.0)
        XCTAssertNil(HealthQueryManager.workoutActiveEnergyKilocalories(activeEnergyQuantity: incompatibleQty))
        XCTAssertNil(HealthQueryManager.workoutActiveEnergyKilocalories(activeEnergyQuantity: nil))
        let nanQty = HKQuantity(unit: .kilocalorie(), doubleValue: .nan)
        XCTAssertNil(HealthQueryManager.workoutActiveEnergyKilocalories(activeEnergyQuantity: nanQty))
    }

    // MARK: - Audit Issue #7 (P1): Secondary sweep cursor does not advance before exhaustQuery finishes

    @MainActor
    func testAuditIssue7_SecondarySweepOffsetDoesNotAdvanceBeforeExhaustQueryCompletes() throws {
        let defaults = makeIsolatedDefaults()
        let manager = HealthQueryManager(defaults: defaults)

        let priorType = HKQuantityTypeIdentifier.flightsClimbed.rawValue
        let pageLimitedType = HKQuantityTypeIdentifier.distanceCycling.rawValue
        let priorAnchor = try makeArchivedAnchorData(value: 10)
        let page1Anchor = try makeArchivedAnchorData(value: 20)
        let dummyPoint = HealthDataPoint(
            type: pageLimitedType,
            value: .double(100),
            unit: "m",
            startDate: "2026-11-24T00:00:00Z",
            endDate: "2026-11-24T00:05:00Z",
            source: "Apple Watch",
            uuid: UUID().uuidString,
            metadata: nil
        )

        // Case 1: Page-limited secondary type alone in batch.
        var batch1 = PendingMultiTypeBatch()
        batch1.append(
            typeIdentifier: pageLimitedType,
            dataPoints: [dummyPoint],
            deletedUuids: [],
            newAnchorData: page1Anchor,
            tokenPart: "tok-1",
            nextSweepOffset: 4,
            hitPageLimit: true
        )
        XCTAssertNil(batch1.nextSweepOffset, "Page-limited type must not schedule sweep offset on page-1 flush")

        manager.commitFlushedBatch(anchors: batch1.anchors, nextSweepOffset: batch1.nextSweepOffset)
        // Page-1 anchor IS persisted so page 1 is not re-uploaded, while sweep cursor stays at 0.
        XCTAssertEqual(defaults.data(forKey: "anchor_\(pageLimitedType)"), page1Anchor)
        XCTAssertEqual(manager.currentSweepOffset, 0)

        // Mid-pagination failure, cancellation, or database lock must NOT advance sweep cursor.
        manager.commitExhaustOutcome(.failed, nextSweepOffset: 4)
        XCTAssertEqual(manager.currentSweepOffset, 0)
        manager.commitExhaustOutcome(.cancelled, nextSweepOffset: 4)
        XCTAssertEqual(manager.currentSweepOffset, 0)
        manager.commitExhaustOutcome(.databaseLocked, nextSweepOffset: 4)
        XCTAssertEqual(manager.currentSweepOffset, 0)

        // Only a clean exhaustQuery completion advances sweep cursor past the page-limited type.
        manager.commitExhaustOutcome(.success, nextSweepOffset: 4)
        XCTAssertEqual(manager.currentSweepOffset, 4)

        // Case 2: Earlier completed secondary type (offset -> 3) bundled with page-limited type (offset -> 4).
        defaults.set(2, forKey: "nextTypeSweepOffset")
        var batch2 = PendingMultiTypeBatch()
        batch2.append(
            typeIdentifier: priorType,
            dataPoints: [dummyPoint],
            deletedUuids: [],
            newAnchorData: priorAnchor,
            tokenPart: "tok-prior",
            nextSweepOffset: 3,
            hitPageLimit: false
        )
        batch2.append(
            typeIdentifier: pageLimitedType,
            dataPoints: [dummyPoint],
            deletedUuids: [],
            newAnchorData: page1Anchor,
            tokenPart: "tok-limited",
            nextSweepOffset: 4,
            hitPageLimit: true
        )
        // Batch keeps offset 3 (pointing AT the page-limited type), NOT 4 (past it).
        XCTAssertEqual(batch2.nextSweepOffset, 3)

        manager.commitFlushedBatch(anchors: batch2.anchors, nextSweepOffset: batch2.nextSweepOffset)
        XCTAssertEqual(defaults.data(forKey: "anchor_\(priorType)"), priorAnchor)
        XCTAssertEqual(defaults.data(forKey: "anchor_\(pageLimitedType)"), page1Anchor)
        XCTAssertEqual(manager.currentSweepOffset, 3)

        manager.commitExhaustOutcome(.failed, nextSweepOffset: 4)
        XCTAssertEqual(manager.currentSweepOffset, 3)

        manager.commitExhaustOutcome(.success, nextSweepOffset: 4)
        XCTAssertEqual(manager.currentSweepOffset, 4)
    }

    // MARK: - Audit Issue #8 (P1): ServerResolver.saveApiKey surfaces Keychain write failures

    func testAuditIssue8_ServerResolverSaveApiKeyReportsKeychainFailuresAndPreservesLegacyOnFailure() {
        let defaults = makeIsolatedDefaults()
        defaults.set("legacy-secret", forKey: "apiKey")

        // Delete failure returns false, skips add, and preserves legacy UserDefaults copy.
        var addCalled = false
        let deleteFailed = ServerResolver.saveApiKey(
            "new-secret",
            deleteItem: { _ in errSecInteractionNotAllowed },
            addItem: { _ in
                addCalled = true
                return errSecSuccess
            },
            defaults: defaults
        )
        XCTAssertFalse(deleteFailed)
        XCTAssertFalse(addCalled)
        XCTAssertEqual(defaults.string(forKey: "apiKey"), "legacy-secret")

        // Add failure returns false and preserves legacy UserDefaults copy.
        let addFailed = ServerResolver.saveApiKey(
            "new-secret",
            deleteItem: { _ in errSecItemNotFound },
            addItem: { _ in errSecAuthFailed },
            defaults: defaults
        )
        XCTAssertFalse(addFailed)
        XCTAssertEqual(defaults.string(forKey: "apiKey"), "legacy-secret")

        // Successful write (with errSecItemNotFound on delete) returns true and removes legacy copy.
        var storedPayload: Data?
        let saved = ServerResolver.saveApiKey(
            "  new-secret\n",
            deleteItem: { _ in errSecItemNotFound },
            addItem: { query in
                let dict = query as NSDictionary
                storedPayload = dict[kSecValueData] as? Data
                return errSecSuccess
            },
            defaults: defaults
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(storedPayload, Data("new-secret".utf8))
        XCTAssertNil(defaults.string(forKey: "apiKey"))

        // Clearing an empty key reports delete failure, and succeeds on errSecSuccess/errSecItemNotFound.
        XCTAssertFalse(
            ServerResolver.saveApiKey(
                "   ",
                deleteItem: { _ in errSecInteractionNotAllowed },
                addItem: { _ in XCTFail("addItem must not run for empty key"); return errSecSuccess },
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ServerResolver.saveApiKey(
                "   ",
                deleteItem: { _ in errSecItemNotFound },
                addItem: { _ in XCTFail("addItem must not run for empty key"); return errSecSuccess },
                defaults: defaults
            )
        )
    }

    // MARK: - Audit Issue #12 (P2): LogLevel ordering without force-unwraps & LogViewer cancellation/filtering

    func testAuditIssue12_LogLevelOrderingAndLogViewerFilteringAndCancellation() async {
        // Verify strict total ordering across all cases via severityRank (no dictionary force-unwraps).
        let expectedOrder: [LogLevel] = [.debug, .info, .warn, .error]
        XCTAssertEqual(LogLevel.allCases.sorted(), expectedOrder)
        for i in expectedOrder.indices {
            XCTAssertFalse(expectedOrder[i] < expectedOrder[i])
            for j in expectedOrder.indices where i < j {
                XCTAssertTrue(expectedOrder[i] < expectedOrder[j])
                XCTAssertFalse(expectedOrder[j] < expectedOrder[i])
            }
        }

        let rawLines = [
            "[DEBUG] [2026-11-24 01:00:00.000] Starting sweep",
            "malformed line without brackets",
            "[WARN] [2026-11-24 01:00:01.000] Slow network response",
            "[ERROR] [2026-11-24 01:00:02.000] Sync failed for stepCount"
        ]
        let parsed = LogViewer.parseLines(rawLines)
        XCTAssertEqual(parsed.count, 3)
        // Reversed newest-first
        XCTAssertEqual(parsed[0].level, .error)
        XCTAssertEqual(parsed[0].timestamp, "2026-11-24 01:00:02.000")
        XCTAssertEqual(parsed[0].message, "Sync failed for stepCount")
        XCTAssertEqual(parsed[2].level, .debug)

        // Filtering respects level toggles and case-insensitive search.
        let errorsOnly = LogViewer.filterEntries(
            parsed,
            searchText: "stepcount",
            showDebug: false,
            showInfo: false,
            showWarn: false,
            showError: true
        )
        XCTAssertEqual(errorsOnly.count, 1)
        XCTAssertEqual(errorsOnly[0].level, .error)

        let noDebug = LogViewer.filterEntries(
            parsed,
            searchText: "",
            showDebug: false,
            showInfo: true,
            showWarn: true,
            showError: true
        )
        XCTAssertEqual(noDebug.count, 2)

        // Cancelled task aborts parseLines cleanly without returning stale results.
        let cancelledTask = Task { () -> [LogEntry] in
            // Wait until cancelled before running parseLines.
            while !Task.isCancelled {
                await Task.yield()
            }
            return LogViewer.parseLines(rawLines)
        }
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.value
        XCTAssertTrue(cancelledResult.isEmpty)
    }

    // MARK: - Audit Issue #15 (P3): Readiness score ring avoids zero-span AngularGradient

    func testAuditIssue15_ReadinessScoreRingNeverUsesZeroSpanAngularGradient() {
        // Score 0 and negative scores have 0 progress and a strictly positive gradient span (>= 1 deg).
        XCTAssertEqual(ReadinessCardView.scoreRingProgress(for: 0), 0.0)
        XCTAssertEqual(ReadinessCardView.scoreRingProgress(for: -15), 0.0)
        XCTAssertGreaterThanOrEqual(ReadinessCardView.scoreRingGradientEndDegrees(for: 0), 1.0)
        XCTAssertGreaterThanOrEqual(ReadinessCardView.scoreRingGradientEndDegrees(for: -15), 1.0)

        // Positive scores map linearly and clamp at 100.
        XCTAssertEqual(ReadinessCardView.scoreRingProgress(for: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ReadinessCardView.scoreRingGradientEndDegrees(for: 50), 180.0, accuracy: 0.0001)
        XCTAssertEqual(ReadinessCardView.scoreRingProgress(for: 100), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ReadinessCardView.scoreRingGradientEndDegrees(for: 100), 360.0, accuracy: 0.0001)
        XCTAssertEqual(ReadinessCardView.scoreRingGradientEndDegrees(for: 140), 360.0, accuracy: 0.0001)

        // Instantiating ReadinessCardView with score == 0 succeeds cleanly.
        let zeroSummary = ReadinessSummary(
            score: 0,
            tier: .recover,
            insight: "Rest today.",
            factors: []
        )
        let card = ReadinessCardView(summary: zeroSummary, isAuthorized: true, isLoading: false)
        XCTAssertEqual(card.summary?.score, 0)
    }
}
