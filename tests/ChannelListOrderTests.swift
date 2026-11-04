// ChannelListOrderTests.swift
//
// A channel goes to the top of the chat list only when it is active (James,
// 2026-11-03: "I want the Channel chat to be open and a message be sent or
// received before moving it to the top of the chat list"; the posts a channel
// loads on opening count). Until then a tap on a channel's row moved it to the
// top, with or without anything new. Now UserPreferences.markChannelActive is
// called for a post sent from the channel and for a post stored while the
// channel is the chat open (NotificationManager.activeChatId), and nowhere
// else; the list places a channel by that time, and its row still shows its
// newest post's.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/channel-list-order \
//     Retichat-ios/Retichat/Services/ChannelActivity.swift \
//     Retichat-ios/tests/ChannelListOrderTests.swift && \
//     /private/tmp/claude-501/channel-list-order
//
// ChannelActivity runs for real. Its callers need SwiftData, SwiftUI and the
// FFI, so the wiring is asserted on the source, like
// ChannelLastMessageTimeTests.swift.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    if ok {
        print("ok    - \(what)")
    } else {
        let message = detail.isEmpty ? what : "\(what) — \(detail)"
        failures.append(message)
        print("FAIL  - \(message)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// Every match of `pattern` (a regex) in `text`, as strings.
func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
}

/// The body of `signature` in `text`, up to its closing brace at the same indent.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.lowerBound...]
    guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
    return String(rest[..<end.upperBound])
}

/// The channel ids in the order the chat list shows them.
func order(_ times: [String: Double], _ lastMessageTimes: [String: Double]) -> [String] {
    lastMessageTimes.keys.sorted {
        let a = ChannelActivity.sortTime(times, channelId: $0, lastMessageTime: lastMessageTimes[$0]!)
        let b = ChannelActivity.sortTime(times, channelId: $1, lastMessageTime: lastMessageTimes[$1]!)
        return a != b ? a > b : $0 < $1
    }
}

func testActivityOnlyMovesAChannelUp() {
    var times = ChannelActivity.marked([:], channelId: "aa", at: 100)
    check(times == ["aa": 100], "a channel active for the first time takes that time", "\(times)")
    times = ChannelActivity.marked(times, channelId: "aa", at: 90)
    check(times["aa"] == 100, "an earlier time never moves it down", "\(times)")
    times = ChannelActivity.marked(times, channelId: "aa", at: 120)
    check(times["aa"] == 120, "a later one moves it up", "\(times)")
}

func testEveryChannelStartsWhereItStands() {
    // Before 2026-11-03: "aa" and "dd" were opened at 300 and 50; "bb" and
    // "cc" never were, so the list placed them by their newest post.
    let opened: [String: Double] = ["aa": 300, "dd": 50]
    let lastMessageTimes: [String: Double] = ["aa": 100, "bb": 400, "cc": 200, "dd": 500]
    let before = lastMessageTimes.keys.sorted {
        (opened[$0] ?? lastMessageTimes[$0]!) > (opened[$1] ?? lastMessageTimes[$1]!)
    }
    guard let placed = ChannelActivity.placingNew(opened, lastMessageTimes: lastMessageTimes) else {
        check(false, "the channels never opened are placed")
        return
    }
    check(placed == ["aa": 300, "bb": 400, "cc": 200, "dd": 50],
          "each channel never opened is placed at its newest post; the opened keep their times", "\(placed)")
    check(order(placed, lastMessageTimes) == before, "the list keeps the order it had",
          "\(order(placed, lastMessageTimes)) vs \(before)")
    check(ChannelActivity.placingNew(placed, lastMessageTimes: lastMessageTimes) == nil,
          "placing again changes nothing")
}

func testPostsMoveAChannelOnlyWhenItIsActive() {
    var lastMessageTimes: [String: Double] = ["aa": 100, "bb": 400]
    var times = ChannelActivity.placingNew(["aa": 300], lastMessageTimes: lastMessageTimes) ?? [:]
    check(order(times, lastMessageTimes) == ["bb", "aa"], "bb starts on top")
    // A post comes in to "aa" while it is not open: its row's time moves, its place does not.
    lastMessageTimes["aa"] = 900
    check(order(times, lastMessageTimes) == ["bb", "aa"], "a post while the channel is not open leaves it in its place")
    // "aa" is opened and a post it missed loads: it was active.
    times = ChannelActivity.marked(times, channelId: "aa", at: 1000)
    check(order(times, lastMessageTimes) == ["aa", "bb"], "a post while it is open moves it to the top")
    // A channel just joined is placed at its join: the top.
    lastMessageTimes["cc"] = 1100
    times = ChannelActivity.placingNew(times, lastMessageTimes: lastMessageTimes) ?? times
    check(order(times, lastMessageTimes).first == "cc", "a channel just joined goes to the top")
}

func testTheWiring() {
    let client = source("Retichat/Services/RfedChannelClient.swift")
    let prefs = source("Retichat/Services/UserPreferences.swift")
    let list = source("Retichat/Views/ChatList/ChatListView.swift")
    let conversation = source("Retichat/Views/Conversation/ConversationView.swift")
    check(!client.isEmpty && !prefs.isEmpty && !list.isEmpty && !conversation.isEmpty, "reads the sources")

    // Sent: a new post; one released from the queue was marked when it was typed.
    let send = body(of: "private func sendMessageAsync(", in: client)
    let newPost = send.range(of: "} else {").map { at -> String in
        let rest = send[at.lowerBound...]
        return String(rest[..<(rest.range(of: "\n        }\n")?.upperBound ?? rest.endIndex)])
    } ?? ""
    check(newPost.contains("prefs.markChannelActive(channel.id)"), "a post sent from the channel moves it")
    check(matches(#"markChannelActive\("#, in: send).count == 1, "a post released from the queue does not")

    // Stored: only while the channel is the chat open; the echo of the user's
    // own post (moved by its send) and a post already here come back first.
    let dispatch = body(of: "private func dispatchVerifiedLxmf(", in: client)
    check(dispatch.contains(
        "if NotificationManager.shared.activeChatId?.lowercased() == channelHashHex.lowercased() {\n"
        + "            prefs.markChannelActive(channelHashHex)\n"
        + "        }"), "a post stored moves it only while the channel is open")
    check(matches(#"markChannelActive\("#, in: dispatch).count == 1, "once, for a post stored")
    check(matches(#"markChannelActive\("#, in: client).count == 2, "the client marks a channel in those two places only")
    check(!body(of: "func markChannelOpenedForStreaming(", in: client).contains("markChannelActive"),
          "opening a channel marks nothing")
    check(!conversation.contains("markChannelActive"), "nor does the conversation screen")

    // A channel new to the list is placed; a channel left forgets its place.
    check(client.contains("@Published var channels: [Channel] = [] {")
          && client.contains("prefs.placeNewChannels(lastMessageTimes: Dictionary(channels.map { ($0.id, $0.lastMessageTime) },"),
          "every change to the channels places the new ones")
    check(body(of: "private func leaveHere(", in: client)
            .contains("prefs.forgetChannelActivity(channelHashHex)\n        channels.removeAll { $0.id == channelHashHex }"),
          "a channel left forgets its place")

    // The list orders a channel by its activity, a tap moves nothing, and the
    // row shows its newest post's time.
    check(list.contains("return ChannelActivity.sortTime(UserPreferences.shared.channelLastActive,"),
          "the list orders a channel by when it was active")
    check(!list.contains("markChannel"), "a tap on a channel's row moves nothing")
    check(list.contains("Text(formatRelativeTime(channel.lastMessageTime))"), "the row shows its newest post's time")

    // The times carry on under the key they had.
    check(prefs.contains("static let channelLastActive = \"channel_last_opened\""), "the stored times keep their key")
    check(prefs.contains("channelLastActive = ChannelActivity.marked(channelLastActive, channelId: channelId, at: time)"),
          "marking goes through ChannelActivity")
}

@main
enum ChannelListOrderTests {
    static func main() {
        testActivityOnlyMovesAChannelUp()
        testEveryChannelStartsWhereItStands()
        testPostsMoveAChannelOnlyWhenItIsActive()
        testTheWiring()
        if failures.isEmpty {
            print("all channel list order tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
