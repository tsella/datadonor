# DataDonor State Machines & Reliability Audit

This document catalogs every explicit and implicit state machine in DataDonor (`client/` iOS app and `server/` Fastify ingest service), their states, invariants, transition tables, and confirmed reachable invalid states/transitions (including under retries, cancellation, and concurrency).

Issues are prioritized by impact and tracked to resolution with regression tests in `client/Tests/StateMachineRegressionTests.swift`.

---

## Summary of State Machines

| ID | Component | Kind | Primary Files |
|---|---|---|---|
| **SM-1** | Sync Execution, Anchor Progression & Reset Lifecycle | Implicit + explicit outcome | `client/Sources/Managers/HealthQueryManager.swift`, `SettingsView.swift` |
| **SM-2** | Background Upload Continuation, Staging Files & Orphan Acknowledgement | Implicit (concurrent, cross-process) | `client/Sources/Managers/SyncEngine.swift`, `OrphanedUploadStore.swift`, `AppDelegate.swift` |
| **SM-3** | Background Wake Orchestration (Observers, BGTasks, Unlock Catch-up) | Implicit (multi-trigger) | `client/Sources/Managers/BackgroundSyncManager.swift` |
| **SM-4** | Bonjour Discovery, Server Approval & TLS Certificate Pinning | Implicit → Explicit (`DiscoveryState`) | `client/Sources/Managers/ServerDiscoveryManager.swift`, `ServerResolver.swift`, `ServerTrustStore.swift` |
| **SM-5** | Sync Failure Streak & Notification Throttle | Implicit (persisted) | `client/Sources/Managers/NotificationManager.swift`, `HealthQueryManager.swift` |
| **SM-6** | QR Camera Permission & Capture Session | Implicit → Explicit (`ScannerState`) | `client/Sources/Views/QRScannerView.swift` |
| **SM-7** | Dashboard Chart Fetch & Cache Refresh | Implicit (async UI) | `client/Sources/Views/DashboardView.swift` |
| **SM-8** | Server Ingest Write Queue, SQLite Transaction & Shutdown | Implicit (serialized async) | `server/app.js`, `server/db.js` |

---

## SM-1: HealthKit Sync Execution, Anchor Progression & Reset Lifecycle

**Files:** `client/Sources/Managers/HealthQueryManager.swift`, `client/Sources/Views/SettingsView.swift`

### State Variables
- `isSyncing: Bool` (`@Published`, `@MainActor`)
- `isCancelled: Bool` (`@MainActor`)
- `totalRecordsSynced: Int` + `UserDefaults["totalRecordsSynced"]`
- `UserDefaults["anchor_<type>"]`: per-type archived `HKQueryAnchor`
- `UserDefaults["nextTypeSweepOffset"]`: rotation cursor for secondary types
- `UserDefaults["lastSyncTimestamp"]` / `UserDefaults["lastFullSweepTimestamp"]`
- `UserDefaults["pendingFullResync"]` *(added in Issue 2 fix)*
- `pendingBatch: PendingMultiTypeBatch` (in-memory accumulator during a run)

### States
- `Idle`: `isSyncing == false`
- `ResetPending`: `isSyncing == false`, local `anchor_*` cleared, `pendingFullResync == true`
- `Reconciling`: `isSyncing == true`, fetching server checkpoints before reading HealthKit
- `ExtractingAndUploading`: `isSyncing == true`, bounded concurrent `HKAnchoredObjectQuery` chunks + multi-type `flushPendingBatch` / `exhaustQuery`
- `Cancelling`: `isSyncing == true && isCancelled == true`
- `Heartbeat`: `isSyncing == true`, `uploadedRecords == 0`, posting local anchors

### Invariants
1. **Single writer:** At most one `performSync` runs at a time (`guard !isSyncing`).
2. **Anchor monotonicity on delivery:** A local `anchor_<type>` advances *only* after the server returns `2xx` for all records up to that anchor (or all samples in that page were unmappable with zero deletions).
3. **No mutation while syncing:** `resetAllAnchors()` must never clear anchors or counters while `isSyncing == true`.
4. **Reset survives reconciliation:** A deliberate user reset (`ResetPending`) must force a full backfill from `anchor = nil` and must *not* be undone by `reconcileAnchorState()` re-seeding old anchors from the server.
5. **UI/storage lockstep:** `totalRecordsSynced` equals `UserDefaults["totalRecordsSynced"]`.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `Idle` | `performSync(...)` | `serverURL != nil && !isSyncing` | `Reconciling` (if `reconcileAnchors`) or `ExtractingAndUploading` | Sets `isSyncing = true`, `isCancelled = false` |
| `Idle` | `resetAllAnchors()` | `!isSyncing` | `ResetPending` | Clears `anchor_*`, `sweepOffset`, `lastSyncTimestamp`, `lastFullSweepTimestamp`, sets `totalRecordsSynced = 0`, sets `pendingFullResync = true` |
| `ResetPending` | `performSync(reconcileAnchors: true)` | `pendingFullResync == true` | `ExtractingAndUploading` | Skips server anchor seeding; starts backfill from `nil` anchors |
| `Reconciling` | Server checkpoints fetched | `!pendingFullResync` | `ExtractingAndUploading` | Seeds only missing local anchors; updates `totalRecordsSynced = max(server, local)` |
| `ExtractingAndUploading` | Batch upload `2xx` | `!isCancelled` | `ExtractingAndUploading` | Persists batch `anchors` + `sweepOffset`; increments `totalRecordsSynced` |
| `ExtractingAndUploading` | Batch upload fails (non-cancel) | — | `ExtractingAndUploading` | Leaves batch anchors untouched; appends types to `failedTypes` |
| `ExtractingAndUploading` | `errorDatabaseInaccessible` | — | `Idle` (`.databaseLocked`) | Stops remaining chunks; leaves un-uploaded anchors untouched |
| `ExtractingAndUploading` | `cancelSync()` or `Task.cancel()` | — | `Cancelling` → `Idle` (`.cancelled`) | Aborts loop and in-flight upload; leaves un-committed anchors untouched |
| `ExtractingAndUploading` | All types done | `failedTypes.isEmpty && !isCancelled` | `Heartbeat` (if no uploads) → `Idle` (`.completed`) | Updates `lastSyncTimestamp`; if `isFullSweep`: updates `lastFullSweepTimestamp`, clears `pendingFullResync` and failure streak |
| `ExtractingAndUploading` | All types done | `!failedTypes.isEmpty` | `Idle` (`.failed`) | Increments failure streak; posts alert on 3rd consecutive failure |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **Invalid State 1A (Reset silently undone by reconciliation — Issue 2, P0):**
  - Evidence: `HealthQueryManager.swift` `resetAllAnchors()` cleared all `anchor_*` keys without setting a reset flag. On the very next manual "Sync Now" (`ContentView.swift:158`, `reconcileAnchors: true`), `reconcileAnchorState()` saw `localAnchorKeys.isEmpty == true`, fetched checkpoints from the server, and seeded every old anchor back into `UserDefaults` — completely cancelling the reset and contradicting the Settings footer and code comment.
- **Invalid State 1B (Concurrent reset mid-sync — Issue 2, P0):**
  - Evidence: `SettingsView.swift:136-141` disabled the "Reset Sync State" button while `isSyncing`, presenting an alert (`isShowingResetConfirmation`). If a background observer or discovery sync began while the alert was on screen, tapping "Reset" called `resetAllAnchors()`, which lacked `guard !isSyncing`, wiping `anchor_*` and `totalRecordsSynced` mid-flight while `performSync` continued writing post-reset anchors and counters.

---

## SM-2: `SyncEngine` Background Upload, Staging Files & `OrphanedUploadStore`

**Files:** `client/Sources/Managers/SyncEngine.swift`, `client/Sources/Managers/OrphanedUploadStore.swift`, `client/Sources/AppDelegate.swift`

### State Variables
- `pendingUploads: [String: CheckedContinuation<Void, Error>]` (guarded by `stateLock`)
- `responseBodies: [String: Data]` (guarded by `stateLock`)
- `payloadFiles: [String: URL]` (guarded by `stateLock`)
- `cancelledAttempts: Set<String>` *(added in Issue 1 fix, guarded by `stateLock`)*
- `orphanStore.map: [String: Double]` + `UserDefaults["acknowledgedOrphanedUploads"]` (guarded by `OrphanedUploadStore.lock`)
- `backgroundCompletionHandler: (() -> Void)?` + `backgroundEventsFinished: Bool` *(added in Issue 3 fix)*

### States (Per Upload Attempt for a Deterministic `batchToken`)
- `NotStarted`
- `Staging`: compressing & writing temp file off main actor
- `AwaitingResponse`: `URLSessionUploadTask` resumed, continuation registered under unique `attemptId`
- `DetachedInFlight`: caller cancelled or process died; `URLSessionUploadTask` continues out-of-process in `nsurlsessiond`
- `AcknowledgedOrphan`: `didCompleteWithError(nil)` with HTTP `2xx` and no waiter; recorded in `OrphanedUploadStore` keyed by `batchToken`
- `Completed`: caller resumed with `()` (or error) and staging file deleted

### Invariants
1. **Exactly-once continuation resume:** Every `CheckedContinuation` is resumed at most once and never leaked/hung on cancellation.
2. **Attempt isolation on retry:** Two overlapping attempts for the same deterministic `batchToken` (e.g., cancelled attempt #1 still in `nsurlsessiond` while retry #2 starts) must have independent staging files, response buffers, and continuations.
3. **File lifetime ownership:** A staging file handed to `session.uploadTask(with:fromFile:)` is deleted *only* when *that specific attempt's* `didCompleteWithError` fires (or stale-file pruning after 24h), never deleted out from under a live upload.
4. **Monotonic persistence order:** `OrphanedUploadStore` writes to `UserDefaults` in the exact order mutations occur under `lock` (no async main-queue snapshot inversion).
5. **Background session completion guarantee:** `handleEventsForBackgroundURLSession`'s completion handler is always invoked once `urlSessionDidFinishEvents` fires, regardless of arrival order.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `NotStarted` | `sync(transport: .immediate)` | `!Task.isCancelled` | `Completed` | Compresses in memory; `ephemeralSession.upload(for:from:)` returns or throws |
| `NotStarted` | `sync(transport: .background)` | `orphanStore.consumeAcknowledgement(batchToken)` | `Completed` | Skips network upload; caller advances anchor |
| `NotStarted` | `sync(transport: .background)` | Not previously acknowledged | `Staging` | Compresses & writes unique temp file off main actor |
| `Staging` | `Task.cancel()` before registration | `cancelledAttempts.contains(attemptId)` or `Task.isCancelled` | `Completed` (throws `CancellationError`) | Deletes temp file; never creates `URLSessionUploadTask` |
| `Staging` | Register under `attemptId` + `task.resume()` | Not cancelled under `stateLock` | `AwaitingResponse` | Stores `task.taskDescription = "\(batchToken)|\(attemptId)"`; records `pendingUploads[attemptId]` & `payloadFiles[attemptId]` |
| `AwaitingResponse` | `onCancel` | — | `DetachedInFlight` | Removes `pendingUploads[attemptId]` and resumes with `CancellationError`; leaves task and `payloadFiles[attemptId]` alive |
| `AwaitingResponse` | `didCompleteWithError(nil)` + `2xx` | — | `Completed` | Removes `pendingUploads[attemptId]`, `payloadFiles[attemptId]`, `responseBodies[attemptId]`; deletes staging file; resumes `()` |
| `AwaitingResponse` | `didCompleteWithError(err)` or non-`2xx` | — | `Completed` (throws) | Cleans up `attemptId` state & staging file; checks `orphanStore.consumeAcknowledgement(batchToken)` in case a prior detached attempt landed `2xx` |
| `DetachedInFlight` | `didCompleteWithError(nil)` + `2xx` | `continuation == nil` | `AcknowledgedOrphan` | Deletes staging file; synchronously persists `orphanStore.recordSuccess(token: batchToken)` |
| `DetachedInFlight` | `didCompleteWithError(err)` or non-`2xx` | `continuation == nil` | `Completed` | Deletes staging file; does *not* record acknowledgement |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **Invalid State 2A (Retry collides with detached in-flight attempt — Issue 1, P0):**
  - Evidence: `SyncEngine.swift:379-387` keyed `pendingUploads`, `responseBodies`, and `payloadFiles` directly by the deterministic `uploadToken`. When attempt #1 was cancelled (`onCancel` left the background task running per design) and retry #2 started for the same un-advanced anchor, retry #2 computed the same `uploadToken`:
    1. `payloadFiles.updateValue(fileURL_2, forKey: uploadToken)` returned `fileURL_1`, and line 386 immediately **deleted `fileURL_1` while attempt #1 was still reading it**.
    2. Both tasks appended chunks into the same `responseBodies[uploadToken]`.
    3. When attempt #1 failed/finished first, `didCompleteWithError` removed `pendingUploads[uploadToken]` (**stealing retry #2's continuation**) and deleted `fileURL_2` out from under retry #2.
- **Invalid State 2B (`Task.isCancelled` vs `onCancel` hang window — Issue 1, P0):**
  - Evidence: `SyncEngine.swift:372-384` checked `if Task.isCancelled` *outside* `stateLock` before `session.uploadTask(...)` and before inserting `pendingUploads[token] = continuation`. Cancellation arriving in that window ran `onCancel` against an empty `pendingUploads` (no-op), after which `continuation` was inserted and hung until timeout because `onCancel` only fires once.
- **Invalid State 2C (Out-of-order `OrphanedUploadStore` persistence — Issue 3, P1):**
  - Evidence: `OrphanedUploadStore.swift:31-39` persisted via `DispatchQueue.main.async` on background threads and synchronously on main. A background `recordSuccess` snapshot queued on main could execute *after* a newer synchronous main-thread `consumeAcknowledgement`, resurrecting consumed entries or clobbering state, or get dropped if the process suspended before the main-queue block ran.
- **Invalid State 2D (`backgroundCompletionHandler` missed or overwritten — Issue 3, P1):**
  - Evidence: `AppDelegate.swift:54` assigned `syncEngine.backgroundCompletionHandler = completionHandler` directly, while `SyncEngine.swift:120-126` read and cleared it on `DispatchQueue.main.async`. If `urlSessionDidFinishEvents` arrived before `AppDelegate` assigned the handler, the handler was never invoked; if assigned twice, the first handler leaked uncalled.

---

## SM-3: `BackgroundSyncManager` Wake Orchestration

**Files:** `client/Sources/Managers/BackgroundSyncManager.swift`

### State Variables
- `activeObserverQueries: [HKObserverQuery]` (empty = unregistered, non-empty = active)
- `isDrainingObservers: Bool`
- `pendingObservedTypes: Set<HKSampleType>`
- `pendingObserverCompletions: [OneShotCompletion]`
- `inFlightObserverCompletions: [OneShotCompletion]`
- `observerDrainTask: Task<Void, Never>?`
- `unlockSyncTask: Task<Void, Never>?`
- `hasPendingDeferredSync: Bool` (`UserDefaults["pendingDeferredBackgroundSync"]`)
- `latestPathBox: LockedBox<NWPath?>`

### States
- `Uninitialized` → `Configured` → `Observing`
- Observer sub-machine: `ObserverIdle` ↔ `ObserverDraining` → `ObserverExpiring` → `ObserverIdle`
- Unlock sub-machine: `UnlockIdle` ↔ `UnlockCatchUpRunning`
- BGTask sub-machine: `Scheduled` → `Running` → (`Completed` | `Expired`)

### Invariants
1. **Synchronous observer registration:** `activeObserverQueries` is populated synchronously before `didFinishLaunchingWithOptions` returns whenever authorized.
2. **Guaranteed completion delivery:** Every `HKObserverQueryCompletionHandler` is called *exactly once*, including on lock-screen deferral, coalescing, and `beginBackgroundTask` expiration.
3. **No silent loss of HealthKit updates:** If an observer wake cannot be synced right now (device locked, server unreachable, another sync already in progress, or expiration during drain), `hasPendingDeferredSync` must become `true` so the next unlocked wake runs a catch-up full sweep.
4. **Full-sweep failure recovery:** Any full sweep (`BGAppRefreshTask`, `BGProcessingTask`, unlock catch-up) that finishes `.deferred`, `.cancelled`, `.failed`, or `.skipped` sets `hasPendingDeferredSync = true`; only a `.completed` full sweep clears it.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `ObserverIdle` | `HKObserverQuery` fires | `!isProtectedDataAvailable` | `ObserverIdle` | Sets `hasPendingDeferredSync = true`; fires `completion` immediately |
| `ObserverIdle` | `HKObserverQuery` fires | `healthQueryManager.isSyncing` | `ObserverIdle` | Sets `hasPendingDeferredSync = true`; fires `completion` (deferred full sweep catches up) |
| `ObserverIdle` | `HKObserverQuery` fires | Unlocked & `!isSyncing` | `ObserverDraining` | Begins `BackgroundTaskToken`, resolves reachable URL, drains `pendingObservedTypes`, fires batch completions, runs opportunistic full sweep if stale/deferred |
| `ObserverDraining` | Another `HKObserverQuery` fires | `!isExpiring` | `ObserverDraining` | Unions `types` into `pendingObservedTypes`; queues `completion` |
| `ObserverDraining` | `BackgroundTaskToken` expires | — | `ObserverExpiring` → `ObserverIdle` | Sets `hasPendingDeferredSync = true`, cancels drain task & sync, flushes all in-flight and pending completions, ends background task |
| `UnlockIdle` | `protectedDataDidBecomeAvailable` | `(hasPendingDeferredSync \|\| stale) && !isSyncing && !isDrainingObservers` | `UnlockCatchUpRunning` → `UnlockIdle` | Runs full sweep under `BackgroundTaskToken`; clears `hasPendingDeferredSync` on `.completed` |
| `BGTask Running` | `runBackgroundSync` returns `.completed` | — | `Completed(true)` | Clears `hasPendingDeferredSync = false` |
| `BGTask Running` | `runBackgroundSync` returns `.deferred` | — | `Completed(true)` | Ensures `hasPendingDeferredSync = true` (keeps DAS healthy) |
| `BGTask Running` | `runBackgroundSync` returns `.failed`/`.cancelled` | — | `Completed(false)` | Sets `hasPendingDeferredSync = true` |
| `BGTask Running` | `task.expirationHandler` | — | `Expired` (`Completed(false)`) | Sets `hasPendingDeferredSync = true`, cancels task & sync, invokes one-shot `setTaskCompleted(false)` immediately |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **Invalid State 3A (Observer updates silently dropped during active sync — Issue 4, P1):**
  - Evidence: `BackgroundSyncManager.swift:422-433` checked `guard !healthQueryManager.isSyncing`, flushed completions, and discarded `pendingObservedTypes` *without* setting `hasPendingDeferredSync = true`. If an active full sweep had already passed `stepCount` or `workout` when new samples arrived, those updates were dropped without scheduling catch-up.
- **Invalid State 3B (Observer wake arriving during expiration teardown dropped — Issue 4, P1):**
  - Evidence: `BackgroundSyncManager.swift:435-454` cancelled `observerDrainTask` on `BackgroundTaskToken` expiry while `isDrainingObservers` remained `true` until the async task exited. A new observer wake arriving in that window saw `isDrainingObservers == true`, appended to `pendingObservedTypes`, and then `defer` discarded `pendingObservedTypes` without setting `hasPendingDeferredSync = true`.
- **Invalid State 3C (Failed/cancelled/skipped BGTask fails to set `hasPendingDeferredSync` — Issue 4, P1):**
  - Evidence: `BackgroundSyncManager.swift:222-235` only set `hasPendingDeferredSync` inside `runBackgroundSync` for lock/offline/unreachable paths, not when a `BGAppRefreshTask`/`BGProcessingTask` failed, expired, or was skipped due to a single-type observer sync already running.

---

## SM-4: Server Discovery, Approval & TLS Pinning

**Files:** `client/Sources/Managers/ServerDiscoveryManager.swift`, `ServerResolver.swift`, `ServerTrustStore.swift`, `SettingsView.swift`

### State Variables
- `DiscoveryState`: `.idle`, `.searching`, `.stopping`, `.restarting` *(explicit enum added in Issue 5 fix)*
- `activeServerURL: URL?` (`@Published`)
- `pendingApprovalURL: URL?` (`@Published`)
- `UserDefaults["approvedServers"]`, `UserDefaults["lastActiveServerURL"]`, `UserDefaults["cachedServerHostIPs"]`
- `ServerTrustStore.cachedPins: [String: String]` + `UserDefaults["pinnedServerKeys"]`

### Invariants
1. **No unapproved traffic:** `activeServerURL` is only ever set to an explicitly approved URL.
2. **Clean `NetServiceBrowser` stop/start sequencing:** `searchForServices` is never called while a prior `stop()` is still awaiting `netServiceBrowserDidStopSearch`.
3. **No post-stop publications:** Resolved services arriving after `stopDiscovery()` must not mutate `activeServerURL` or `pendingApprovalURL` while backgrounded.
4. **No TOFU over cached IP:** Connecting via a cached fallback IP requires an already-established public key pin for the approved logical hostname.
5. **Ordered pin persistence:** `ServerTrustStore` persists pins synchronously under `lock` so `forget(host:)` can never be overwritten by an earlier queued background snapshot.

### Transition Table (`DiscoveryState`)

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `idle` | `startDiscovery()` | — | `searching` | Calls `browser.searchForServices(...)` |
| `searching` | `stopDiscovery()` | — | `stopping` | Clears `resolvingServices`; calls `browser.stop()` |
| `stopping` | `startDiscovery()` | — | `restarting` | Waits for `netServiceBrowserDidStopSearch` (does not call `searchForServices` early) |
| `restarting` | `stopDiscovery()` | — | `stopping` | Cancels pending restart |
| `stopping` | `netServiceBrowserDidStopSearch` | — | `idle` | — |
| `restarting` | `netServiceBrowserDidStopSearch` | — | `searching` | Immediately calls `browser.searchForServices(...)` |
| `searching` | `netServiceBrowser(_:didNotSearch:)` | — | `idle` | Logs error |
| `searching` | `netServiceDidResolveAddress` | `state == .searching` | `searching` | Caches IP; sets `activeServerURL` if approved else `pendingApprovalURL` |
| `idle`/`stopping`/`restarting` | `netServiceDidResolveAddress` | `state != .searching` | *(unchanged)* | Drops stale resolution; does not publish |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **Invalid State 4A (Stop → Start race stalls Bonjour discovery — Issue 5, P2):**
  - Evidence: `ServerDiscoveryManager.swift:23-47` used a single `isSearching: Bool`. Rapid background (`stopDiscovery()` → `isSearching = false`, `browser.stop()`) followed immediately by foreground (`startDiscovery()` → `isSearching = true`, `browser.searchForServices(...)`) before `netServiceBrowserDidStopSearch` fired caused either `NSNetServicesActivityInProgress` (`didNotSearch`) or the stale `didStopSearch` callback to reset `isSearching = false`, leaving discovery broken.
- **Invalid State 4B (Post-stop async publish triggers foreground sync in background — Issue 5, P2):**
  - Evidence: `ServerDiscoveryManager.swift:93-108` wrapped publication in `DispatchQueue.main.async` inside `@MainActor netServiceDidResolveAddress` without checking whether discovery was still active, allowing a resolution queued just before backgrounding to mutate `activeServerURL` after `stopDiscovery()`.
- **Invalid State 4C (Out-of-order `ServerTrustStore` pin persistence — Issue 3, P1):**
  - Evidence: `ServerTrustStore.swift:32-40` dispatched background-thread `store(pin:for:)` writes via `DispatchQueue.main.async` while main-thread `forget(host:)` wrote synchronously, allowing an older background snapshot to resurrect a deleted TLS pin.

---

## SM-5: Failure Streak & Alert Throttle

**Files:** `client/Sources/Managers/NotificationManager.swift`, `client/Sources/Managers/HealthQueryManager.swift`

### State Variables
- `UserDefaults["consecutiveSyncFailures"]` (`Int`, `0..∞`)
- `UserDefaults["lastSyncFailureAlert"]` (`Date?`)
- `lastReportedFailure: [String: Date]` (in-memory log throttle, 1 hour per type)

### Invariants
1. **Streak accuracy:** `consecutiveSyncFailures` increments on failing runs, triggers at `>= 3` (at most once per `alertInterval = 3600s`), and resets *only* when a **full sweep** succeeds cleanly (not when a single-type observer subset succeeds while another type keeps failing).

### Confirmed Reachable Invalid State (Pre-Fix Evidence)
- **Invalid State 5A (Partial observer wake resets full-sweep failure streak — Issue 6, P2):**
  - Evidence: `HealthQueryManager.swift:807` called `NotificationManager.shared.recordSyncOutcome(failedTypeCount: 0)` whenever `failedTypes.isEmpty`, even when `types != nil` (e.g., a 1-type `stepCount` observer wake). A persistent failure in any non-observed type could never reach 3 consecutive failures because any intervening `stepCount` observer wake reset `consecutiveSyncFailures` to `0`.

---

## SM-6: QR Camera Scanner Lifecycle

**Files:** `client/Sources/Views/QRScannerView.swift`

### State Variables
- `ScannerState`: `.checkingPermission`, `.ready`, `.running`, `.scanned`, `.unavailable` *(added in Issue 7 fix)*
- `isViewVisible: Bool` *(added in Issue 7 fix)*
- `sessionQueue`: dedicated serial `DispatchQueue` *(added in Issue 7 fix)*

### Invariants
1. **Serialized `AVCaptureSession` control:** All `configure`, `startRunning`, and `stopRunning` calls execute on one serial queue.
2. **Single scan emission:** `onResult` and vibration fire *at most once* per presentation.
3. **No background capture after dismissal:** An async camera permission grant arriving after `viewWillDisappear` does not start the camera session.

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **Invalid State 6A (Concurrent `startRunning`/`stopRunning` on global queue — Issue 7, P2):**
  - Evidence: `QRScannerView.swift:116-128` dispatched both `startRunning()` and `stopRunning()` to `DispatchQueue.global(qos: .userInitiated)` (concurrent!), and `configureSession()` + `viewWillAppear` could both see `!session.isRunning` and enqueue overlapping starts/stops.
- **Invalid State 6B (Duplicate `onResult` & vibration across frames — Issue 7, P2):**
  - Evidence: `QRScannerView.swift:145-158` called async `stopSession()` with no `hasScanned` / `.scanned` state guard, letting consecutive 30–60fps frames fire `onResult` and vibrate multiple times before capture stopped.
- **Invalid State 6C (Permission grant starts capture after sheet dismissed — Issue 7, P2):**
  - Evidence: `QRScannerView.swift:52-60` called `configureSession()` → `startSession()` in the async `requestAccess` callback without checking whether the view was still visible.

---

## SM-7: Dashboard Chart Fetch Lifecycle

**Files:** `client/Sources/Views/DashboardView.swift`

### State Variables
- `syncData: [SyncDataPoint]`
- `fetchTask: Task<Void, Never>?`
- `fetchGeneration: Int` *(added in Issue 8 fix)*
- `lastRefreshCount: Int`

### Invariants
1. **Single active fetch + monotonic application:** All refreshes go through `refreshData()`, cancelling any prior `fetchTask`, and only the latest `fetchGeneration` can overwrite `syncData` and the `UserDefaults` chart cache.

### Confirmed Reachable Invalid State (Pre-Fix Evidence)
- **Invalid State 7A (Concurrent `.task` vs `refreshData()` stale overwrite — Issue 8, P3):**
  - Evidence: `DashboardView.swift:138-141` called `await fetchDashboardStats()` directly inside `.task`, bypassing `fetchTask`. When `activeServerURL` or `isSyncing` triggered `refreshData()` concurrently, both requests ran in parallel and a slower earlier response could overwrite newer stats and cache.

---

## SM-8: Server Ingest Write Queue, SQLite Transaction & Shutdown

**Files:** `server/app.js`, `server/db.js`

### State Variables
- `dbPromise`: singleton DB init/migration promise
- `dbQueue: Promise` + `queueDepth: Number` (`0..MAX_QUEUE_DEPTH(64)`)
- `inTransaction: Boolean` (per `ingestPayload` call)
- `knownDevices: Set<String>`
- `shuttingDown: Boolean`

### Invariants
1. **DB ready before HTTP:** `start()` awaits `getDb()` before `fastify.listen(...)`.
2. **Serialized transactions with bounded backpressure:** `enqueueWrite` rejects with HTTP `503` when `queueDepth >= 64`; `dbQueue` never stays rejected across tasks (`result.then(() => {}, () => {})`).
3. **Rollback safety:** `knownDevices.add(device_id)` runs only *after* `COMMIT`; any error while `inTransaction` runs `ROLLBACK`.
4. **Idempotent stats:** `daily_sync_stats` increments only on `ON CONFLICT(uuid) DO NOTHING RETURNING` rows and decrements only on `DELETE ... RETURNING` rows.
5. **Graceful shutdown:** `shuttingDown` prevents re-entry; unpublishes Bonjour, closes Fastify, drains `dbQueue`, then closes SQLite.

*Audit result: No reachable invalid state transitions found in SM-8; existing server tests (`server/test/ingest.test.js`, `auth.test.js`, `gzip.test.js`) cover idempotency, rollback/validation, and deletion stats.*

---

## Prioritized Issues & Resolution Tracker

All 8 confirmed issues are fixed and verified by `DataDonorTests` (`client/Tests/StateMachineRegressionTests.swift`, 19/19 passing on iOS Simulator) and `server/test/` (22/22 passing).

| Issue | Priority | State Machine(s) | Fix Summary | Status | Regression Test(s) |
|---|---|---|---|---|---|
| **Issue 1** | **P0 (Critical)** | SM-2 (`SyncEngine`) | Keyed `pendingUploads`, `responseBodies`, and `payloadFiles` by per-attempt `attemptId` (`UploadTaskIdentity` `"<batchToken>\|<attemptId>"`, preserving legacy parsing) while recording orphan 2xx acks under `batchToken`; added `cancelledAttempts` under `stateLock` so pre-registration cancellation aborts atomically without hanging. | **Fixed** | `testIssue1_UploadTaskIdentityParsesCurrentAndLegacyFormats`, `testIssue1_RetryDoesNotDeleteInFlightAttemptFileOrStealContinuation`, `testIssue1_DetachedAttempt2xxRecordedUnderBatchToken`, `testIssue1_CancelBeforeRegistrationAbortsWithoutHanging` |
| **Issue 2** | **P0 (Critical)** | SM-1 (`HealthQueryManager`) | Persisted `pendingFullResync` in `resetAllAnchors()` so `reconcileAnchorState()` / `applyServerCheckpoints()` skips seeding server anchors until a full sweep finishes cleanly; added `guard !isSyncing` to `resetAllAnchors()` to prevent mid-sync half-resets; separated internal `clearLocalSyncState()` for fresh-start reconciliation. | **Fixed** | `testIssue2_ResetAllAnchorsSurvivesServerCheckpointReconciliation`, `testIssue2_FreshInstallWithoutResetStillSeedsServerCheckpoints`, `testIssue2_ResetAllAnchorsRefusesToMutateWhileSyncing` |
| **Issue 3** | **P1 (High)** | SM-2, SM-4 (`OrphanedUploadStore`, `ServerTrustStore`, `SyncEngine`, `AppDelegate`) | Persisted `OrphanedUploadStore` and `ServerTrustStore` synchronously under their locks (eliminating `DispatchQueue.main.async` snapshot inversions); replaced raw `backgroundCompletionHandler` with `setBackgroundCompletionHandler(_:)` + `pendingBackgroundEventsFinished` so both arrival orders and handler replacements invoke every system completion handler. | **Fixed** | `testIssue3_OrphanedUploadStoreConcurrentRecordAndConsumeNeverResurrectsTokens`, `testIssue3_ServerTrustStoreForgetPersistsSynchronouslyWithoutAsyncClobber`, `testIssue3_BackgroundCompletionHandlerInvokedRegardlessOfOrder` |
| **Issue 4** | **P1 (High)** | SM-3 (`BackgroundSyncManager`) | Set `hasPendingDeferredSync = true` when observer wakes coalesce into an active sync, arrive during `isObserverDrainExpiring` teardown, or when a `BGTask` full sweep finishes `.deferred`, `.failed`, `.cancelled`, or expires. | **Fixed** | `testIssue4_ObserverWakeDuringActiveSyncSetsPendingDeferredAndFiresCompletion`, `testIssue4_ObserverWakeDuringExpirationTeardownSetsPendingDeferredAndFiresImmediately`, `testIssue4_BGTaskOutcomesTrackPendingDeferredSyncAndDASStatus` |
| **Issue 5** | **P2 (Medium)** | SM-4 (`ServerDiscoveryManager`) | Replaced `isSearching: Bool` with explicit `DiscoveryState` (`.idle`, `.searching`, `.stopping`, `.restarting`) so `stop -> start` queues cleanly until `netServiceBrowserDidStopSearch`; cancelled in-flight `NetService` resolves on stop and dropped late resolutions outside `.searching`. | **Fixed** | `testIssue5_StopThenStartWaitsForDidStopSearchBeforeRestarting`, `testIssue5_LateResolutionAfterStopDoesNotPublishServer` |
| **Issue 6** | **P2 (Medium)** | SM-5 (`NotificationManager`, `HealthQueryManager`) | Restricted clearing `consecutiveSyncFailures` to clean full sweeps (`isFullSweep == true`) so partial observer wakes cannot mask persistent failures in other sample types; added injectable `UserDefaults` + clock on `NotificationManager`. | **Fixed** | `testIssue6_PartialObserverSuccessDoesNotResetFullSweepFailureStreak` |
| **Issue 7** | **P2 (Medium)** | SM-6 (`QRScannerView`) | Serialized all `AVCaptureSession` start/stop transitions onto a dedicated serial `sessionQueue`, added explicit `ScannerState` with single-emission `handleScannedCode` guard, and gated capture startup on `isViewVisible`. | **Fixed** | `testIssue7_ScannerEmitsScannedCodeAtMostOnce` |
| **Issue 8** | **P3 (Low)** | SM-7 (`DashboardView`) | Routed `.task` through `refreshData()`, cancelled `fetchTask` in `.onDisappear`, and guarded chart/cache application with monotonic `FetchGenerationGuard`. | **Fixed** | `testIssue8_FetchGenerationGuardRejectsSupersededRequests` |

### Running Verification

```bash
# iOS regression tests (XCTest)
xcodebuild test -project client/DataDonor.xcodeproj -scheme DataDonor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

# Server tests
cd server && npm test
```
