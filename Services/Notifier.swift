import Foundation
import UserNotifications

protocol NotificationCenterAdapter: Sendable {
    func register(delegate: UNUserNotificationCenterDelegate)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async
    func post(_ content: UNNotificationContent)
}

struct UserNotificationAdapter: NotificationCenterAdapter {
    func register(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let follow = UNNotificationAction(identifier: Notifier.followAction, title: AppLanguage.isChinese ? "改过去" : "Move There", options: [])
        let category = UNNotificationCategory(identifier: Notifier.exitChangedCategory, actions: [follow],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func post(_ content: UNNotificationContent) {
        let id = content.categoryIdentifier.isEmpty ? UUID().uuidString : content.categoryIdentifier
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let exitChangedCategory = "EXIT_CHANGED"
    static let followAction = "FOLLOW_EXIT"

    private let center: NotificationCenterAdapter
    @MainActor private var authorization: Task<Void, Never>?
    @MainActor var onFollow: (@MainActor () -> Void)?

    init(center: NotificationCenterAdapter = UserNotificationAdapter()) {
        self.center = center
        super.init()
        center.register(delegate: self)
    }

    @MainActor func requestAuthorizationIfNeeded() async {
        if let authorization { return await authorization.value }
        let task = Task { [center] in
            if await center.authorizationStatus() == .notDetermined { await center.requestAuthorization() }
        }
        authorization = task
        await task.value
        authorization = nil
    }

    func post(title: String, body: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        center.post(content)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await handleResponse(category: response.notification.request.content.categoryIdentifier, action: response.actionIdentifier)
    }

    @MainActor func handleResponse(category: String, action: String) {
        guard category == Self.exitChangedCategory,
              action == Self.followAction || action == UNNotificationDefaultActionIdentifier else { return }
        onFollow?()
    }
}
