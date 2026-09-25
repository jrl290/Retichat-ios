// OutboundAttemptsTests.swift
//
// Regression tests for the propagated copy of a 1:1 message (James,
// 2026-09-24: duplicate messages must be deduplicated). Until then the copy
// was built as a new message — a new timestamp, so a new LXMF message hash —
// and a recipient that got both the DIRECT message and the copy showed it
// twice; a message with attachments got no copy at all. The copy is now a
// clone (message_clone_propagated) with the DIRECT message's hash, so both
// attempts report under one hash and ChatRepository counts the attempts in
// flight with OutboundAttempts.
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/outbound-attempts \
//     Retichat-ios/Retichat/Services/OutboundAttempts.swift \
//     Retichat-ios/tests/OutboundAttemptsTests.swift && \
//     /private/tmp/claude-501/outbound-attempts
//
// The OutboundAttempts checks drive the pure type. The ChatRepository checks
// read the source, like HeldSendsTests.swift: ChatRepository needs the FFI
// and SwiftData, so the wiring (clone, one pending entry, routing order) is
// asserted on the code itself.

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

typealias Step = OutboundAttempts.Step

let nothing = Step()
let copyWhilePropagating = Step(show: .propagating, startCopy: true)

// MARK: - OutboundAttempts

func testStart() {
    let direct = OutboundAttempts(direct: true)
    check(direct.inFlight == 1 && !direct.copyStarted && !direct.isComplete,
          "a DIRECT send starts with one attempt in flight and no copy")
    let propagated = OutboundAttempts(direct: false)
    check(propagated.inFlight == 1 && !propagated.copyStarted && !propagated.isComplete,
          "a PROPAGATED-only send starts with one attempt in flight")
}

func testTimerPStartsTheCopyBesideTheDirectAttempt() {
    var a = OutboundAttempts(direct: true)
    let step = a.propagationRequested()
    check(step == copyWhilePropagating, "0x10 starts the copy and shows propagating", "got \(step)")
    check(a.inFlight == 2, "0x10: the copy runs beside the DIRECT attempt", "inFlight \(a.inFlight)")
    check(a.propagationRequested() == nothing && a.inFlight == 2,
          "a second 0x10 starts no second copy")
    check(a.failed() == nothing && a.inFlight == 1,
          "after 0x10 a failure is one attempt ending, not a second copy")
}

func testDirectFailureBeforeAnyCopyStartsIt() {
    var a = OutboundAttempts(direct: true)
    let step = a.failed()
    check(step == copyWhilePropagating,
          "a failure before any copy starts it and shows propagating (was: left pending)",
          "got \(step)")
    check(a.inFlight == 1 && a.copyStarted && !a.isComplete,
          "the copy takes the failed DIRECT attempt's place: still one in flight",
          "inFlight \(a.inFlight)")
    check(a.propagationRequested() == nothing && a.inFlight == 1,
          "0x10 after the DIRECT failure starts no second copy")
    let sent = a.sent()
    check(sent == Step(show: .sent, complete: true), "the copy's SENT shows sent and completes",
          "got \(sent)")
}

func testCopyFailsWhileDirectLiveKeepsWaiting() {
    var a = OutboundAttempts(direct: true)
    _ = a.propagationRequested()
    let step = a.failed()
    check(step == nothing && !a.isComplete && a.inFlight == 1,
          "the copy failing while the DIRECT attempt runs keeps waiting, bubble untouched",
          "got \(step), inFlight \(a.inFlight)")
    let delivered = a.delivered()
    check(delivered == Step(show: .delivered, complete: true),
          "the DIRECT attempt's DELIVERED then completes it delivered", "got \(delivered)")
}

func testDirectFailsAfterCopyStartedKeepsWaitingOnTheCopy() {
    var a = OutboundAttempts(direct: true)
    _ = a.propagationRequested()
    check(a.failed() == nothing && !a.isComplete,
          "the DIRECT attempt failing after the copy started keeps waiting on the copy")
    let sent = a.sent()
    check(sent == Step(show: .sent, complete: true), "the copy's SENT completes it sent",
          "got \(sent)")
}

func testBothFailFailsOnce() {
    var a = OutboundAttempts(direct: true)
    _ = a.propagationRequested()
    _ = a.failed()
    let last = a.failed()
    check(last == Step(show: .failed, complete: true),
          "both attempts failing shows failed and completes", "got \(last)")
    check(a.failed() == nothing && a.sent() == nothing && a.delivered() == nothing,
          "nothing after completion shows or completes a second time")

    var b = OutboundAttempts(direct: true)
    _ = b.failed()          // DIRECT failed: copy started, one in flight
    let copyFailed = b.failed()
    check(copyFailed == Step(show: .failed, complete: true),
          "DIRECT failed then the copy failed: failed once", "got \(copyFailed)")
}

func testSentThenLateDelivered() {
    // 0x10: two in flight; the node takes the copy first.
    var a = OutboundAttempts(direct: true)
    _ = a.propagationRequested()
    let sent = a.sent()
    check(sent == Step(show: .sent), "SENT with the DIRECT attempt still running shows sent, keeps waiting",
          "got \(sent)")
    let delivered = a.delivered()
    check(delivered == Step(show: .delivered, complete: true),
          "a DELIVERED after SENT upgrades to delivered and completes", "got \(delivered)")

    // Success is sticky: the DIRECT attempt failing after the copy was SENT
    // completes without showing failed.
    var b = OutboundAttempts(direct: true)
    _ = b.propagationRequested()
    _ = b.sent()
    let directFailed = b.failed()
    check(directFailed == Step(complete: true),
          "a failure after SENT completes without showing failed", "got \(directFailed)")

    // DIRECT failed, copy SENT: complete; the late proof (LXMF-rust 9ef5174)
    // comes for a hash with no pending entry — ChatRepository's 0x08 branch.
    var c = OutboundAttempts(direct: true)
    _ = c.failed()
    check(c.sent() == Step(show: .sent, complete: true), "the copy's SENT after a DIRECT failure completes")
    check(c.delivered() == nothing, "a DELIVERED after completion is not the type's to handle")
}

func testCopyNotStarted() {
    var a = OutboundAttempts(direct: true)
    _ = a.propagationRequested()
    check(a.copyNotStarted() == nothing && a.inFlight == 1 && !a.isComplete,
          "a copy that could not start, DIRECT still running: keep waiting")
    check(a.failed() == Step(show: .failed, complete: true),
          "then the DIRECT failure is the last: failed")

    var b = OutboundAttempts(direct: true)
    _ = b.failed()
    check(b.copyNotStarted() == Step(show: .failed, complete: true),
          "a copy that could not start after the DIRECT failure: failed")

    var c = OutboundAttempts(direct: true)
    check(c.copyNotStarted() == nothing && c.inFlight == 1,
          "copyNotStarted without a copy changes nothing")
}

func testPropagatedOnlySendHasNoCopy() {
    var a = OutboundAttempts(direct: false)
    check(a.propagationRequested() == nothing, "a PROPAGATED-only send starts no copy on 0x10")
    check(a.failed() == Step(show: .failed, complete: true),
          "a PROPAGATED-only send's failure is final")

    var b = OutboundAttempts(direct: false)
    check(b.sent() == Step(show: .sent, complete: true),
          "a PROPAGATED-only send completes on SENT (the distro's DELIVERED never comes)")
}

func testDeliveredFirstEndsIt() {
    var a = OutboundAttempts(direct: true)
    check(a.delivered() == Step(show: .delivered, complete: true), "DELIVERED completes at once")
    check(a.propagationRequested() == nothing && a.failed() == nothing,
          "no copy and no failure after DELIVERED")
}

func testOneCopyWhicheverComesFirst() {
    for order in [["0x10", "fail"], ["fail", "0x10"], ["0x10", "0x10", "fail", "fail"]] {
        var a = OutboundAttempts(direct: true)
        var copies = 0
        for event in order {
            let step = event == "0x10" ? a.propagationRequested() : a.failed()
            if step.startCopy { copies += 1 }
        }
        check(copies == 1, "one copy per message for \(order)", "got \(copies)")
    }
}

// MARK: - ChatRepository wiring

func chatRepositorySource() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Retichat/Services/ChatRepository.swift")
    return try String(contentsOf: url, encoding: .utf8)
}

/// The method from its signature to its closing brace (methods sit at four
/// spaces in ChatRepository, so the first "\n    }\n" ends one).
func method(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature),
          let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
    else { return "" }
    return String(source[start.lowerBound..<end.upperBound])
}

func position(of needle: String, in text: String) -> Int? {
    guard let r = text.range(of: needle) else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

/// True when every needle is present and each comes after the one before it.
func inOrder(_ needles: [String], in text: String) -> Bool {
    let positions = needles.map { position(of: $0, in: text) }
    guard positions.allSatisfy({ $0 != nil }) else { return false }
    let ps = positions.map { $0! }
    return zip(ps, ps.dropFirst()).allSatisfy { $0 < $1 }
}

func testChatRepositoryWiring() {
    let source: String
    do {
        source = try chatRepositorySource()
    } catch {
        check(false, "reads ChatRepository source", String(describing: error))
        return
    }

    let retry = method("private func retrySendViaPropNode(", in: source)
    let submit = method("nonisolated private static func submitPropagatedCopy(", in: source)
    check(!retry.isEmpty && !submit.isEmpty, "finds retrySendViaPropNode and submitPropagatedCopy")
    check(inOrder(["ffiQueue.async", "Self.submitPropagatedCopy("], in: retry),
          "the copy is made on ffiQueue, never on the main actor or in the state callback")
    // message_clone_propagated, through DistroMessageFFI's nonisolated
    // wrapper (LxmfClient's statics are main-actor isolated).
    check(submit.contains("DistroMessageFFI.clonePropagated(directHandle)")
            || submit.contains("LxmfClient.messageClonePropagated(directHandle)"),
          "the copy is a clone of the DIRECT message (same hash, keeps attachments)")
    for old in ["createOutboundMessage(", "messageCreate(", "messageAddAttachment("] {
        check(!retry.contains(old) && !submit.contains(old),
              "the copy is no longer built as a new message (\(old))")
    }
    check(inOrder(["lonePropagated(directHandle)", "defer { DistroMessageFFI.destroy(copy) }",
                   "DistroMessageFFI.sendViaAppLinks(copy)"], in: submit),
          "the copy's registry handle is released once submitted")
    check(!retry.contains("pendingOutbound[") && !submit.contains("pendingOutbound["),
          "the copy registers no second pending entry (it would overwrite the DIRECT one)")

    let handle = method("private func handleMessageState(hashHex: String, state: UInt8)", in: source)
    check(inOrder(["GroupChatManager.shared.handleMessageState(", "DistroTransferTracker.shared.handleMessageState(",
                   "distroSentCopies.contains(hashHex)", "pendingOutbound[hashHex]"], in: handle),
          "group, transfer and distro sent-copy states are routed before the pending entry")
    check(inOrder(["if state == 0x08 {", "updateDeliveryState(messageId: hashHex, state: DeliveryState.delivered)",
                   "earlyMessageStates[hashHex, default: []].append(state)"], in: handle),
          "a DELIVERED for a completed message still reaches its row; other early states are buffered")
    for call in ["pending.attempts.sent()", "pending.attempts.delivered()",
                 "pending.attempts.propagationRequested()", "pending.attempts.failed()"] {
        check(handle.contains(call), "handleMessageState drives \(call)")
    }
    check(inOrder(["pendingOutbound[hashHex] = pending", "apply(step, hashHex: hashHex, pending: pending)"],
                  in: handle),
          "the updated attempts are stored before the step is applied")
    check(!handle.isEmpty && !handle.contains("messageDestroy("),
          "a failure never releases the DIRECT handle the copy is cloned from")
    check(!source.contains("hasAttachments"),
          "attachment messages are no longer excluded from the copy")
    check(!source.contains("propFallbackSent"),
          "the copy's bookkeeping lives in the one pending entry")

    let apply = method("private func apply(_ step: OutboundAttempts.Step", in: source)
    check(inOrder(["step.show", "step.startCopy", "retrySendViaPropNode(hashHex: hashHex, directHandle: pending.msgHandle)",
                   "step.complete", "completePending("], in: apply),
          "apply writes the bubble, starts the copy, then completes")

    let complete = method("private func completePending(", in: source)
    check(inOrder(["pendingOutbound.removeValue(forKey: hashHex)", "earlyMessageStates.removeValue(forKey: hashHex)",
                   "LxmfClient.messageDestroy(pending.msgHandle)"], in: complete),
          "completing drops the entry, its buffered states and the DIRECT handle")

    let notStarted = method("private func propagatedCopyNotStarted(", in: source)
    check(notStarted.contains("pending.attempts.copyNotStarted()"),
          "a copy that could not go out counts as an attempt that ended")

    let submitDirect = method("private func submitDirectMessage(", in: source)
    check(submitDirect.contains("attempts: OutboundAttempts(direct: method == directMethod)"),
          "the pending entry starts with the send's own attempt")

    // The other attempt of a completed message still reports under its
    // hash; that is not an early state to keep until stop.
    check(complete.contains("completedHashSet.insert(hashHex)"),
          "completing remembers the hash")
    check(handle.contains("} else if !completedHashSet.contains(hashHex) {"),
          "a completed message's later states are not buffered as early states")

    // A propagating attachment message shows no progress bar: the row still
    // points at the failed DIRECT attempt, whose progress is 0.
    let list = method("func messages(forChatId chatId: String", in: source)
    check(list.contains("&& entity.deliveryState != DeliveryState.propagating"),
          "no progress bar while the copy is propagating")
}

@main
enum OutboundAttemptsTests {
    static func main() {
        testStart()
        testTimerPStartsTheCopyBesideTheDirectAttempt()
        testDirectFailureBeforeAnyCopyStartsIt()
        testCopyFailsWhileDirectLiveKeepsWaiting()
        testDirectFailsAfterCopyStartedKeepsWaitingOnTheCopy()
        testBothFailFailsOnce()
        testSentThenLateDelivered()
        testCopyNotStarted()
        testPropagatedOnlySendHasNoCopy()
        testDeliveredFirstEndsIt()
        testOneCopyWhicheverComesFirst()
        testChatRepositoryWiring()

        if failures.isEmpty {
            print("all outbound-attempt tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
