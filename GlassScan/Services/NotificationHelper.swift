import Foundation
import UserNotifications

enum NotificationHelper {
    private static let ujingOrderPrefix = "ujing_order_done_"

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func scheduleLaundryDone(orderId: String, deviceName: String, isDryer: Bool, inSeconds seconds: Int) {
        let id = "\(ujingOrderPrefix)\(orderId)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])

        guard seconds > 10 else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = isDryer ? "U净 · 衣物已烘干" : "U净 · 衣物已洗完"
        content.body = "「\(deviceName)」已完成，记得及时去取衣物"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }

    static func cancelLaundryDone(orderId: String) {
        let id = "\(ujingOrderPrefix)\(orderId)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
