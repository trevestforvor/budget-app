import BackgroundTasks
import UIKit
import UserNotifications

/// What only an app delegate hears: the APNs device token, notifications arriving or being tapped, and the background
/// refresh that tells the server the phone's time zone.
///
/// Every completion here runs on the main thread. UIKit updates the app's snapshot when a background task completes and
/// asserts that's on the main thread ("Call must be made on main thread"); SwiftUI's `.backgroundTask` finished it from
/// a background thread under Swift 6 and crashed the app.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so a tap that launched the app isn't missed and the refresh is registered in time.
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: MorningSummaryModel.refreshTaskID, using: .main) { task in
            MainActor.assumeIsolated { MorningSummaryModel.shared.handleRefresh(task) }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MorningSummaryModel.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        MorningSummaryModel.shared.didFailToRegister(error)
    }

    /// With the app open, the summary still shows as a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.banner, .list]) }
    }

    /// A tapped summary opens Activity on its day; a tapped pace alert, the budget, category or merchant it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        let payload = Dictionary(info.compactMap { key, value in (key as? String).flatMap { k in (value as? String).map { (k, $0) } } },
                                 uniquingKeysWith: { first, _ in first })
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if payload["kind"] == "pace" {
                    MorningSummaryModel.shared.openPace(payload)
                } else if let day = payload["day"] {
                    MorningSummaryModel.shared.open(day: day)
                }
            }
            completionHandler()
        }
    }
}
