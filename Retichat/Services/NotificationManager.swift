//
//  NotificationManager.swift
//  Retichat
//
//  Local notification management: permission, posting, badge count,
//  foreground presentation, and tap-to-navigate handling.
//  Mirrors Android MessageNotificationHelper + notification channels.
//

import Foundation
import UserNotifications
import UIKit

/// Notification posted when the user taps a notification banner.
/// The `object` is the `chatId` string.
extension Notification.Name {
    static let openChatFromNotification = Notification.Name("OpenChatFromNotification")
    /// Posted for rfed/APNs wakes that arrive through the user-notification
    /// delegate path instead of UIApplication's remote-notification callback.
    static let rfedPushReceived = Notification.Name("RfedPushReceived")
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// The chat whose conversation is open (a DM, Group or channel id), set
    /// by ConversationView. It notifies nothing while the app is active
    /// (chatOnScreen).
    var activeChatId: String?

    /// The app is in the foreground (scenePhase .active), set by RetichatApp.
    /// An open chat behind the home screen is not on screen.
    var appActive = false

    /// Whether `chatId` is on screen: the open chat, with the app active. Ids
    /// compare without case: a channel's is its hash in hex, lowercased by the
    /// NSE. Until 2026-10-19 a channel never marked itself open, so its posts
    /// notified over it, and an open DM behind the home screen stayed silent
    /// (James, 2026-10-19).
    static func chatOnScreen(appActive: Bool, openChatId: String?, chatId: String) -> Bool {
        guard appActive, let openChatId else { return false }
        return openChatId.lowercased() == chatId.lowercased()
    }

    /// Badge counts per chat — cleared when user opens the conversation.
    private var badgeCounts: [String: Int] = [:]
    private let lock = NSLock()

    // MARK: - Setup

    private override init() {
        super.init()
    }

    /// Call once at app launch, before any notifications fire.
    func configure() {
        UNUserNotificationCenter.current().delegate = self

        // Define the "message" category (extensible for inline-reply later)
        let messageCategory = UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [],
            intentIdentifiers: ["INSendMessageIntent"],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([messageCategory])
    }

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if let error = error {
                print("[Retichat] Notification permission error: \(error)")
            }
            print("[Retichat] Notifications \(granted ? "granted" : "denied")")
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    /// Returns the current authorization status.
    func checkPermission(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }

    // MARK: - Post

    /// `messageId` is the message's transient id when it is known
    /// (NotificationIds): the notification is posted under it.
    func postMessageNotification(chatId: String, senderName: String, content: String, messageId: Data? = nil) {
        // Don't notify if user is viewing this chat
        if Self.chatOnScreen(appActive: appActive, openChatId: activeChatId, chatId: chatId) {
            print("[Notify] chat \(chatId.prefix(8)) is on screen — not notified")
            return
        }
        // Don't notify if user has muted this chat
        if UserPreferences.shared.isChatMuted(chatId) { return }
        print("[Notify] chat \(chatId.prefix(8)): notified")

        postLocalNotification(chatId: chatId, senderName: senderName, content: content, messageId: messageId)
    }

    /// Post a regular local notification (used when not already covered by an APNs push).
    ///
    /// With `messageId` it is posted under the message's transient id, the
    /// identifier apns-bridge's push for the message has (its
    /// apns-collapse-id), so a push that comes after it replaces it rather
    /// than adding one. It is not posted when a notification with that id is
    /// shown already: the push came first, or another copy of the message did
    /// (RFed-spec Notify.md "One notification per message").
    private func postLocalNotification(chatId: String, senderName: String, content: String, messageId: Data?) {
        let identifier = NotificationIds.requestIdentifier(messageId: messageId)
        guard messageId != nil else {
            addLocalNotification(identifier: identifier, chatId: chatId, senderName: senderName, content: content)
            return
        }
        Task { @MainActor in
            let shown = await UNUserNotificationCenter.current().deliveredNotifications()
            if shown.contains(where: { $0.request.identifier == identifier }) {
                print("[Notify] message \(identifier.prefix(16)) is shown already — not notified again")
                return
            }
            self.addLocalNotification(identifier: identifier, chatId: chatId, senderName: senderName, content: content)
        }
    }

    private func addLocalNotification(identifier: String, chatId: String, senderName: String, content: String) {
        let notifContent = UNMutableNotificationContent()
        notifContent.title = senderName
        notifContent.body = content
        notifContent.sound = .default
        notifContent.threadIdentifier = chatId        // groups per chat
        notifContent.categoryIdentifier = "MESSAGE"
        notifContent.userInfo = ["chatId": chatId]

        // Update badge
        incrementBadge(chatId: chatId)
        notifContent.badge = NSNumber(value: totalBadgeCount())

        let request = UNNotificationRequest(
            identifier: identifier,
            content: notifContent,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Retichat] Failed to post notification: \(error)")
            }
        }
    }

    // MARK: - Badge management

    private func incrementBadge(chatId: String) {
        lock.lock()
        badgeCounts[chatId, default: 0] += 1
        lock.unlock()
    }

    private func totalBadgeCount() -> Int {
        lock.lock()
        let total = badgeCounts.values.reduce(0, +)
        lock.unlock()
        return total
    }

    func clearNotifications(forChatId chatId: String) {
        lock.lock()
        badgeCounts.removeValue(forKey: chatId)
        let remaining = badgeCounts.values.reduce(0, +)
        lock.unlock()

        // Remove delivered notifications for this chat
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let toRemove = notifications.filter {
                $0.request.content.threadIdentifier == chatId
            }.map { $0.request.identifier }

            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: toRemove
            )
        }

        // Update badge
        updateBadge(count: remaining)
    }

    func clearAll() {
        lock.lock()
        badgeCounts.removeAll()
        lock.unlock()

        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        updateBadge(count: 0)
    }

    private func updateBadge(count: Int) {
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }

    private func notifyRfedPushIfNeeded(_ userInfo: [AnyHashable: Any]) {
        guard userInfo["rfed"] != nil else { return }
        NotificationCenter.default.post(name: .rfedPushReceived, object: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification arrives while the app is in the foreground.
    /// Show it as a banner unless the user is viewing that chat.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        notifyRfedPushIfNeeded(notification.request.content.userInfo)

        let chatId = notification.request.content.userInfo["chatId"] as? String
        let body = notification.request.content.body

        // Suppress if user is viewing this chat (willPresent comes only in the foreground)
        if let chatId = chatId, Self.chatOnScreen(appActive: true, openChatId: activeChatId, chatId: chatId) {
            print("[Notify] banner for chat \(chatId.prefix(8)) not shown: it is on screen")
            completionHandler([])
            return
        }
        // Suppress empty NSE notifications (sync-complete with nothing to show)
        if body.isEmpty {
            completionHandler([])
            return
        }
        // Show banner + sound + badge even in foreground
        completionHandler([.banner, .sound, .badge])
    }

    /// Called when the user taps a notification.
    /// Post a Notification to navigate to the specific chat.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        notifyRfedPushIfNeeded(userInfo)
        if let chatId = userInfo["chatId"] as? String {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .openChatFromNotification,
                    object: chatId
                )
            }
        }
        completionHandler()
    }
}
