// ChannelPostQueueTests.swift
//
// A channel post that cannot go now waits, queued, as Android's does (James,
// 2026-10-19: "on iOS, there isn't the same queuing of Channel message sends
// when coming out of background and connections need to be reestablished").
// Until then a post sent while the rfed.link was still coming back waited
// 5 s for it, 5 s more, and showed the red mark; one sent before the stack
// was ready waited in memory only, and was lost with the process.
//
// Now: with no stack or no rfed.link the post is stored as queued (the
// pending clock), the link is opened, and the queue is released, oldest
// first, when the stack starts and on every ACTIVE edge of the link; a send
// that fails with the link gone, or gets no answer on a link that still reads
// ACTIVE but died in the background, is queued again, not failed; and a post an
// earlier process left sending is failed at the next start, not left on the
// clock.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/ChannelPostQueueTests.swift
//
// Source-level: RfedChannelClient needs SwiftData, the FFI and a stack.

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
let client = source("Retichat/Services/RfedChannelClient.swift")
let models = source("Retichat/Models/Models.swift")
let bubble = source("Retichat/Views/Components/GlassComponents.swift")

/// The text of the function whose signature starts with `signature`, up to the next `    func`/`    private func`.
func body(_ signature: String) -> String {
    guard let start = client.range(of: signature) else { return "" }
    let rest = client[start.upperBound...]
    let next = ["\n    func ", "\n    private func ", "\n    nonisolated ", "\n    // MARK"]
        .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
    return String(client[start.lowerBound..<next])
}

// 1. The state, and the clock it shows.
check(models.contains("static let queued = 5"), "DeliveryState has queued")
check(bubble.contains("case DeliveryState.pending, DeliveryState.queued:"), "a queued post shows the pending clock")

// 2. A post that cannot go now is queued.
let send = body("private func sendMessageAsync(")
check(send.contains("guard canIssueRfedOperations, Self.linkUp(RfedLink.shared.status(nodeHex: channel.rfedNodeHash)) else {"),
      "the send waits for the stack and the channel's rfed.link")
check(send.contains("queuePost(optimisticId: optimisticId, channel: channel)"), "it is queued, not sent into a link that is not up")
check(!client.contains("enqueuePendingSend"), "no post waits in memory only")
check(send.components(separatedBy: "if requeueIfLinkDown(optimisticId: optimisticId, channel: liveChannel) { return }").count - 1 == 3,
      "every failure with the link gone queues it again rather than failing it")

// A link that died in the background still reads ACTIVE until its own
// request timeout tears it down (AppLinks then re-opens it): a post sent on it
// in that window is not answered, and waits for the new link.
let trySendBody = body("private func trySend(")
check(trySendBody.contains("return answer == nil ? .unanswered : .failed"), "a send with no answer is told apart from a refusal")
check(send.components(separatedBy: "case .unanswered:").count - 1 == 2
      && send.components(separatedBy: "queuePost(optimisticId: optimisticId, channel: liveChannel)").count - 1 == 2,
      "a post with no answer is queued, not failed")
check(send.components(separatedBy: "case .sent:\n            releaseQueuedPosts()").count - 1 == 2,
      "a post rfed took releases any still queued: its link is up")

let queue = body("private func queuePost(")
check(queue.contains("state: DeliveryState.queued"), "queuePost stores it queued")
check(queue.contains("RfedLink.shared.ensure(nodeHex: channel.rfedNodeHash)"), "queuePost opens the link, so its ACTIVE edge comes")

// 3. The release: at start, on each ACTIVE edge, oldest first, once per release.
check(body("func start()").contains("releaseQueuedPosts()"), "start releases the queue")
check(client.contains("RfedLink.shared.setBinder(owner: \"channel-queue\") { [weak self] _ in\n            self?.releaseQueuedPosts()"),
      "every ACTIVE edge of an rfed.link releases the queue")
let release = body("private func releaseQueuedPosts()")
check(release.contains("sortBy: [SortDescriptor(\\.timestamp)]"), "oldest first")
check(release.contains("if releasingQueuedPosts {\n            releaseQueuedPostsAgain = true"), "one release at a time; one asked for meanwhile runs after it")
check(release.contains("state: DeliveryState.pending)\n                    await sendMessageAsync("), "each post is taken from the queue before it is sent")
check(!release.contains("asyncAfter") && !release.contains("Task.sleep"), "no timer: each release follows a signal")

// 4. A post an earlier process left sending.
let load = body("private func loadPersistedMessages()")
check(load.contains("where e.isOutgoing && e.deliveryState == DeliveryState.pending"), "a post left sending by an earlier process is found at start")
check(load.contains("e.deliveryState = DeliveryState.failed"), "and failed, not left on the clock")

if failures.isEmpty {
    print("\nall passed")
} else {
    print("\n\(failures.count) failed")
    exit(1)
}
