import SwiftUI
import UIKit
import UserNotifications

@main
struct AlarmClockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

/// 负责通知回调：App 在前台时不重复弹横幅（前台由 App 自己全屏响铃），
/// 点击测试提醒通知则进入全屏测试响铃，锁屏状态下同样可用。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 前台已由 App 内全屏响铃接管，不再叠加横幅与声音
        if notification.request.identifier == "medtest" {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == "medtest" {
            Task { @MainActor in
                await AlarmScheduler.shared.fireTestReminder()
            }
        }
        completionHandler()
    }
}
