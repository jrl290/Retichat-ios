// ChannelResumeEntryTests.swift
//
// Coming back to a channel from the background is another entry (James,
// 2026-10-19): the steps that opening it from the chat list runs (streaming
// on, page-load re-enabled, auto-pull once the rfed link is up) run again.
// Before, the return pulled at once whether the link was up or not, and a
// pull that failed for want of a link wasn't tried again when it came up.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/ChannelResumeEntryTests.swift
//
// Source-level: ConversationView needs SwiftUI, SwiftData and the FFI.

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
let view = try String(
    contentsOf: root.appendingPathComponent("Retichat/Views/Conversation/ConversationView.swift"),
    encoding: .utf8
)

/// The text from `start` up to the next `end` after it.
func span(from start: String, to end: String, in source: String) -> String {
    guard let a = source.range(of: start),
          let b = source.range(of: end, range: a.upperBound..<source.endIndex) else { return "" }
    return String(source[a.lowerBound..<b.lowerBound])
}

// 1. A return to the foreground counts an entry and forgets the last
//    auto-pull, and doesn't pull by itself.
let resume = span(from: ".onChange(of: scenePhase)", to: ".onReceive(Timer.publish", in: view)
check(!resume.isEmpty, "the scene phase handler is found")
check(resume.contains("lastAutoPullGeneration = nil"), "a resume forgets the last auto-pull")
check(resume.contains("channelEntries &+= 1"), "a resume counts an entry")
check(!resume.contains("pullDeferred"), "a resume doesn't pull at once, link up or not")

// 2. Each entry runs the entry steps again.
let entry = span(from: ".onChange(of: channelEntries)", to: "}", in: view)
check(entry.contains("markChannelOpenedForStreaming(channelHashHex: channel.id)"), "an entry turns streaming on")
check(entry.contains("canPullMore[channelKey] = nil"), "an entry re-enables loading earlier messages")

// 3. The auto-pull runs again on an entry, still only with the link up, and
//    its pull isn't cancelled when the key moves on.
let autoPull = span(from: ".task(id: \"\\(channelClient.rfedLinkGeneration)/\\(channelEntries)\")", to: "\n        }\n    }", in: view)
check(!autoPull.isEmpty, "the auto-pull is keyed on the link generation and the entries")
check(autoPull.contains("guard channelClient.rfedNodeStatus == .connected"), "the auto-pull waits for the link")
check(autoPull.contains("Task { await channelClient.pullDeferred(channel: channel) }"), "the pull is its own task")

if failures.isEmpty {
    print("\nall passed")
} else {
    print("\n\(failures.count) failed")
    exit(1)
}
