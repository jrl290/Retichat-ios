// ChatSwipeTests.swift
//
// The chat list's trailing swipe (James, 2026-10-05): on a group, Delete
// asks first, with the words of the chat info's Delete (the members are
// told, and it is final), then leaves and deletes the group through
// ChatRepository.deleteChat, which takes quitGroup, exactly as the chat
// info's Delete does. A direct chat's Delete still archives it; a pending
// invite still offers Decline (asks first) and Accept. Until 2026-10-05 the
// swipe only archived a group: it carried on, its members still counting
// the user.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/chat-swipe \
//     Retichat-ios/Retichat/Views/ChatList/ChatSwipe.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/tests/ChatSwipeTests.swift && \
//     /private/tmp/claude-501/chat-swipe
//
// ChatSwipe runs for real; the SwiftUI wiring is asserted on the source,
// and deleteChat's way to quitGroup is GroupModelTests.swift's.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok    - \(what)")
    } else {
        failures.append(what)
        print("FAIL  - \(what)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// The text from `start` up to the first `end` after it.
func span(_ text: String, from start: String, to end: String) -> String {
    guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return "" }
    return String(text[a.lowerBound..<b.upperBound])
}

func testTheChoice() {
    check(ChatSwipe.of(isGroup: true, isPendingInvite: false) == .leaveGroup,
          "a group's swipe leaves and deletes it (after asking)")
    check(ChatSwipe.of(isGroup: false, isPendingInvite: false) == .archive, "a direct chat's swipe archives it, as before")
    check(ChatSwipe.of(isGroup: true, isPendingInvite: true) == .invite, "a pending invite's swipe offers Decline and Accept")
}

func testTheWiring() {
    let list = source("Retichat/Views/ChatList/ChatListView.swift")
    let swipe = span(list, from: "switch ChatSwipe.of(isGroup: chat.isGroup,", to: "case .channel(let channel):")
    check(!swipe.isEmpty, "the swipe follows ChatSwipe")
    let group = span(swipe, from: "case .leaveGroup:", to: "case .archive:")
    check(group.contains("leaving = chat") && !group.contains("archiveChat") && !group.contains("deleteChat"),
          "a group's Delete only asks: nothing happens before the confirmation")
    check(span(swipe, from: "case .archive:", to: "}\n                                    }").contains("repository.archiveChat(chatId: chat.id)"),
          "a direct chat's Delete archives it")
    let dialog = span(list, from: ".confirmationDialog(GroupDeleteText.title(distro: leaving?.isDistroGroup ?? false),",
                      to: "Text(GroupDeleteText.message(distro: chat.isDistroGroup))")
    check(dialog.contains("presenting: leaving") && dialog.contains("repository.deleteChat(chatId: chat.id)")
            && dialog.contains("Button(\"Cancel\", role: .cancel) { leaving = nil }"),
          "confirmed, it deletes the group through deleteChat (quitGroup), as the chat info's Delete")
    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    check(view.contains(".confirmationDialog(isGroup ? GroupDeleteText.title(distro: isDistroGroup) : \"Delete this conversation?\"")
            && view.contains("Text(isGroup ? GroupDeleteText.message(distro: isDistroGroup)")
            && view.contains("onDelete: {\n                        repository.deleteChat(chatId: chatId)"),
          "the chat info's Delete uses the same words and the same deleteChat")
    check(view.contains("static let message = \"Deleting a group conversation leaves the group: the members are told you left, and you won't be able to rejoin it. All messages will be permanently deleted.\""),
          "the words say the members are told and it is final")
}

/// GROUPS-DISTRO-DESIGN.md §8.7 (James, 2026-10-11): a group that uses a distro address no
/// longer on this device offers no Accept, Decline or leave; its Delete asks, then removes it
/// from this device only (deleteGroupFromThisDevice: no leave, no group sync). While the app is
/// starting a group's swipe offers what it always offers, greyed, with no text, and never
/// "Delete from this device".
func testAFormerDistroGroupAndStartUp() {
    check(ChatSwipe.of(isGroup: true, isPendingInvite: false, formerDistro: true) == .deleteFromThisDevice,
          "§8.7: a joined group whose distro is gone only deletes from this device")
    check(ChatSwipe.of(isGroup: true, isPendingInvite: true, formerDistro: true) == .deleteFromThisDevice,
          "§8.7: a pending invite whose distro is gone offers no Accept or Decline")
    check(ChatSwipe.of(isGroup: false, isPendingInvite: false, formerDistro: true) == .archive,
          "a direct chat is unaffected")
    check(ChatSwipe.of(isGroup: true, isPendingInvite: false, formerDistro: false) == .leaveGroup,
          "a group whose distro is here, or not read yet, still leaves (after asking)")
    let list = source("Retichat/Views/ChatList/ChatListView.swift")
    check(list.contains("formerDistro: chat.formerDistroText != nil) {"),
          "the swipe asks the chat whether its distro is gone, never whether it is merely not ready")
    check(!list.contains("cannotAct"), "nothing else turns the swipe into Delete from this device")
    let all = span(list, from: "switch ChatSwipe.of(isGroup: chat.isGroup,", to: "case .channel(let channel):")
    let invite = span(all, from: "case .invite:", to: "case .leaveGroup:")
    check(invite.components(separatedBy: ".disabled(chat.groupActionsWait)").count - 1 == 2,
          "start-up: Decline and Accept are greyed")
    check(span(all, from: "case .leaveGroup:", to: "case .archive:").contains(".disabled(chat.groupActionsWait)"),
          "start-up: a group's Delete is greyed")
    check(!span(all, from: "case .archive:", to: "case .deleteFromThisDevice:").contains(".disabled("),
          "a direct chat's Delete never is")
    let swipe = span(list, from: "case .deleteFromThisDevice:", to: "}\n                                    }")
    check(swipe.contains("deletingHere = chat") && !swipe.contains("deleteChat") && !swipe.contains("deleteGroupFromThisDevice"),
          "its Delete only asks: nothing happens before the confirmation")
    let dialog = span(list, from: ".confirmationDialog(GroupSelf.deleteLocalTitle + \"?\",", to: "Text(GroupSelf.deleteLocalMessage)")
    check(dialog.contains("presenting: deletingHere") && dialog.contains("repository.deleteGroupFromThisDevice(chatId: chat.id)")
            && !dialog.contains("repository.deleteChat("),
          "confirmed, it deletes the group from this device only, never through deleteChat (quitGroup)")
    check(GroupSelf.deleteLocalTitle == "Delete from this device"
            && GroupSelf.deleteLocalMessage == "This removes the group from this device only. You stay in the group on your other devices and for the other members.",
          "§8.7's words, exactly")
}

@main
struct ChatSwipeTestsMain {
    static func main() {
        testTheChoice()
        testTheWiring()
        testAFormerDistroGroupAndStartUp()
        if failures.isEmpty {
            print("all chat swipe tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
