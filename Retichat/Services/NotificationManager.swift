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
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// The currently-active chat ID — suppress notifications for this chat.
    var activeChatId: String?

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

    func postMessageNotification(chatId: String, senderName: String, content: String) {
        // Don't notify if user is viewing this chat
        if chatId == activeChatId { return }
        // Don't notify if user has muted this chat
        if UserPreferences.shared.isChatMuted(chatId) { return }

        postLocalNotification(chatId: chatId, senderName: senderName, content: content)
    }

    /// Post a regular local notification (used when not already covered by an APNs push).
    private func postLocalNotification(chatId: String, senderName: String, content: String) {
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
            identifier: UUID().uuidString,
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

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification arrives while the app is in the foreground.
    /// Show it as a banner unless the user is viewing that chat.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let chatId = notification.request.content.userInfo["chatId"] as? String
        let body = notification.request.content.body

        // Suppress if user is viewing this chat
        if let chatId = chatId, chatId == activeChatId {
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
