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
}
