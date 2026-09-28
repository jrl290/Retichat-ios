// ChannelLastMessageTimeTests.swift
//
// The "Jun 30" bug (staging cross-client run, 2026-09-27): a public channel's
// chat-list row showed "Jun 30" for a post the sim made that day. The send
// path (RfedChannelClient.sendMessage, since f0d4271) handed the post's wire
// timestamp in milliseconds to updateChannelLastMessage, which stores
// seconds; the receive path divided by 1000. 1.79e12 "seconds" is a June
// date in the year ~58,700, and the chat list formats anything not today or
// yesterday as "MMM d".
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/channel-last-message-time \
//     Retichat-ios/Retichat/Services/ChannelTime.swift \
//     Retichat-ios/tests/ChannelLastMessageTimeTests.swift && \
//     /private/tmp/claude-501/channel-last-message-time
//
// ChannelTime runs for real. updateChannelLastMessage and its callers need
// SwiftData and the FFI, so the wiring is asserted on the source, like
// NSEChannelPullTests.swift.

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

func dayString(_ seconds: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date(timeIntervalSince1970: seconds))
}

// The post from the staging run: 2026-09-27 20:56:25.749 local, as LXMF ms.
let postMs: UInt64 = 1_790_556_985_749

func testTheConversion() {
    let seconds = ChannelTime.lastMessageSeconds(postMs: postMs)
    check(seconds == 1_790_556_985.749, "a post's ms become seconds", "\(seconds)")
    check(dayString(seconds) == "2026-09-28" || dayString(seconds) == "2026-09-27",
          "the post lands on the day it was made", dayString(seconds))
    // What the send path did: the ms read as seconds is a far-future June.
    check(dayString(Double(postMs)).hasSuffix("-06-30"),
          "the old unit error is the Jun 30 the chat list showed", dayString(Double(postMs)))
    check(ChannelTime.lastMessageSeconds(postMs: 0) == 0, "zero stays zero (no time shown)")
}

func testTheStoredRowCorrection() {
    let wrong = Double(postMs)
    let fixed = ChannelTime.normalizedStoredSeconds(wrong)
    check(fixed == 1_790_556_985.749, "a stored ms value is corrected to seconds", "\(fixed)")
    check(ChannelTime.normalizedStoredSeconds(fixed) == fixed, "the correction is idempotent")
    let now = 1_790_557_315.921
    check(ChannelTime.normalizedStoredSeconds(now) == now, "a seconds value is left alone")
    check(ChannelTime.normalizedStoredSeconds(0) == 0, "zero is left alone")
    check(ChannelTime.normalizedStoredSeconds(ChannelTime.millisecondFloor) == ChannelTime.millisecondFloor,
          "the floor itself is seconds (only values above it are ms)")
    check(ChannelTime.millisecondFloor == 1e11, "the floor is the 1e11 the other migrations use")
}

func testTheWiring() {
    let client = source("Retichat/Services/RfedChannelClient.swift")
    check(!client.isEmpty, "reads RfedChannelClient.swift")

    let update = body(of: "private func updateChannelLastMessage(", in: client)
    check(update.contains("postMs: UInt64"),
          "updateChannelLastMessage takes the post's wire ms, not a unit-free Double")
    check(update.contains("ChannelTime.lastMessageSeconds(postMs:"),
          "updateChannelLastMessage converts through ChannelTime")

    let calls = matches(#"updateChannelLastMessage\([^)]*\)"#, in: client)
        .filter { !$0.contains("postMs: UInt64") }
    check(calls.count == 2, "two call sites: send and receive", "\(calls)")
    for call in calls {
        check(call.contains("postMs: tsMs"), "call passes the wire ms", call)
        check(!call.contains("time:"), "no call passes a pre-converted time", call)
    }

    let load = body(of: "private func loadPersistedChannels(", in: client)
    check(load.contains("ChannelTime.normalizedStoredSeconds("),
          "loading channels corrects rows stored in ms")
    check(load.contains("if seconds != raw { $0.lastMessageTime = seconds }"),
          "the corrected value is written back to the row")
    check(load.contains("try? ctx.save()"), "and saved")
}

@main
enum ChannelLastMessageTimeTests {
    static func main() {
        testTheConversion()
        testTheStoredRowCorrection()
        testTheWiring()
        if failures.isEmpty {
            print("all channel last-message time tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
