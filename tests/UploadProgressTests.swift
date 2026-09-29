// UploadProgressTests.swift
//
// The progress bar of an outgoing attachment (device round 2026-09-29: an
// iPad photo, ~650 KB in 1708 parts over a Nearby RTNode Bluetooth link,
// about 4 minutes, showed no bar). Three things hid or froze it:
//
//   - Since dc6c9d8 (2026-09-24) a row the propagated copy made
//     `propagating` showed no bar, on the reasoning that its DIRECT attempt
//     had failed. AppLinks Timer P started that copy 5 s in, while the
//     DIRECT Resource was still moving, so the bar went for the whole
//     transfer.
//   - The bar was read only on a structural reload (a row added, an id or a
//     state changed), so it never moved between reloads; and it was read on
//     the main actor, through a call that takes the message's lock (§6).
//   - The core never moved the value on the AppLinks path: 0.05 throughout
//     (fixed in LXMF-rust 4125139, app-links 07bea51).
//
// The bar now follows the DIRECT attempt's own state: shown while it is
// SENDING, whatever the bubble shows, read off the main actor on every 3 s
// tick, and assigned only when it changed.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/upload-progress \
//     Retichat-ios/Retichat/Services/UploadProgress.swift \
//     Retichat-ios/Retichat/Services/OutboundAttempts.swift \
//     Retichat-ios/tests/UploadProgressTests.swift && \
//     /private/tmp/claude-501/upload-progress
//
// The UploadProgress checks drive the pure type, with OutboundAttempts for
// the 0x10 scenario (ChatRepository keeps a message's pending entry, which
// is what makes a row live, until OutboundAttempts says complete).
// ChatRepository and ConversationViewModel need the FFI, SwiftData and
// SwiftUI, so their wiring is asserted on the source, like
// OutboundAttemptsTests.swift.

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

// LXMessage states (LXMF-rust lx_message.rs, LXMF/LXMessage.py).
let generating: Int32 = 0x00
let outbound: Int32 = 0x01
let sending: Int32 = 0x02
let sent: Int32 = 0x04
let delivered: Int32 = 0x08
let failed: Int32 = 0xFF
/// What lxmf_message_state / lxmf_message_progress return for a handle the
/// registry no longer holds.
let unknownState: Int32 = -1
let unknownProgress: Float = -1.0

typealias Change = (index: Int, bar: Float?)

func same(_ a: [Change], _ b: [Change]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.index == $1.index && $0.bar == $1.bar }
}

func describe(_ changes: [Change]) -> String {
    "[" + changes.map { "(\($0.index), \($0.bar.map { String($0) } ?? "nil"))" }.joined(separator: ", ") + "]"
}

// MARK: - The bar follows the DIRECT attempt's own state

func testBarFollowsTheAttemptsOwnState() {
    check(UploadProgress.sending == sending, "SENDING is 0x02, as the core has it")
    check(UploadProgress.bar(state: sending, progress: 0.42) == 0.42,
          "a SENDING attempt shows its progress")
    check(UploadProgress.bar(state: sending, progress: 0.05) == 0.05,
          "a send that has just started shows the router's 0.05")
    check(UploadProgress.bar(state: sending, progress: 0.10 + 0.90 * 0.5) == 0.10 + 0.90 * 0.5,
          "the reference's 0.10 + 0.90 × fraction passes through as it is")
    check(UploadProgress.bar(state: sending, progress: 1.0) == nil,
          "a transfer at 1.0 shows no bar")
    check(UploadProgress.bar(state: sending, progress: -1.0) == nil,
          "a negative progress shows no bar")
    check(UploadProgress.bar(state: failed, progress: 0.0) == nil,
          "a FAILED attempt shows no bar (the router resets it to 0)")
    check(UploadProgress.bar(state: failed, progress: 0.55) == nil,
          "a FAILED attempt shows no bar whatever its progress says")
    check(UploadProgress.bar(state: outbound, progress: 0.55) == nil,
          "an OUTBOUND attempt (not started, or on its way to FAILED) shows no bar")
    check(UploadProgress.bar(state: generating, progress: 0.0) == nil,
          "a GENERATING attempt shows no bar")
    check(UploadProgress.bar(state: sent, progress: 0.5) == nil
            && UploadProgress.bar(state: delivered, progress: 0.99) == nil,
          "a SENT or DELIVERED attempt shows no bar")
    check(UploadProgress.bar(state: unknownState, progress: unknownProgress) == nil,
          "a handle the registry no longer holds shows no bar")
}

// MARK: - Which rows are read

func testLiveRows() {
    check(UploadProgress.isLive(isOutgoing: true, withAttachments: true, nativeHandle: 7, pendingHandle: 7),
          "an outgoing attachment whose pending entry holds its handle is read")
    check(!UploadProgress.isLive(isOutgoing: false, withAttachments: true, nativeHandle: 7, pendingHandle: 7),
          "an incoming message is not read")
    check(!UploadProgress.isLive(isOutgoing: true, withAttachments: false, nativeHandle: 7, pendingHandle: 7),
          "a message without attachments is not read")
    check(!UploadProgress.isLive(isOutgoing: true, withAttachments: true, nativeHandle: 0, pendingHandle: nil),
          "a send not yet submitted (held, or the pending_ bubble) is not read")
    check(!UploadProgress.isLive(isOutgoing: true, withAttachments: true, nativeHandle: 7, pendingHandle: nil),
          "a completed message, or a row from an earlier run, is not read")
    check(!UploadProgress.isLive(isOutgoing: true, withAttachments: true, nativeHandle: 7, pendingHandle: 9),
          "a row whose handle is not its pending entry's is not read")
}

// MARK: - 0x10 while the DIRECT Resource moves (the device round)

func testPropagatingRowKeepsTheDirectAttemptsBar() {
    let handle: UInt64 = 7
    var attempts = OutboundAttempts(direct: true)

    // Timer P: 0x10 PROP_FALLBACK_REQUESTED. The bubble says propagating,
    // the copy starts, and the message is not complete, so ChatRepository
    // keeps its pending entry (and the DIRECT handle in it).
    let step = attempts.propagationRequested()
    check(step.show == .propagating && step.startCopy && !step.complete,
          "0x10 shows propagating and starts the copy, and the message stays pending", "got \(step)")
    let pendingHandle: UInt64? = step.complete ? nil : handle
    check(UploadProgress.isLive(isOutgoing: true, withAttachments: true, nativeHandle: handle,
                                pendingHandle: pendingHandle),
          "the propagating row is still read")
    check(UploadProgress.bar(state: sending, progress: 0.42) == 0.42,
          "the propagating row shows its DIRECT attempt's 42 % (was: no bar)")

    // The bar moves on each tick while the Resource does.
    var rows: [(id: String, bar: Float?)] = [(id: "m", bar: nil)]
    var shown: [Float] = []
    for progress: Float in [0.10, 0.28, 0.28, 0.61, 0.97] {
        let reading = UploadProgress.bar(state: sending, progress: progress)
        let changes = UploadProgress.changes(rows: rows, live: ["m"], read: ["m": reading])
        for change in changes {
            rows[change.index].bar = change.bar
            if let bar = change.bar { shown.append(bar) }
        }
    }
    check(shown == [0.10, 0.28, 0.61, 0.97],
          "each tick's reading moves the bar, and an unchanged one assigns nothing", "shown \(shown)")

    // The DIRECT attempt delivers: the message completes, its entry goes,
    // and the row is no longer read; a reading taken just before is stale.
    let done = attempts.delivered()
    check(done.complete, "DELIVERED completes the message")
    let cleared = UploadProgress.changes(rows: rows, live: [], read: ["m": 0.99])
    check(same(cleared, [(0, nil)]), "the delivered row loses its bar, whatever an older reading said",
          describe(cleared))

    // The other way into propagating: the DIRECT attempt failed first. The
    // entry stays for the copy, but the attempt is FAILED: no bar — the
    // case the old `!= .propagating` guard was written for.
    var b = OutboundAttempts(direct: true)
    let afterFailure = b.failed()
    check(afterFailure.show == .propagating && !afterFailure.complete,
          "a DIRECT failure shows propagating and keeps the entry for the copy")
    check(UploadProgress.bar(state: failed, progress: 0.0) == nil,
          "propagating after a DIRECT failure shows no bar")
}

// MARK: - A reading applied to the list

func testChanges() {
    let rows: [(id: String, bar: Float?)] = [
        (id: "a", bar: nil), (id: "b", bar: 0.2), (id: "c", bar: 0.5), (id: "d", bar: nil),
    ]
    let none: Float? = nil
    let changes = UploadProgress.changes(rows: rows, live: ["a", "b", "c"],
                                         read: ["a": 0.15, "b": 0.2, "c": none])
    check(same(changes, [(0, 0.15), (2, nil)]),
          "a live row takes its reading, an unchanged bar is left out, a reading of none clears it",
          describe(changes))

    let kept = UploadProgress.changes(rows: [(id: "e", bar: 0.3)], live: ["e"], read: [:])
    check(kept.isEmpty, "a live row the reading predates keeps its bar", describe(kept))

    let gone = UploadProgress.changes(rows: [(id: "f", bar: 0.3), (id: "g", bar: nil)], live: [], read: [:])
    check(same(gone, [(0, nil)]), "with nothing live, every bar left is cleared", describe(gone))

    let stale = UploadProgress.changes(rows: [(id: "h", bar: 0.3)], live: [], read: ["h": 0.6])
    check(same(stale, [(0, nil)]), "a reading for a row no longer live is not applied", describe(stale))
}

func testCarried() {
    let old: [(id: String, bar: Float?)] = [(id: "x", bar: 0.4), (id: "y", bar: nil)]
    let kept = UploadProgress.carried(from: old, to: ["w", "x", "y"])
    check(kept == [nil, 0.4, nil], "a full reload keeps each id's bar, and a new row starts without one",
          "got \(kept)")
    check(UploadProgress.carried(from: [(id: "pending_1", bar: nil)], to: ["abcd"]) == [nil],
          "the renamed pending_ bubble starts without a bar")
}

// MARK: - Wiring (source)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// The member from its signature to its closing brace (members sit at four
/// spaces in both files, so the first "\n    }\n" ends one).
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

func containsWord(_ word: String, in text: String) -> Bool {
    text.range(of: "\\b\(word)\\b", options: .regularExpression) != nil
}

func testChatRepositoryWiring() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(!repo.isEmpty, "reads ChatRepository source")

    let list = method("func messages(forChatId chatId: String", in: repo)
    check(!list.isEmpty, "finds messages(forChatId:)")
    check(!list.contains("DeliveryState.propagating"),
          "a propagating row is no longer denied its bar")
    check(!list.contains("LxmfClient.messageProgress(") && !list.contains("LxmfClient.messageState("),
          "messages() reads no FFI on the main actor")
    check(list.contains("uploadProgress: nil"), "messages() builds rows without bars")
    check(!repo.contains("LxmfClient.messageProgress("), "nothing reads progress through LxmfClient's main-actor static")

    let live = method("func liveUploads(in rows: [ChatMessage])", in: repo)
    check(live.contains("UploadProgress.isLive(") && live.contains("pendingHandle: pendingOutbound[row.id]?.msgHandle"),
          "a row is live when its pending entry holds its handle")

    let bars = method("func uploadBars(for live: [(id: String, handle: UInt64)]) async", in: repo)
    check(inOrder(["ffiQueue.async", "Self.readUploadBars(live)"], in: bars),
          "the bars are read on ffiQueue")

    let read = method("nonisolated private static func readUploadBars(", in: repo)
    check(inOrder(["UploadProgress.bar(state: DistroMessageFFI.state(upload.handle)",
                   "progress: DistroMessageFFI.progress(upload.handle)"], in: read),
          "each bar is the DIRECT attempt's own (state, progress) through the nonisolated wrappers")
    check(!read.isEmpty && !read.contains("LxmfClient."), "the ffiQueue read uses no main-actor static")

    let ffi = source("Retichat/Services/RfedDistroClient.swift")
    // The enum sits at the top level, so the first "\n}\n" ends it.
    var wrappers = ""
    if let start = ffi.range(of: "nonisolated enum DistroMessageFFI {"),
       let end = ffi.range(of: "\n}\n", range: start.upperBound..<ffi.endIndex) {
        wrappers = String(ffi[start.lowerBound..<end.upperBound])
    }
    check(wrappers.contains("static func state(_ h: UInt64) -> Int32 {\n        lxmf_message_state(h)"),
          "DistroMessageFFI.state wraps lxmf_message_state")
    check(wrappers.contains("static func progress(_ h: UInt64) -> Float {\n        lxmf_message_progress(h)"),
          "DistroMessageFFI.progress wraps lxmf_message_progress")
}

func testConversationViewModelWiring() {
    let vm = source("Retichat/Views/Conversation/ConversationViewModel.swift")
    check(!vm.isEmpty, "reads ConversationViewModel source")

    let refresh = method("func refreshMessages(", in: vm)
    check(!refresh.isEmpty, "finds refreshMessages")
    check(!refresh.contains("guard changed else { return }"),
          "a tick with nothing structural changed does not return before the bars")
    if let call = refresh.range(of: "refreshUploadProgress(repository: repository)") {
        check(!containsWord("return", in: String(refresh[..<call.lowerBound])),
              "nothing returns ahead of the bar reading on any tick")
    } else {
        check(false, "refreshMessages reads the bars")
    }
    check(inOrder(["if changed {", "UploadProgress.carried(", "full[index].uploadProgress = kept[index]",
                   "messages = full", "refreshUploadProgress(repository: repository)"], in: refresh),
          "a structural reload keeps the bars, then the tick reads them")
    // The reading sits after the structural block (closed at eight spaces),
    // not inside it: a tick with nothing structural changed reads too.
    if let block = refresh.range(of: "if changed {"),
       let blockEnd = refresh.range(of: "\n        }\n", range: block.upperBound..<refresh.endIndex),
       let call = refresh.range(of: "refreshUploadProgress(repository: repository)") {
        check(call.lowerBound > blockEnd.lowerBound
                && refresh.range(of: "refreshUploadProgress(", range: block.upperBound..<blockEnd.lowerBound) == nil,
              "the bars are read on every tick, outside the structural reload")
    } else {
        check(false, "the bars are read on every tick, outside the structural reload",
              "no `if changed {` block, or no reading")
    }

    check(inOrder(["messages = page", "refreshUploadProgress(repository: repository)"],
                  in: method("func loadChat(", in: vm)),
          "opening the chat reads the bars")

    let reader = method("private func refreshUploadProgress(", in: vm)
    check(inOrder(["repository.liveUploads(in: messages)", "guard !readingUploadBars", "readingUploadBars = true",
                   "await repository.uploadBars(for: live)", "readingUploadBars = false",
                   "applyUploadBars(read"], in: reader),
          "one reading at a time, off the main actor, then applied")

    let apply = method("private func applyUploadBars(", in: vm)
    check(inOrder(["repository.liveUploads(in: messages)", "UploadProgress.changes(",
                   "messages[change.index].uploadProgress = change.bar"], in: apply),
          "only the bars that changed are assigned, against the rows live now")
    check(!apply.contains("messages = "), "applying a reading never replaces the list")
    check(!vm.contains("LxmfClient."), "the view model calls no FFI")
}

@main
enum UploadProgressTests {
    static func main() {
        testBarFollowsTheAttemptsOwnState()
        testLiveRows()
        testPropagatingRowKeepsTheDirectAttemptsBar()
        testChanges()
        testCarried()
        testChatRepositoryWiring()
        testConversationViewModelWiring()

        if failures.isEmpty {
            print("all upload-progress tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
