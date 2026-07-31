import Foundation
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Notification permission granted.")
            } else if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    func sendSyncErrorNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "DataDonor Sync Error"
        content.body = message
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    func sendDailySummaryNotification(recordsSynced: Int) {
        let content = UNMutableNotificationContent()
        content.title = "DataDonor Sync Complete"
        content.body = "Successfully synced \(recordsSynced) health records to your server."
        content.sound = .default
        
        // In a real implementation, this would be scheduled or triggered only once a day
        let request = UNNotificationRequest(identifier: "daily_summary", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
