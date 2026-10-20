// ChatGlitchTests.swift
//
// Two glitches on the chat screen (James, 2026-10-20):
//
// 1. "When the app foregrounds, the bubbles momentarily scroll down 1-2
//    bubbles and then back to the end of the chat." A return to a channel is
//    an entry, which shows "Load earlier messages" until the pull answers. The
//    row came and went above the posts, and the list, with no bottom anchor,
//    slid down by it and back. The row now keeps one height, button or not.
//
// 2. "When sending, two bubbles for the same message appear, then one is
//    removed." rfed sends a post to the channel's readers, this device among
//    them, before it answers the publish. The echo was stored as a second
//    bubble beside the placeholder until the answer removed the placeholder.
//    The echo of a post awaiting its answer now becomes the post's bubble.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/ChatGlitchTests.swift
//
// Source-level: the view and RfedChannelClient need SwiftUI, SwiftData, the
// FFI and a stack.

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
let view = source("Retichat/Views/Conversation/ConversationView.swift")
let client = source("Retichat/Services/RfedChannelClient.swift")

func inOrder(_ text: Substring, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for part in parts {
        guard let r = text.range(of: part, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}

func body(_ text: String, _ signature: String) -> Substring {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let next = ["\n    func ", "\n    private func ", "\n    nonisolated ", "\n    // MARK"]
        .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
    return text[start.lowerBound..<next]
}

// ---- 1. The channel list's top row ----

let channelList = body(view, "private func channelMessagesList(channel: Channel)")
check(inOrder(channelList, [
    "LazyVStack(spacing: 4) {",
    "Color.clear",
    ".frame(height: loadEarlierRowHeight)",
    ".overlay {",
    "if canPull {",
    "Text(pulling ? \"Loading…\" : \"Load earlier messages\")",
    "ForEach(dayRows(msgs, timestamp: Self.channelSeconds))",
]), "the top row has one height, and the button shows inside it")
// The button is the only thing in the list that a return turns on and off:
// nothing else above the posts may come and go.
let aboveThePosts = channelList[..<(channelList.range(of: "ForEach(dayRows(msgs")?.lowerBound ?? channelList.endIndex)]
let lazy = aboveThePosts[(aboveThePosts.range(of: "LazyVStack(spacing: 4) {")?.upperBound ?? aboveThePosts.endIndex)...]
let topLevel = lazy.split(separator: "\n").filter { $0.hasPrefix("                    ") && !$0.hasPrefix("                     ") }
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("//") }
check(topLevel == ["Color.clear"], "nothing else sits above the posts", "\(topLevel)")
check(view.contains("@ScaledMetric(relativeTo: .caption) private var loadEarlierRowHeight: CGFloat = 36"),
      "the row grows with the caption's text size")
// A return is still an entry (James, 2026-10-19).
check(inOrder(body(view, "var body: some View")[...], [
    ".onChange(of: scenePhase) { _, phase in", "lastAutoPullGeneration = nil", "channelEntries &+= 1",
]), "a return to the channel is still an entry")

// ---- 2. The echo of a post awaiting rfed's answer ----

let trySend = body(client, "private func trySend(")
check(inOrder(trySend, [
    "let canonicalId = (Data(hexString: postingHex) ?? Data()).hexString",
    "postsAwaitingAnswer[canonicalId] = optimisticId",
    "let answer = await RfedLink.shared.request(nodeHex: channel.rfedNodeHash, path: \"/channel/publish\"",
    "let echoed = postsAwaitingAnswer.removeValue(forKey: canonicalId) == nil",
    "if let refusal = Self.publishRefusal(answer) {",
    "guard echoed else {",
    "return answer == nil ? .unanswered : .failed",
    "recordPostName(postName, channelHashHex: channel.id, postingHex: postingHex)",
    "showSent(optimisticId: optimisticId, canonicalId: canonicalId,",
    "return .sent",
]), "a post awaits its answer by its echo's id, and an echo that came first counts as rfed's yes")

let dispatch = body(client, "private func dispatchVerifiedLxmf(")
check(inOrder(dispatch, [
    "let msgId = senderHashHex + String(format: \"%016llx\", tsMs)",
    "if let optimisticId = postsAwaitingAnswer.removeValue(forKey: msgId) {",
    "showSent(optimisticId: optimisticId, canonicalId: msgId, channelHash: channelHashHex,",
    "return true",
    "let existingForChannel",
    "modelContext?.insert(entity)",
]), "the echo of a post awaiting its answer becomes its bubble, before anything is stored")

let showSent = body(client, "private func showSent(")
check(inOrder(showSent, [
    "temp.id = canonicalId", "temp.deliveryState = DeliveryState.sent",
    "if let idx = list.firstIndex(where: { $0.id == optimisticId }) {",
    "list[idx] = ChannelMessage(", "id: canonicalId", "deliveryState: DeliveryState.sent",
]), "the placeholder becomes the post in place, in the store and on screen")
check(!showSent.contains("list.append("), "never a second bubble")

if failures.isEmpty {
    print("\nall passed")
} else {
    print("\n\(failures.count) failed")
    exit(1)
}
