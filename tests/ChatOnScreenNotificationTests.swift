// ChatOnScreenNotificationTests.swift
//
// The chat on screen posts no notification: its conversation open and the app
// active (James, 2026-10-19: "make sure notifications are defeated for
// messages on a Channel that is on screen"). Until then a channel never set
// NotificationManager.activeChatId, so each post in the channel being read
// notified over it (a local notification from the app, or the NSE's banner
// through willPresent); and the app-side check ignored the foreground, so an
// open DM behind the home screen stayed silent.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/ChatOnScreenNotificationTests.swift
//
// Source-level: NotificationManager needs UserNotifications and the app.

import Foundation

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String, _ detail: String = "") {
    if condition() {
        print("ok    - \(name)")
    } else {
        let message = detail.isEmpty ? name : "\(name) — \(detail)"
        print("FAIL  - \(message)")
        failures.append(message)
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}
let manager = source("Retichat/Services/NotificationManager.swift")
let app = source("Retichat/RetichatApp.swift")
let view = source("Retichat/Views/Conversation/ConversationView.swift")

// 1. The rule: open, with the app active; ids without case.
check(manager.contains("static func chatOnScreen(appActive: Bool, openChatId: String?, chatId: String) -> Bool {\n        guard appActive, let openChatId else { return false }\n        return openChatId.lowercased() == chatId.lowercased()"),
      "on screen is the open chat with the app active, ids compared without case")
check(manager.contains("if Self.chatOnScreen(appActive: appActive, openChatId: activeChatId, chatId: chatId) {\n            print(\"[Notify] chat \\(chatId.prefix(8)) is on screen — not notified\")\n            return"),
      "the app's own notifications skip the chat on screen")
check(manager.contains("if let chatId = chatId, Self.chatOnScreen(appActive: true, openChatId: activeChatId, chatId: chatId) {"),
      "a banner in the foreground (the NSE's too) is not shown for the chat on screen")
check(!manager.contains("chatId == activeChatId"), "no check of the open chat without the foreground")

// 2. The foreground, from launch.
check(app.contains(".onChange(of: scenePhase, initial: true) { _, phase in\n            NotificationManager.shared.appActive = phase == .active\n        }"),
      "the app's foreground state is kept from launch")

// 3. A channel screen marks itself open, as a DM screen does.
check(view.contains("if case .channel(let channel) = mode {\n                channelClient.retainRfedLinkMonitor()\n"
                    + "                // The channel open here is the chat on screen, as an open DM\n"
                    + "                // is: its posts notify nothing while the app is active.\n"
                    + "                NotificationManager.shared.activeChatId = channel.id\n"
                    + "                NotificationManager.shared.clearNotifications(forChatId: channel.id)"),
      "an open channel is the chat on screen, and its delivered notifications go")
check(view.contains("if NotificationManager.shared.activeChatId == channel.id { NotificationManager.shared.activeChatId = nil }"),
      "a closing channel leaves a newer screen's mark")
check(view.contains("if NotificationManager.shared.activeChatId == id { NotificationManager.shared.activeChatId = nil }"),
      "a closing DM leaves a newer screen's mark")

// 4. A channel post is notified under the channel's id.
let client = source("Retichat/Services/RfedChannelClient.swift")
check(client.contains("NotificationManager.shared.postMessageNotification(chatId: channelHashHex,") ||
      client.contains("NotificationManager.shared.postMessageNotification(\n                chatId: channelHashHex"),
      "a channel post's notification carries the channel's hash, the id its screen marks")

if failures.isEmpty {
    print("\nall passed")
} else {
    print("\n\(failures.count) failed")
    exit(1)
}
