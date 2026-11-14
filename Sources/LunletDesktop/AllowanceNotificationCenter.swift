// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-41, AC-41.01, AC-41.05.
import Foundation
import LunletCore
import UserNotifications

/// Notification Center as the deliverer. The notification service serves only a bundled process, so `system()`
/// hands back an unavailable deliverer anywhere else, such as the test runner.
@MainActor final class AllowanceNotificationCenter: NSObject, AllowanceNotificationDelivering {
    static func system() -> any AllowanceNotificationDelivering {
        Bundle.main.bundleIdentifier == "com.lunlet" ? AllowanceNotificationCenter() : AllowanceNotificationsUnavailable()
    }
    private let center = UNUserNotificationCenter.current()
    var activated: ((SessionProvider) -> Void)?

    private override init() {
        super.init()
        center.delegate = self
    }
    func authorizationState() async -> AllowanceNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .granted
        @unknown default: .denied
        }
    }
    func requestAuthorization() async -> AllowanceNotificationAuthorization {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .granted : await authorizationState()
    }
    func deliver(_ notice: AllowanceNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body(now: Date())
        content.sound = .default
        content.threadIdentifier = notice.reading.key
        try? await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
    }
}

extension AllowanceNotificationCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        guard let provider = AllowanceNotice.provider(of: identifier) else { return }
        await MainActor.run { activated?(provider) }
    }
    /// A banner shows even while Lunlet is the active application.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// The deliverer of a process that cannot post notifications; Settings says so.
@MainActor final class AllowanceNotificationsUnavailable: AllowanceNotificationDelivering {
    var activated: ((SessionProvider) -> Void)?
    func authorizationState() async -> AllowanceNotificationAuthorization { .unavailable }
    func requestAuthorization() async -> AllowanceNotificationAuthorization { .unavailable }
    func deliver(_ notice: AllowanceNotice) async {}
}
