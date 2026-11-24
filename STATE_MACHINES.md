# DataDonor State Machines & Reliability Audit

This document catalogs every explicit and implicit state machine in DataDonor (`client/` iOS app and `server/` Fastify ingest service), their states, invariants, transition tables, and confirmed reachable invalid states/transitions (including under retries, cancellation, clock skew, and concurrency).

Issues are prioritized by impact and tracked to resolution with regression tests in `client/Tests/StateMachineRegressionTests.swift` and `server/test/`.

---

## Summary of State Machines

| ID | Component | Kind | Primary Files |
|---|---|---|---|
| **SM-1** | Sync Execution, Anchor Progression & Reset Lifecycle | Implicit + explicit outcome | `client/Sources/Managers/HealthQueryManager.swift`, `SettingsView.swift` |
| **SM-2** | Background Upload Continuation, Staging Files & Orphan Acknowledgement | Implicit (concurrent, cross-process) | `client/Sources/Managers/SyncEngine.swift`, `OrphanedUploadStore.swift`, `AppDelegate.swift` |
| **SM-3** | Background Wake Orchestration (Observers, BGTasks, Unlock Catch-up) | Implicit (multi-trigger) | `client/Sources/Managers/BackgroundSyncManager.swift` |
| **SM-4** | Bonjour Discovery, Server Approval & TLS Certificate Pinning | Explicit (`DiscoveryState`) | `client/Sources/Managers/ServerDiscoveryManager.swift`, `ServerResolver.swift`, `ServerTrustStore.swift` |
| **SM-5** | Sync Failure Streak & Notification Throttle | Implicit (persisted) | `client/Sources/Managers/NotificationManager.swift`, `HealthQueryManager.swift` |
| **SM-6** | QR Camera Permission & Capture Session | Explicit (`ScannerState`) | `client/Sources/Views/QRScannerView.swift` |
| **SM-7** | Dashboard Sync History Fetch, Archive Reconstruction & Cache Refresh | Implicit (async UI) | `client/Sources/Views/DashboardView.swift`, `SyncEngine.swift` |
| **SM-8** | Server Ingest Write Queue, SQLite Transaction, Stats Scope & Shutdown | Implicit (serialized async) | `server/app.js`, `server/db.js` |
| **SM-9** | Live Server Connection Status, Auth Probe & Sync Button Gating | Explicit (`ServerConnectionStatus`, `PingResult`) | `client/Sources/ContentView.swift`, `SyncEngine.swift`, `SettingsView.swift`, `BackgroundSyncManager.swift` |
| **SM-10** | On-Device Vitals Pipeline & Encrypted Snapshot Cache | Implicit (concurrent HealthKit + serialized cache) | `client/Sources/Managers/HealthVitalsStore.swift` |
| **SM-11** | Biometric Launch Splash Choreography & Dismissal | Explicit (`SplashPhase`) | `client/Sources/Views/SplashScreenView.swift`, `ContentView.swift` |
| **SM-12** | Chart Scrub Gesture & Card Collapse/Selection State | Implicit (`@GestureState` + `@AppStorage`) | `client/Sources/Theme/AppTheme.swift`, vitals card views |

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
- `UserDefaults["pendingFullResync"]` *(Issue 2)*
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
2. **Credential precondition:** `performSync` skips immediately (`.skipped`) when `serverURL == nil` or `apiKey` is empty/whitespace.
3. **Anchor monotonicity on delivery:** A local `anchor_<type>` advances *only* after the server returns `2xx` for all records up to that anchor (or all samples in that page were unmappable with zero deletions).
4. **No mutation while syncing:** `resetAllAnchors()` must never clear anchors or counters while `isSyncing == true`.
5. **Reset survives reconciliation:** A deliberate user reset (`ResetPending`) forces a full backfill from `anchor = nil` and is *not* undone by `reconcileAnchorState()` re-seeding old anchors from the server.
6. **UI/storage lockstep:** `totalRecordsSynced` equals `UserDefaults["totalRecordsSynced"]`.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `Idle` | `performSync(...)` | `serverURL == nil \|\| apiKey.trimmed.isEmpty \|\| isSyncing` | `Idle` (`.skipped`) | Logs skip; does not read HealthKit or upload |
| `Idle` | `performSync(...)` | `serverURL != nil && !apiKey.trimmed.isEmpty && !isSyncing` | `Reconciling` (if `reconcileAnchors`) or `ExtractingAndUploading` | Sets `isSyncing = true`, `isCancelled = false` |
| `Idle` | `resetAllAnchors()` | `!isSyncing` | `ResetPending` | Clears `anchor_*`, `sweepOffset`, `lastSyncTimestamp`, `lastFullSweepTimestamp`, sets `totalRecordsSynced = 0`, `pendingFullResync = true` |
| `ResetPending` | `performSync(reconcileAnchors: true)` | `pendingFullResync == true` | `ExtractingAndUploading` | Skips server anchor seeding; starts backfill from `nil` anchors |
| `Reconciling` | Server checkpoints fetched | `!pendingFullResync` | `ExtractingAndUploading` | Seeds only missing local anchors; updates `totalRecordsSynced = max(server, local)` |
| `ExtractingAndUploading` | Batch upload `2xx` | `!isCancelled` | `ExtractingAndUploading` | Persists batch `anchors` + `sweepOffset`; increments `totalRecordsSynced` |
| `ExtractingAndUploading` | Batch upload fails (non-cancel) | — | `ExtractingAndUploading` | Leaves batch anchors untouched; appends types to `failedTypes` |
| `ExtractingAndUploading` | `errorDatabaseInaccessible` | — | `Idle` (`.databaseLocked`) | Stops remaining chunks; leaves un-uploaded anchors untouched |
| `ExtractingAndUploading` | `cancelSync()` or `Task.cancel()` | — | `Cancelling` → `Idle` (`.cancelled`) | Aborts loop and in-flight upload; leaves un-committed anchors untouched |
| `ExtractingAndUploading` | All types done | `failedTypes.isEmpty && !isCancelled` | `Heartbeat` (if no uploads) → `Idle` (`.completed`) | Updates `lastSyncTimestamp`; if `isFullSweep`: updates `lastFullSweepTimestamp`, clears `pendingFullResync` and failure streak |
| `ExtractingAndUploading` | All types done | `!failedTypes.isEmpty` | `Idle` (`.failed`) | Increments failure streak; posts alert on 3rd consecutive failure |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **1A (Reset silently undone by reconciliation — Issue 2, P0):** `resetAllAnchors()` cleared `anchor_*` without persisting a reset flag; the next manual Sync Now saw `localAnchorKeys.isEmpty` and re-seeded all old server anchors.
- **1B (Concurrent reset mid-sync — Issue 2, P0):** `resetAllAnchors()` lacked `guard !isSyncing`, allowing an alert confirmation to wipe anchors mid-flight if a background sync started while the confirmation sheet was open.

---

## SM-2: `SyncEngine` Background Upload, Staging Files & `OrphanedUploadStore`

**Files:** `client/Sources/Managers/SyncEngine.swift`, `client/Sources/Managers/OrphanedUploadStore.swift`, `client/Sources/AppDelegate.swift`

### State Variables
- `pendingUploads: [String: CheckedContinuation<Void, Error>]` (guarded by `stateLock`)
- `responseBodies: [String: Data]` (guarded by `stateLock`)
- `payloadFiles: [String: URL]` (guarded by `stateLock`)
- `cancelledAttempts: Set<String>` *(Issue 1, guarded by `stateLock`)*
- `orphanStore.map: [String: Double]` + `UserDefaults["acknowledgedOrphanedUploads"]` (guarded by `OrphanedUploadStore.lock`)
- `backgroundCompletionHandler: (() -> Void)?` + `pendingBackgroundEventsFinished: Bool` *(Issue 3)*

### States (Per Upload Attempt for a Deterministic `batchToken`)
- `NotStarted` → `Staging` → `AwaitingResponse` → (`DetachedInFlight` → `AcknowledgedOrphan` | `Completed`)

### Invariants
1. **Exactly-once continuation resume:** Every `CheckedContinuation` is resumed at most once and never leaked/hung on cancellation.
2. **Attempt isolation on retry:** Overlapping attempts for the same deterministic `batchToken` use unique `attemptId` keys (`"<batchToken>|<attemptId>"`) with isolated staging files, response buffers, and continuations.
3. **File lifetime ownership:** A staging file handed to `session.uploadTask(with:fromFile:)` is deleted *only* when *that specific attempt's* `didCompleteWithError` fires (or stale-file pruning after 24h).
4. **Monotonic persistence order:** `OrphanedUploadStore` writes to `UserDefaults` synchronously under `lock`.
5. **Background session completion guarantee:** `handleEventsForBackgroundURLSession`'s completion handler is always invoked once `urlSessionDidFinishEvents` fires, regardless of arrival order.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `NotStarted` | `sync(transport: .immediate)` | `!Task.isCancelled` | `Completed` | Compresses in memory; `ephemeralSession.upload(for:from:)` returns or throws |
| `NotStarted` | `sync(transport: .background)` | `orphanStore.consumeAcknowledgement(batchToken)` | `Completed` | Skips network upload; caller advances anchor |
| `NotStarted` | `sync(transport: .background)` | Not previously acknowledged | `Staging` | Compresses & writes unique temp file off main actor |
| `Staging` | `Task.cancel()` before registration | `cancelledAttempts.contains(attemptId)` or `Task.isCancelled` | `Completed` (throws `CancellationError`) | Deletes temp file; never creates `URLSessionUploadTask` |
| `Staging` | Register under `attemptId` + `task.resume()` | Not cancelled under `stateLock` | `AwaitingResponse` | Stores `task.taskDescription = "\(batchToken)\|\(attemptId)"`; records `pendingUploads[attemptId]` & `payloadFiles[attemptId]` |
| `AwaitingResponse` | `onCancel` | — | `DetachedInFlight` | Removes `pendingUploads[attemptId]` and resumes with `CancellationError`; leaves task and `payloadFiles[attemptId]` alive |
| `AwaitingResponse` | `didCompleteWithError(nil)` + `2xx` | — | `Completed` | Cleans up `attemptId` state & staging file; resumes `()` |
| `AwaitingResponse` | `didCompleteWithError(err)` or non-`2xx` | — | `Completed` (throws) | Cleans up `attemptId` state & staging file; checks `orphanStore.consumeAcknowledgement(batchToken)` |
| `DetachedInFlight` | `didCompleteWithError(nil)` + `2xx` | `continuation == nil` | `AcknowledgedOrphan` | Deletes staging file; synchronously persists `orphanStore.recordSuccess(token: batchToken)` |
| `DetachedInFlight` | `didCompleteWithError(err)` or non-`2xx` | `continuation == nil` | `Completed` | Deletes staging file; does *not* record acknowledgement |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **2A (Retry collides with detached in-flight attempt — Issue 1, P0):** Keying maps by `batchToken` let retry #2 delete attempt #1's staging file and let attempt #1 steal retry #2's continuation.
- **2B (`Task.isCancelled` vs `onCancel` hang window — Issue 1, P0):** Pre-lock cancellation check left continuations permanently suspended when cancellation hit between check and registration.
- **2C (Out-of-order `OrphanedUploadStore` persistence — Issue 3, P1):** Mixed async/sync `UserDefaults` writes allowed stale background snapshots to resurrect consumed tokens.
- **2D (`backgroundCompletionHandler` missed or overwritten — Issue 3, P1):** Direct property assignment dropped or leaked system background completion handlers depending on arrival order.

---

## SM-3: `BackgroundSyncManager` Wake Orchestration

**Files:** `client/Sources/Managers/BackgroundSyncManager.swift`

### State Variables
- `activeObserverQueries: [HKObserverQuery]`
- `isDrainingObservers: Bool`, `isObserverDrainExpiring: Bool`
- `pendingObservedTypes: Set<HKSampleType>`
- `pendingObserverCompletions: [OneShotCompletion]`, `inFlightObserverCompletions: [OneShotCompletion]`
- `observerDrainTask: Task<Void, Never>?`, `unlockSyncTask: Task<Void, Never>?`
- `hasPendingDeferredSync: Bool` (`UserDefaults["pendingDeferredBackgroundSync"]`)
- `latestPathBox: LockedBox<NWPath?>`

### States
- Lifecycle: `Uninitialized` → `Configured` → `Observing`
- Observer sub-machine: `ObserverIdle` ↔ `ObserverDraining` → `ObserverExpiring` → `ObserverIdle`
- Unlock sub-machine: `UnlockIdle` ↔ `UnlockCatchUpRunning`
- BGTask sub-machine: `Scheduled` → `Running` → (`Completed` | `Expired`)

### Invariants
1. **Synchronous observer registration:** `activeObserverQueries` is populated synchronously inside `didFinishLaunchingWithOptions` whenever authorized.
2. **Guaranteed completion delivery:** Every `HKObserverQueryCompletionHandler` fires *exactly once*, including on lock-screen deferral, coalescing, and expiration.
3. **No silent loss of updates:** Any deferred, cancelled, expired, or busy wake sets `hasPendingDeferredSync = true`.
4. **Fail-fast auth preflight:** `resolveReachableServerURL` stops immediately on `.unauthorized` (`401`/`403`) without retrying cached LAN IPs.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `ObserverIdle` | `HKObserverQuery` fires | `!isProtectedDataAvailable \|\| healthQueryManager.isSyncing` | `ObserverIdle` | Sets `hasPendingDeferredSync = true`; fires `completion` immediately |
| `ObserverIdle` | `HKObserverQuery` fires | Unlocked & `!isSyncing` | `ObserverDraining` | Begins `BackgroundTaskToken`, resolves reachable URL, drains `pendingObservedTypes`, runs opportunistic full sweep if stale/deferred |
| `ObserverDraining` | Another `HKObserverQuery` fires | `!isObserverDrainExpiring` | `ObserverDraining` | Unions `types` into `pendingObservedTypes`; queues `completion` |
| `ObserverDraining` | Another `HKObserverQuery` fires | `isObserverDrainExpiring` | `ObserverExpiring` | Sets `hasPendingDeferredSync = true`; fires `completion` immediately |
| `ObserverDraining` | `BackgroundTaskToken` expires | — | `ObserverExpiring` → `ObserverIdle` | Sets `hasPendingDeferredSync = true`, cancels drain & sync, flushes all completions, ends background task |
| `UnlockIdle` | `protectedDataDidBecomeAvailable` | `(hasPendingDeferredSync \|\| stale) && !isSyncing && !isDrainingObservers` | `UnlockCatchUpRunning` → `UnlockIdle` | Runs full sweep under `BackgroundTaskToken`; clears `hasPendingDeferredSync` on `.completed` |
| `BGTask Running` | `runBackgroundSync` finishes | `.completed` / `.deferred` / `.failed` / `.cancelled` | `Completed(true\|false)` | Clears `hasPendingDeferredSync` only on `.completed`; sets it on all other outcomes |
| `BGTask Running` | `task.expirationHandler` | — | `Expired` (`Completed(false)`) | Sets `hasPendingDeferredSync = true`, cancels task & sync, fires one-shot completion |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **3A/3B/3C (Dropped observer updates & missing deferred flags — Issue 4, P1):** Coalescing into an active sync, arriving during expiration teardown, or exiting a `BGTask` via `.failed`/`.cancelled`/`.deferred` failed to set `hasPendingDeferredSync = true`.
- **3D (Cached-IP retry on rejected API key — Issue 10D, P1):** `BackgroundSyncManager.swift:315-336` used `ping -> Bool`, so HTTP `401/403` triggered a wasted second ping to the cached IP and logged `"server unreachable"` instead of `"server rejected API key"`.

---

## SM-4: Server Discovery, Approval & TLS Pinning

**Files:** `client/Sources/Managers/ServerDiscoveryManager.swift`, `ServerResolver.swift`, `ServerTrustStore.swift`, `SettingsView.swift`

### State Variables
- `DiscoveryState`: `.idle`, `.searching`, `.stopping`, `.restarting` *(Issue 5)*
- `activeServerURL: URL?`, `pendingApprovalURL: URL?` (`@Published`)
- `UserDefaults["approvedServers"]`, `UserDefaults["lastActiveServerURL"]`, `UserDefaults["cachedServerHostIPs"]`
- `ServerTrustStore.cachedPins: [String: String]` + `UserDefaults["pinnedServerKeys"]`

### Invariants
1. **No unapproved traffic:** `activeServerURL` is only set to explicitly approved URLs.
2. **Clean `NetServiceBrowser` stop/start sequencing:** `searchForServices` waits for `netServiceBrowserDidStopSearch` when stopping.
3. **No post-stop publications:** Resolutions arriving outside `.searching` are dropped.
4. **No TOFU over cached IP:** Cached IP fallback requires an existing pin for the approved logical hostname.
5. **Ordered pin persistence:** `ServerTrustStore` writes pins synchronously under `lock`.

### Transition Table (`DiscoveryState`)

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `idle` | `startDiscovery()` | — | `searching` | Calls `browser.searchForServices(...)` |
| `searching` | `stopDiscovery()` | — | `stopping` | Clears `resolvingServices`; calls `browser.stop()` |
| `stopping` | `startDiscovery()` | — | `restarting` | Waits for `netServiceBrowserDidStopSearch` |
| `restarting` | `stopDiscovery()` | — | `stopping` | Cancels pending restart |
| `stopping` | `netServiceBrowserDidStopSearch` | — | `idle` | — |
| `restarting` | `netServiceBrowserDidStopSearch` | — | `searching` | Calls `browser.searchForServices(...)` |
| `searching` | `netServiceBrowser(_:didNotSearch:)` | — | `idle` | Logs warning |
| `searching` | `netServiceDidResolveAddress` | `state == .searching` | `searching` | Caches IP; publishes `activeServerURL` (if approved) or `pendingApprovalURL` |
| `idle`/`stopping`/`restarting` | `netServiceDidResolveAddress` | `state != .searching` | *(unchanged)* | Drops stale resolution |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **4A/4B (Bonjour stop→start stall & post-stop publish — Issue 5, P2)**
- **4C (Out-of-order `ServerTrustStore` pin persistence — Issue 3, P1)**

---

## SM-5: Failure Streak & Alert Throttle

**Files:** `client/Sources/Managers/NotificationManager.swift`, `client/Sources/Managers/HealthQueryManager.swift`

### State Variables
- `UserDefaults["consecutiveSyncFailures"]` (`Int`, `0..∞`)
- `UserDefaults["lastSyncFailureAlert"]` (`Date?`)
- `lastReportedFailure: [String: Date]` (1h per-type log throttle)

### Invariants
1. **Streak accuracy:** `consecutiveSyncFailures` increments on failing runs, alerts at `>= 3` (at most once per `3600s`), and resets *only* when a **full sweep** (`isFullSweep == true`) completes cleanly.

### Confirmed Reachable Invalid State (Pre-Fix Evidence)
- **5A (Partial observer wake resets full-sweep failure streak — Issue 6, P2):** Single-type observer wakes cleared `consecutiveSyncFailures`, masking persistent failures in non-observed types.

---

## SM-6: QR Camera Scanner Lifecycle

**Files:** `client/Sources/Views/QRScannerView.swift`

### State Variables
- `ScannerState`: `.checkingPermission`, `.ready`, `.running`, `.scanned`, `.unavailable` *(Issue 7)*
- `isViewVisible: Bool`, `sessionQueue: DispatchQueue` (serial)

### Invariants
1. **Serialized `AVCaptureSession` control** on `sessionQueue`.
2. **At-most-once scan emission** per presentation.
3. **No capture after dismissal** if camera permission resolves after `viewWillDisappear`.

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **6A/6B/6C (Concurrent start/stop, duplicate scan emissions, post-dismiss capture — Issue 7, P2)**

---

## SM-7: Dashboard Sync History Fetch, Archive Reconstruction & Cache Refresh

**Files:** `client/Sources/Views/DashboardView.swift`, `client/Sources/Managers/SyncEngine.swift`

### State Variables
- `syncData: [SyncDataPoint]`, `index: SyncHistoryIndex`, `serverTotalRecords: Int`
- `selectedMonth: Date?`, `selectedCategory: String?`
- `fetchTask: Task<Void, Never>?`, `fetchGuard: FetchGenerationGuard`
- `lastRefreshCount: Int`, `UserDefaults["dashboard_cache_months"]`

### States
- `Empty` (`syncData.isEmpty`)
- `Cached` (seeded synchronously from `UserDefaults["dashboard_cache_months"]`)
- `Refreshing(generation)` (`fetchTask != nil`, requesting `GET /api/v1/health-sync/stats?timeScale=months&scope=all`)
- `Loaded` (updated with archive-wide stats + `total_records`)

### Invariants
1. **Single active fetch + monotonic application:** All refreshes go through `refreshData()`, cancelling any prior `fetchTask`, and only `fetchGuard.isCurrent(generation)` may update UI or `UserDefaults`.
2. **Legacy server cache protection:** If an un-upgraded server (omitting `total_records`) returns empty stats for a reinstalled device's new `X-Device-ID`, non-empty cached stats are preserved rather than wiped.
3. **No stale selection across refresh:** `selectedMonth` is cleared if absent from the refreshed `SyncHistoryIndex`.
4. **Background quiescence:** Entering `.background` cancels `fetchTask` and advances `fetchGuard`.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| Any | `.onAppear` / `customServerURL` change / `scenePhase == .active` / `activeServerURL != nil` / sync finishes | — | `Refreshing(g+1)` | Cancels prior `fetchTask`; yields; fetches `scope=all` stats |
| `Refreshing(g)` | `scenePhase == .background` | — | *(Idle)* | Advances `fetchGuard`; cancels `fetchTask` |
| `Refreshing(g)` | `200 OK` decoded | `fetchGuard.isCurrent(g)` & not legacy empty wipe | `Loaded` | Persists raw JSON to `UserDefaults`; updates `syncData`, `index`, `serverTotalRecords`; prunes stale `selectedMonth` |
| `Refreshing(g)` | Error or superseded | — | *(unchanged)* | Preserves existing `syncData` and cache |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **7A (Concurrent `.task` vs `refreshData()` stale overwrite — Issue 8, P3):** Direct `await fetchDashboardStats()` in `.task` raced `refreshData()`.
- **7B (Duplicate launch request + uncancelled background fetch + stale `selectedMonth` — Issue 12, P2):** `DashboardView.swift:185-199` invoked `refreshData()` in *both* `.task` and `.onAppear` (firing and immediately cancelling a redundant request on every launch), did not cancel `fetchTask` on `.background`, and did not validate `selectedMonth` when `applyUpdatedData` replaced `index`.

---

## SM-8: Server Ingest Write Queue, SQLite Transaction, Stats Scope & Shutdown

**Files:** `server/app.js`, `server/db.js`

### State Variables
- `dbPromise`: singleton DB init/migration promise
- `dbQueue: Promise` + `queueDepth: Number` (`0..MAX_QUEUE_DEPTH(64)`)
- `inTransaction: Boolean` (per `ingestPayload` call)
- `knownDevices: Set<String>`
- `shuttingDown: Boolean`

### Invariants
1. **DB ready before HTTP:** `start()` awaits `getDb()` before `fastify.listen(...)`.
2. **Serialized transactions with bounded backpressure:** `enqueueWrite` rejects with HTTP `503` when `queueDepth >= 64`; `dbQueue` never remains rejected across tasks.
3. **Rollback safety:** `knownDevices.add(device_id)` runs only *after* `COMMIT`; any error while `inTransaction` runs `ROLLBACK`.
4. **Idempotent stats & archive reconstruction:** `daily_sync_stats` increments only on `ON CONFLICT(uuid) DO NOTHING RETURNING` and decrements only on `DELETE ... RETURNING`. Because `health_metrics.uuid` is globally `UNIQUE`, `GET /api/v1/health-sync/stats?scope=all` aggregates across all devices with zero double-counting and returns exact `total_records` in the same query pass.
5. **Graceful shutdown:** `shuttingDown` prevents re-entry; unpublishes Bonjour, closes Fastify, drains `dbQueue`, then closes SQLite.

*Audit result: No reachable invalid state transitions found in SM-8; `server/test/` (23/23 passing) covers auth, gzip bomb limits, idempotency, deletion stats, and `scope=all` archive reconstruction.*

---

## SM-9: Live Server Connection Status, Auth Probe & Sync Button Gating

**Files:** `client/Sources/ContentView.swift`, `client/Sources/Managers/SyncEngine.swift`, `client/Sources/Views/SettingsView.swift`

### State Variables
- `connectionStatus: ServerConnectionStatus` (explicit enum: `.invalidURL`, `.discovering`, `.missingApiKey(URL)`, `.checking(URL)`, `.connected(URL)`, `.unauthorized(URL)`, `.unreachable(URL, String)`)
- `connectionCheckTask: Task<Void, Never>?`, `connectionCheckGuard: FetchGenerationGuard`
- `SettingsView`: `isTestingConnection: Bool`, `testConnectionTask: Task<Void, Never>?`, `testConnectionGuard: FetchGenerationGuard`

### Invariants
1. **Never report `.connected` without verified auth:** `.connected(url)` is reachable *only* when a non-empty `apiKey` is stored in Keychain **and** `GET /api/v1/ping` returns HTTP `200`.
2. **Credential-gated sync:** `syncCircleButton` is disabled whenever `connectionStatus.canInitiateSync == false` (`.invalidURL`, `.discovering`, `.missingApiKey`, `.unauthorized`), and discovery auto-sync executes *only* after the live probe confirms `.connected(url)`.
3. **Monotonic probe application:** Only the latest `connectionCheckGuard` (and `testConnectionGuard` in `SettingsView`) generation may publish status updates or clear `isTestingConnection`.
4. **Flicker-free re-verification:** Silently re-probing the same already-`.connected(url)` server on foreground resume keeps showing `.connected` until the probe either confirms `.ok` or fails.

### Transition Table (`ServerConnectionStatus`)

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| Any | `refreshConnectionStatus()` | `resolvedURL == nil && overrideIsInvalid` | `.invalidURL` | Cancels prior probe; disables Sync |
| Any | `refreshConnectionStatus()` | `resolvedURL == nil && !overrideIsInvalid` | `.discovering` | Cancels prior probe; disables Sync |
| Any | `refreshConnectionStatus()` | `resolvedURL != nil && apiKey.trimmed.isEmpty` | `.missingApiKey(url)` | Cancels prior probe; shows Open Settings CTA; disables Sync |
| Any ≠ `.connected(url)` | `refreshConnectionStatus()` | `resolvedURL != nil && !apiKey.isEmpty` | `.checking(url)` | Starts `SyncEngine.checkConnection` under generation `g` |
| `.checking(url)` / `.connected(url)` | Probe returns `.ok` | `connectionCheckGuard.isCurrent(g)` | `.connected(url)` | If `autoSyncIfConnected && !isSyncing && isAuthorized`: starts `performSync` |
| `.checking(url)` / `.connected(url)` | Probe returns `.unauthorized` | `connectionCheckGuard.isCurrent(g)` | `.unauthorized(url)` | Disables Sync; skips auto-sync; shows Open Settings + Retry |
| `.checking(url)` / `.connected(url)` | Probe returns `.serverError` / `.unreachable` | `connectionCheckGuard.isCurrent(g)` | `.unreachable(url, reason)` | Shows Retry; skips auto-sync |
| Any | `scenePhase == .background` | — | *(unchanged)* | Advances `connectionCheckGuard`; cancels `connectionCheckTask` |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **9A (False `"Connected"` with no API key — fixed in v1.6):** `ContentView` previously displayed `"Connected to Server"` solely on `resolvedURL != nil`, misreporting local storage URLs without Keychain API keys as connected.
- **9B (Auto-sync raced ahead of auth verification — Issue 10A, P1):** `ContentView.swift:155-166` fired `performSync` immediately on `activeServerURL` change while `refreshConnectionStatus()` was concurrently discovering `401/403` `.unauthorized`.
- **9C (Duplicate launch ping & un-bumped cancel — Issue 10B, P1):** `ContentView.swift:118,122` ran `refreshConnectionStatus()` in both `.task` and `.onAppear`, cancelling ping #1 on every launch, and `.background` cancelled `connectionCheckTask` without bumping `connectionCheckGuard`.
- **9D (`SettingsView.testConnection` stale overwrite — Issue 10C, P1):** `SettingsView.swift:48-50, 193-208` ran an unguarded `Task` whose late response overwrote `connectionStatusMessage` after the user edited `apiKey` or `customServerURL`.

---

## SM-10: `HealthVitalsStore` On-Device Vitals Pipeline & `VitalsSnapshotCache`

**Files:** `client/Sources/Managers/HealthVitalsStore.swift`

### State Variables
- Published summaries: `heartRate`, `sleep`, `readiness`, `energy`, `cardioFitness`, `overnightVitals`, `gait`
- `isLoading: Bool` (`@Published`, `@MainActor`)
- `fetchTask: Task<Void, Never>?`, `fetchGuard: FetchGenerationGuard`
- Disk cache: `Library/Caches/vitals_snapshot_cache.json` (`NSFileProtectionComplete`, serialized on `VitalsSnapshotCache.writeQueue`, `currentSchemaVersion = 10`, `maxAge = 48h`)

### States
- `Empty`: all summaries `nil`, `isLoading == false`
- `ColdLoading(g)`: `hadData == false`, `isLoading == true`
- `SeededFromCache`: summaries loaded synchronously in `init()`, `isLoading == false`
- `RefreshingInBackground(g)`: `hadData == true`, `isLoading == false` (no spinner flash over cached charts)
- `Fresh`: updated summaries applied with `chartUpdate` spring animation

### Invariants
1. **Generation-owned loading flag:** A superseded generation `g` must *never* clear `isLoading = false` while generation `g+1` is still in flight.
2. **Cache preservation on error:** Transient HealthKit errors or `errorDatabaseInaccessible` (locked device) never wipe existing in-memory or disk snapshots.
3. **Serialized cache writes:** `VitalsSnapshotCache.saveAsync` runs on one serial utility queue so older snapshots cannot overwrite newer ones out of order.
4. **Bounded cache clock validity:** `VitalsSnapshotCache.load` rejects both stale (`age > maxAge`) and far-future clock-skewed (`age < -300s`) envelopes as well as schema mismatches.
5. **Cancellation cleanliness:** `cancel()` advances `fetchGuard`, cancels `fetchTask`, and clears `isLoading`; `CancellationError` is ignored silently.

### Transition Table

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `Init` | `cache.load()` succeeds | `schema == 10 && -300 <= age <= 48h` | `SeededFromCache` | Populates all 7 summaries synchronously before frame 1 |
| `Empty` / `ColdLoading(g)` | `refresh()` | `isAuthorized && isHealthDataAvailable` | `ColdLoading(g+1)` | Cancels prior `fetchTask`; sets `isLoading = true`; runs 19 parallel HealthKit queries + off-MainActor build |
| `SeededFromCache` / `Fresh` | `refresh()` | `isAuthorized && isHealthDataAvailable` | `RefreshingInBackground(g+1)` | Cancels prior `fetchTask`; keeps `isLoading == false` |
| `ColdLoading(g)` / `Refreshing(g)` | Fetch succeeds | `!Task.isCancelled && fetchGuard.isCurrent(g)` | `Fresh` | Enqueues `cache.saveAsync`; animates changed summaries; clears `isLoading` |
| `ColdLoading(g)` | Superseded by `g+1` and exits | `!fetchGuard.isCurrent(g)` | `ColdLoading(g+1)` | Leaves `isLoading == true` untouched; drops result |
| Any | `cancel()` (`.background`) | — | `Empty` / `SeededFromCache` / `Fresh` | Advances `fetchGuard`; cancels `fetchTask`; sets `isLoading = false` |
| Any loading | HealthKit error (non-cancel) | `fetchGuard.isCurrent(g)` | *(prior data preserved)* | Logs debug message; clears `isLoading`; preserves cached state |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **10A (Superseded refresh clears `isLoading` while newer fetch is in flight — Issue 9A, P1):** `HealthVitalsStore.swift:248` executed unconditional `defer { isLoading = false }` when generation `1` exited after being superseded by generation `2` (common on cold launch when `.inactive -> .active` follows `.task`), causing all 7 vitals cards to flash `"No data"` empty states and unblocking `SplashScreenView`'s readiness gate early.
- **10B (`cancel()` skipped generation bump & `catch` logged `CancellationError` — Issue 9B, P1):** `HealthVitalsStore.swift:256-262, 295-298`.
- **10C (Far-future clock-skewed cache never expires — Issue 9C, P1):** `HealthVitalsStore.swift:170` only checked upper bound `<= maxAge`, never lower bound.

---

## SM-11: `SplashScreenView` Biometric Launch Choreography

**Files:** `client/Sources/Views/SplashScreenView.swift`, `client/Sources/ContentView.swift`

### State Variables
- `phase: SplashPhase` (explicit enum: `.animating`, `.dismissing`, `.finished`) *(Issue 11)*
- `isExitingVisual: Bool`, `latestIsReady: Bool`, `dismissTask: Task<Void, Never>?`
- Parent `ContentView.showSplash: Bool`

### Invariants
1. **Single-shot lifecycle:** Plays once per cold launch (`showSplash = true` → `false`); once `.finished`, the view is removed from the hierarchy (`0%` ongoing CPU/GPU cost).
2. **Idempotent dismissal:** `triggerDismiss()` / `finishImmediately()` invoke `onFinished()` at most once.
3. **Zero background spin:** `TimelineView` pauses whenever `phase != .animating || scenePhase != .active`, and backgrounding during splash calls `finishImmediately()` so returning lands directly on the dashboard.
4. **Bounded readiness wait:** Choreography completes in `1.35s` (`0.55s` under Reduce Motion) and waits at most `0.65s` extra for `latestIsReady` (`2.0s` hard ceiling), with tap-to-skip at any time.

### Transition Table (`SplashPhase`)

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `animating` | Choreography + readiness wait completes (not cancelled) | `phase == .animating` | `dismissing` | Pauses `TimelineView`; animates fade/zoom out (`0.36s`); schedules `dismissTask` (`0.38s`) |
| `animating` | User taps splash | `phase == .animating` | `dismissing` | Immediately begins exit animation |
| `animating` / `dismissing` | `scenePhase == .background` | `phase != .finished` | `finished` | Cancels `dismissTask`; calls `onFinished()` immediately |
| `dismissing` | `dismissTask` completes (`0.38s`) | `!Task.isCancelled && phase == .dismissing` | `finished` | Calls `onFinished()` (`showSplash = false`) |
| Any | `.onDisappear` | — | *(torn down)* | Cancels `dismissTask` |

### Confirmed Reachable Invalid States (Pre-Fix Evidence)
- **11A (120Hz `TimelineView` kept running & drifted when backgrounded — Issue 11A, P2):** `SplashScreenView.swift:150` paused only on `isDismissing`, ignoring `scenePhase != .active`.
- **11B (Cancelled `.task` still spawned dismissal `Task` — Issue 11B, P2):** `SplashScreenView.swift:136-141` swallowed `CancellationError` in `try? await Task.sleep` and called `triggerDismiss()` unconditionally.

---

## SM-12: Chart Scrub Gesture & Interactive Card State

**Files:** `client/Sources/Theme/AppTheme.swift`, `HeartRateCardView.swift`, `SleepCardView.swift`, `EnergyCardView.swift`, `CardioFitnessCardView.swift`, `OvernightVitalsCardView.swift`, `GaitBiomechanicsCardView.swift`, `DashboardView.swift`

### State Variables
- `DateChartScrubOverlay`: `@GestureState private var isScrubbing = false`
- Per-card ephemeral selection: `selectedBucket`, `selectedSegment`, `selectedDay`, `selectedPoint`, `selectedSpeedPoint`, `selectedStepPoint`, `selectedMonth`
- Persistent collapse state: `@AppStorage("cardCollapsed_<card>")` (9 cards)

### Invariants
1. **No ScrollView hijacking:** `LongPressGesture(minimumDuration: 0.15).sequenced(before: DragGesture(minimumDistance: 0))` lets normal vertical swipes scroll freely.
2. **Guaranteed release on interruption:** `@GestureState` resets to `false` even on hard system gesture cancellation (Control Center, Notification Center, incoming call), firing `onEnd()` via `.onChange(of: isScrubbing)` so scrub readouts never get stuck.
3. **iOS 17+ plot geometry safety:** Uses `proxy.plotFrame` (unwrapped safely) and `proxy.plotSize` with zero deprecation warnings.

---

## Prioritized Issues & Resolution Tracker

All **12 confirmed issues** are fixed and verified by `DataDonorTests` (`client/Tests/StateMachineRegressionTests.swift`, **39/39 passing**) and `server/test/` (**23/23 passing**).

| Issue | Priority | State Machine(s) | Fix Summary | Status | Regression Test(s) |
|---|---|---|---|---|---|
| **Issue 1** | **P0 (Critical)** | SM-2 (`SyncEngine`) | Keyed `pendingUploads`, `responseBodies`, and `payloadFiles` by per-attempt `attemptId` (`UploadTaskIdentity` `"<batchToken>\|<attemptId>"`, preserving legacy parsing) while recording orphan 2xx acks under `batchToken`; added `cancelledAttempts` under `stateLock` so pre-registration cancellation aborts atomically without hanging. | **Fixed** | `testIssue1_UploadTaskIdentityParsesCurrentAndLegacyFormats`, `testIssue1_RetryDoesNotDeleteInFlightAttemptFileOrStealContinuation`, `testIssue1_DetachedAttempt2xxRecordedUnderBatchToken`, `testIssue1_CancelBeforeRegistrationAbortsWithoutHanging` |
| **Issue 2** | **P0 (Critical)** | SM-1 (`HealthQueryManager`) | Persisted `pendingFullResync` in `resetAllAnchors()` so `reconcileAnchorState()` / `applyServerCheckpoints()` skips seeding server anchors until a full sweep finishes cleanly; added `guard !isSyncing` to `resetAllAnchors()`; separated internal `clearLocalSyncState()`. | **Fixed** | `testIssue2_ResetAllAnchorsSurvivesServerCheckpointReconciliation`, `testIssue2_FreshInstallWithoutResetStillSeedsServerCheckpoints`, `testIssue2_ResetAllAnchorsRefusesToMutateWhileSyncing` |
| **Issue 3** | **P1 (High)** | SM-2, SM-4 (`OrphanedUploadStore`, `ServerTrustStore`, `SyncEngine`, `AppDelegate`) | Persisted `OrphanedUploadStore` and `ServerTrustStore` synchronously under their locks; replaced raw `backgroundCompletionHandler` with `setBackgroundCompletionHandler(_:)` + `pendingBackgroundEventsFinished`. | **Fixed** | `testIssue3_OrphanedUploadStoreConcurrentRecordAndConsumeNeverResurrectsTokens`, `testIssue3_ServerTrustStoreForgetPersistsSynchronouslyWithoutAsyncClobber`, `testIssue3_BackgroundCompletionHandlerInvokedRegardlessOfOrder` |
| **Issue 4** | **P1 (High)** | SM-3 (`BackgroundSyncManager`) | Set `hasPendingDeferredSync = true` when observer wakes coalesce into an active sync, arrive during `isObserverDrainExpiring` teardown, or when a `BGTask` full sweep finishes `.deferred`, `.failed`, `.cancelled`, or expires. | **Fixed** | `testIssue4_ObserverWakeDuringActiveSyncSetsPendingDeferredAndFiresCompletion`, `testIssue4_ObserverWakeDuringExpirationTeardownSetsPendingDeferredAndFiresImmediately`, `testIssue4_BGTaskOutcomesTrackPendingDeferredSyncAndDASStatus` |
| **Issue 9** | **P1 (High)** | SM-10 (`HealthVitalsStore`, `VitalsSnapshotCache`) | Guarded `defer { if fetchGuard.isCurrent(generation) { isLoading = false } }` so superseded refreshes cannot clear `isLoading` while a newer fetch is in flight; advanced `fetchGuard` and cleared `isLoading` in `cancel()`; ignored `CancellationError` in `catch`; rejected far-future clock-skewed cache timestamps (`age < -300s`). | **Fixed** | `testIssue9_SupersededVitalsRefreshDoesNotClearIsLoadingWhileNewerFetchInFlight`, `testIssue9_VitalsSnapshotCacheRejectsFarFutureClockSkewedSnapshots`, `testReviewFinding3_VitalsStorePreservesCachedSnapshotOnQueryError` |
| **Issue 10** | **P1 (High)** | SM-9, SM-3 (`ContentView`, `SettingsView`, `SyncEngine`, `BackgroundSyncManager`, `HealthQueryManager`) | Gated discovery auto-sync on live `checkConnection(...) == .ok` (updating `connectionStatus` from the same probe); centralized `cancelConnectionCheck()` advancing `connectionCheckGuard`; eliminated duplicate `.task`/`.onAppear` launch ping; guarded `SettingsView.testConnection` with `FetchGenerationGuard` + cancellation on edit/disappear; made `BackgroundSyncManager` fail fast on `.unauthorized` instead of retrying cached IP; guarded `performSync` against empty `apiKey`. | **Fixed** | `testServerConnectionStatusRequiresApiKeyAndVerifiedPing`, `testIssue10_SyncEngineCheckConnectionRejectsEmptyApiKeyWithoutNetwork` |
| **Issue 5** | **P2 (Medium)** | SM-4 (`ServerDiscoveryManager`) | Replaced `isSearching: Bool` with explicit `DiscoveryState` (`.idle`, `.searching`, `.stopping`, `.restarting`); cancelled in-flight `NetService` resolves on stop and dropped late resolutions outside `.searching`. | **Fixed** | `testIssue5_StopThenStartWaitsForDidStopSearchBeforeRestarting`, `testIssue5_LateResolutionAfterStopDoesNotPublishServer` |
| **Issue 6** | **P2 (Medium)** | SM-5 (`NotificationManager`, `HealthQueryManager`) | Restricted clearing `consecutiveSyncFailures` to clean full sweeps (`isFullSweep == true`). | **Fixed** | `testIssue6_PartialObserverSuccessDoesNotResetFullSweepFailureStreak` |
| **Issue 7** | **P2 (Medium)** | SM-6 (`QRScannerView`) | Serialized `AVCaptureSession` start/stop onto `sessionQueue`, added explicit `ScannerState` with single-emission guard, and gated startup on `isViewVisible`. | **Fixed** | `testIssue7_ScannerEmitsScannedCodeAtMostOnce` |
| **Issue 11** | **P2 (Medium)** | SM-11 (`SplashScreenView`) | Replaced `isDismissing: Bool` with explicit `SplashPhase` (`.animating`, `.dismissing`, `.finished`), paused `TimelineView` when `scenePhase != .active`, dismissed immediately on `.background`, checked `Task.isCancelled` after sleep, and cancelled `dismissTask` on `.onDisappear`. | **Fixed** | `testSplashWaveformMathRPeakAlignmentAndLubDubScale` |
| **Issue 12** | **P2 (Medium)** | SM-7 (`DashboardView`) | Deduplicated `.task`/`.onAppear` launch fetch into `.onAppear`, added `cancelRefresh()` advancing `fetchGuard` on `.background`, and pruned stale `selectedMonth` when refreshed data omits it. | **Fixed** | `testIssue8_FetchGenerationGuardRejectsSupersededRequests`, `testServerStatsResponseDecodesArchiveTotalAndLegacyFormat`, `testSyncHistoryIndexPrecomputesTotalsCategoriesAndBinarySearchNearestMonth` |
| **Issue 8** | **P3 (Low)** | SM-7 (`DashboardView`) | Routed initial fetch through `refreshData()` and guarded chart/cache application with monotonic `FetchGenerationGuard`. | **Fixed** | `testIssue8_FetchGenerationGuardRejectsSupersededRequests` |

### Running Verification

```bash
# iOS regression tests (XCTest — 39 tests)
xcodebuild test -project client/DataDonor.xcodeproj -scheme DataDonor \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO

# Server tests (23 tests)
cd server && npm test
```
