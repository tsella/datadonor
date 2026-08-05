import Foundation
import UserNotifications

final class NotificationManager: @unchecked Sendable {
    static let shared = NotificationManager()

    /// Throttles per-type failure notifications so a broken server can't produce one
    /// alert per data type on every sync.
    private var lastReportedFailure: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 3600
    private let lock = NSLock()

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

    func sendDailySummaryNotification(recordsSynced: Int) {
        let content = UNMutableNotificationContent()
        content.title = "DataDonor Sync Complete"
        content.body = "Successfully synced \(recordsSynced) health records to your server."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "daily_summary", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DataDonorLogger.shared.log("Failed to post summary notification: \(error.localizedDescription)", level: .warn)
            }
        }
    }
}
