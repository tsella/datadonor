import Foundation
import UserNotifications

final class NotificationManager: @unchecked Sendable {
    static let shared = NotificationManager()

    /// Throttles per-type failure notifications so a broken server can't produce one
    /// alert per data type on every sync.
    private var lastReportedFailure: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 3600
    private let lock = NSLock()

    /// A sync run has to fail this many times in a row before the owner is told.
    /// One expired window, one dropped connection or one flaky type is routine in
    /// the background, and belongs in the log rather than on the lock screen.
    private let failureAlertThreshold = 3
    /// Running count of failed runs. Stored in UserDefaults because a background
    /// sync usually gets a fresh process, and an in-memory count would restart at
    /// zero every run and never reach the threshold.
    private let consecutiveFailuresKey = "consecutiveSyncFailures"
    /// Time of the last alert, also persisted, so a restart does not re-alert.
    private let lastAlertKey = "lastSyncFailureAlert"
    /// While a streak runs past the threshold, alert at most this often.
    private let alertInterval: TimeInterval = 3600

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                DataDonorLogger.shared.log("Notification permission error: \(error.localizedDescription)", level: .warn)
            } else {
                DataDonorLogger.shared.log("Notification permission granted: \(granted)", level: .info)
            }
        }
    }

    /// Records a failed upload for a single data type. Only logs; the user-facing summary
    /// is sent once at the end of a sync so we don't spam the lock screen.
    func reportSyncFailure(type: String, error: Error) {
        lock.lock()
        let now = Date()
        let shouldNotify: Bool
        if let last = lastReportedFailure[type], now.timeIntervalSince(last) < throttleInterval {
            shouldNotify = false
        } else {
            lastReportedFailure[type] = now
            shouldNotify = true
        }
        lock.unlock()

        guard shouldNotify else { return }
        DataDonorLogger.shared.log(
            "Sync failure for \(type): \(error.localizedDescription)", level: .error)
    }

    /// Records the result of one whole sync run and decides whether to alert.
    /// Returns true at the third consecutive failure, then at most once per
    /// `alertInterval` while the streak continues. A clean run clears the streak.
    func recordSyncOutcome(failedTypeCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard failedTypeCount > 0 else {
            UserDefaults.standard.removeObject(forKey: consecutiveFailuresKey)
            UserDefaults.standard.removeObject(forKey: lastAlertKey)
            return false
        }

        let streak = UserDefaults.standard.integer(forKey: consecutiveFailuresKey) + 1
        UserDefaults.standard.set(streak, forKey: consecutiveFailuresKey)

        guard streak >= failureAlertThreshold else {
            DataDonorLogger.shared.log(
                "Sync failure streak \(streak)/\(failureAlertThreshold); no alert until the streak reaches \(failureAlertThreshold).",
                level: .warn)
            return false
        }

        let now = Date()
        if let lastAlert = UserDefaults.standard.object(forKey: lastAlertKey) as? Date,
           now.timeIntervalSince(lastAlert) < alertInterval {
            return false
        }
        UserDefaults.standard.set(now, forKey: lastAlertKey)
        return true
    }

    func sendSyncErrorNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "DataDonor Sync Error"
        content.body = message
        content.sound = .default

        // Reuse a stable identifier so a repeated failure replaces the previous alert
        // rather than stacking up in Notification Center.
        let request = UNNotificationRequest(identifier: "sync_error", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DataDonorLogger.shared.log("Failed to post sync error notification: \(error.localizedDescription)", level: .warn)
            }
        }
    }
}
