// DMScrollTests.swift
//
// The open DM or group conversation froze for good while messages arrived
// (staging 2026-10-18, iOS simulator): every main-thread sample sat in one
// SwiftUI update, GraphHost.flushTransactions running transaction after
// transaction over the LazyVStack's placements and height estimates. It
// came from the animated scroll to the newest message. A new message ran
// `withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }`, and with
// rows from one line to ~2000 pt tall (a 2500-character message with no
// spaces) the LazyVStack's estimates for the rows it has not measured move
// while the animation runs toward a target whose place they decide, so
// each step of the animation laid the list out again and the update never
// ended. A fresh chat taking short and long messages 3 s apart froze in
// 7 of 7 runs on rfed-link and in 2 of 5 on the 1.28 App Store build
// (7cdfaa0): it is not new. Scrolled without animation, 0 of 3 froze, and
// keeping the animation but anchoring the bottom only at the first layout
// (defaultScrollAnchor(.bottom, for: .initialOffset)) still froze 3 of 3.
//
// So the DM list scrolls to its newest message without animation, from
// every place it does so: a message arriving, the keyboard opening, and a
// send. SwiftUI's layout cannot run here, so this is asserted on the
// source, like NSEChannelPullTests.swift; the freeze itself is checked on
// staging (a fresh chat, test-harnesses/staging, short and long messages
// 3 s apart, `sample` on the app for GraphHost.flushTransactions).
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/dm-scroll \
//     Retichat-ios/tests/DMScrollTests.swift && \
//     /private/tmp/claude-501/dm-scroll

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
let source = try! String(contentsOf: root.appendingPathComponent(
    "Retichat/Views/Conversation/ConversationView.swift"), encoding: .utf8)

/// The text from the first `start` to the next `end` after it, "" when either is missing.
func section(_ start: String, _ end: String) -> String {
    guard let from = source.range(of: start),
          let to = source.range(of: end, range: from.upperBound..<source.endIndex) else { return "" }
    return String(source[from.lowerBound..<to.lowerBound])
}

let dmList = section("private var messagesList: some View", "// MARK: - Channel message list")
let dmSend = section("case .dm(let id):\n            // §8.7", "case .channel(let ch):")

check(!dmList.isEmpty, "the DM list is found")
check(!dmSend.isEmpty, "the DM send is found")

// Each scroll is still there: to the newest message, at the bottom.
check(dmList.contains(".onChange(of: viewModel.messages.count)"), "the DM list scrolls when a message arrives")
check(dmList.contains("keyboardWillShowNotification"), "the DM list scrolls when the keyboard opens")
check(dmList.components(separatedBy: "scrollTo(lastId, anchor: .bottom)").count - 1 >= 3,
      "the DM list scrolls to the newest message, at the bottom (load, arrival, keyboard)")
check(dmSend.contains("scrollTo(lastId, anchor: .bottom)"), "a DM send scrolls to the newest message")

// None of them animated.
check(!dmList.contains("withAnimation"), "the DM list never animates a scroll",
      "an animated scrollTo in the LazyVStack froze the main thread")
check(!dmSend.contains("withAnimation"), "a DM send never animates its scroll",
      "an animated scrollTo in the LazyVStack froze the main thread")

if failures.isEmpty {
    print("\nall passed")
} else {
    print("\n\(failures.count) failed")
    exit(1)
}
