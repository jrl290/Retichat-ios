// NSEDeliveryHandOffTests.swift
//
// Regression tests for the NSE keeping every message of a run (U2 in
// CONNECTIVITY_READINESS.md, 2026-09-25). The sync an NSE run starts
// acknowledges every fetched message to the propagation node, which deletes
// them, but the NSE kept only the first delivery ("ignoring extra
// delivery"): with two or more messages waiting and the app not running,
// messages 2..N were gone for good.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/nse-hand-off \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/tests/NSEDeliveryHandOffTests.swift && \
//     /private/tmp/claude-501/nse-hand-off
//
// The NSERun checks drive the real type against a scratch directory (never
// the App Group container) and read back with readAndClearNSEMessages(in:),
// the function the app's importNSEMessages uses. The append checks cover
// what the NSE can afford: an append costs one message, not the file
// (measured as phys_footprint, what jetsam counts), and never leaves a
// partial file for the app to read. The NotificationService checks read
// the source, like HeldSendsTests.swift: the extension needs UIKit and the
// FFI, so its wiring is asserted on the code itself. The concurrency
// checks are probabilistic, but each caught the mutation it guards against
// on every run tried (2026-09-25).

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

typealias NSEMessage = PendingNotification.NSEMessage

func message(_ n: Int, timestamp: Double, content: String? = nil) -> NSEMessage {
    NSEMessage(messageHash: String(format: "%032x", n),
               senderHash: String(format: "%032x", 0xa000 + n),
               destHash: String(repeating: "d", count: 32),
               title: "sender \(n)",
               content: content ?? "message \(n)",
               timestamp: timestamp,
               signatureValid: true,
               fieldsRawBase64: "")
}

func scratchDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nse-hand-off-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func run(in dir: URL, prepare: @escaping (NSEMessage) -> NSEMessage? = { $0 }) -> PendingNotification.NSERun {
    PendingNotification.NSERun(prepare: prepare,
                               store: { PendingNotification.appendNSEMessage($0, in: dir) })
}

// Three messages waiting, one NSE run: all three reach the app.
func testThreeDeliveriesAreAllStored() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Delivery order is the node's, not time order: the newest is the second.
    let first = message(1, timestamp: 1_000)
    let second = message(2, timestamp: 3_000)
    let third = message(3, timestamp: 2_000)
    let nse = run(in: dir)
    for m in [first, second, third] { nse.deliver(m) }

    let summary = nse.summary()
    check(summary.newest?.messageHash == second.messageHash,
          "the notification shows the newest message, not the first delivered",
          "showed \(summary.newest?.content ?? "nothing")")
    check(summary.others == 2, "the notification counts the other two", "others=\(summary.others)")
    check(summary.body == "message 2\n+2 more", "the body is the newest text then +2 more",
          "body=\(summary.body.debugDescription)")

    let imported = PendingNotification.readAndClearNSEMessages(in: dir)
    check(imported.count == 3, "three deliveries give three stored messages", "stored \(imported.count)")
    check(imported.map(\.messageHash) == [first, second, third].map(\.messageHash),
          "each stored message keeps its hash, for the app's dedupe")
    check(PendingNotification.readAndClearNSEMessages(in: dir).isEmpty,
          "the import clears the hand-off")
}

// Each delivery is on disk when deliver returns: the router acknowledges the
// run's messages to the node only after the last delivery callback returns.
func testEachDeliveryIsStoredBeforeDeliverReturns() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nse = run(in: dir)

    var onDisk: [Int] = []
    for n in 1...3 {
        nse.deliver(message(n, timestamp: Double(n)))
        let data = try? Data(contentsOf: dir.appendingPathComponent("nse_messages.json"))
        let stored = data.flatMap { try? JSONDecoder().decode([NSEMessage].self, from: $0) } ?? []
        onDisk.append(stored.count)
    }
    check(onDisk == [1, 2, 3], "each delivery is written before deliver returns", "counts \(onDisk)")
}

func testOneDeliveryShowsNoCount() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nse = run(in: dir)
    nse.deliver(message(1, timestamp: 1))
    let summary = nse.summary()
    check(summary.others == 0 && summary.body == "message 1", "one message: its text alone, no count",
          "body=\(summary.body.debugDescription)")

    let empty = run(in: dir)
    empty.deliver(message(2, timestamp: 2, content: ""))
    empty.deliver(message(3, timestamp: 1, content: "older"))
    check(empty.summary().body == "+1 more", "an empty newest text shows the count alone",
          "body=\(empty.summary().body.debugDescription)")
}

// A run adds to what earlier runs left for the app; it never replaces it.
func testARunKeepsEarlierRunsMessages() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    run(in: dir).deliver(message(1, timestamp: 1))
    let later = run(in: dir)
    for n in 2...4 { later.deliver(message(n, timestamp: Double(n))) }
    check(later.summary().others == 2, "the count is this run's, not the file's")
    check(PendingNotification.readAndClearNSEMessages(in: dir).count == 4,
          "an earlier run's message is kept alongside this run's three")
}

// A delivery the NSE does not store (a distro sent copy) is not counted.
func testUnstoredDeliveriesAreNotCounted() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dropSecond: (NSEMessage) -> NSEMessage? = { $0.messageHash == String(format: "%032x", 2) ? nil : $0 }
    let nse = run(in: dir, prepare: dropSecond)
    for n in 1...3 { nse.deliver(message(n, timestamp: Double(n))) }
    let summary = nse.summary()
    check(summary.newest?.messageHash == String(format: "%032x", 3) && summary.others == 1
            && summary.dropped == 1,
          "a dropped delivery is neither shown nor counted",
          "newest=\(summary.newest?.content ?? "-") others=\(summary.others) dropped=\(summary.dropped)")
    check(PendingNotification.readAndClearNSEMessages(in: dir).count == 2,
          "a dropped delivery is not stored")

    let onlyDropped = run(in: dir, prepare: { _ in nil })
    onlyDropped.deliver(message(5, timestamp: 5))
    let s = onlyDropped.summary()
    check(s.newest == nil && s.dropped == 1, "only dropped deliveries leave nothing to show")
}

// Stored form: what prepare returns is what the app imports (the distro
// transfer key is stripped before the file is written).
func testTheStoredFormIsThePreparedOne() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nse = run(in: dir, prepare: { $0.strippedForDistroTransfer(.keychain) })
    nse.deliver(NSEMessage(messageHash: "aa", senderHash: "bb", destHash: "cc", title: "",
                           content: "transfer", timestamp: 1, signatureValid: true,
                           fieldsRawBase64: "c2VjcmV0"))
    let imported = PendingNotification.readAndClearNSEMessages(in: dir)
    check(imported.count == 1 && imported[0].fieldsRawBase64.isEmpty
            && imported[0].distroTransfer == .keychain,
          "the prepared (stripped) form is stored, not the raw delivery")
}

// Deliveries from several threads at once are all kept.
func testConcurrentDeliveriesAreAllStored() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nse = run(in: dir)
    DispatchQueue.concurrentPerform(iterations: 40) { n in
        nse.deliver(message(n, timestamp: Double(n)))
    }
    let imported = PendingNotification.readAndClearNSEMessages(in: dir)
    check(Set(imported.map(\.messageHash)).count == 40 && nse.summary().others == 39,
          "40 concurrent deliveries give 40 stored messages",
          "stored \(imported.count), others \(nse.summary().others)")

    // The run's own counts, with no file I/O to serialise the deliveries:
    // they are what the notification's "+N more" says.
    let counts = PendingNotification.NSERun(prepare: { $0.content == "drop" ? nil : $0 },
                                            store: { $0.content != "fail" })
    DispatchQueue.concurrentPerform(iterations: 30_000) { n in
        counts.deliver(message(n, timestamp: Double(n), content: ["keep", "drop", "fail"][n % 3]))
    }
    let s = counts.summary()
    check(s.others == 9_999 && s.dropped == 10_000 && s.failed == 10_000,
          "the run's counts are exact under concurrent deliveries",
          "others=\(s.others) dropped=\(s.dropped) failed=\(s.failed)")
    // Drops alone: the shortest path through deliver, so the most contended.
    let drops = PendingNotification.NSERun(prepare: { _ in nil }, store: { _ in true })
    let one = message(1, timestamp: 1)
    DispatchQueue.concurrentPerform(iterations: 200_000) { _ in drops.deliver(one) }
    check(drops.summary().dropped == 200_000, "the dropped count is exact under concurrent deliveries",
          "dropped=\(drops.summary().dropped)")
}

// Two runs in one process (iOS can run two NSE requests at once, and the
// second reset() replaces the first's run while its delivery is still
// writing): the file's lock is per process, so neither run's write is lost.
func testTwoRunsInOneProcessKeepEveryWrite() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = run(in: dir)
    let new = run(in: dir)
    DispatchQueue.concurrentPerform(iterations: 60) { n in
        (n.isMultiple(of: 2) ? old : new).deliver(message(n, timestamp: Double(n)))
    }
    let imported = PendingNotification.readAndClearNSEMessages(in: dir)
    check(Set(imported.map(\.messageHash)).count == 60,
          "two runs writing at once keep all 60 messages", "stored \(imported.count)")
}

// A write that fails is not in the file, so the app will never import it:
// the notification must not show it or count it in "+N more".
func testAFailedWriteIsNeitherShownNorCounted() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // The second delivery is the newest, and its write fails.
    let failSecond = PendingNotification.NSERun(prepare: { $0 }, store: { m in
        m.messageHash == String(format: "%032x", 2) ? false : PendingNotification.appendNSEMessage(m, in: dir)
    })
    failSecond.deliver(message(1, timestamp: 1))
    failSecond.deliver(message(2, timestamp: 9))
    failSecond.deliver(message(3, timestamp: 2))
    let summary = failSecond.summary()
    check(summary.newest?.messageHash == String(format: "%032x", 3) && summary.others == 1
            && summary.failed == 1 && summary.body == "message 3\n+1 more",
          "a failed write is neither shown nor counted, but is reported",
          "newest=\(summary.newest?.content ?? "-") others=\(summary.others) failed=\(summary.failed)")
    check(PendingNotification.readAndClearNSEMessages(in: dir).count == 2,
          "only the written messages reach the import")

    // The real write, into a directory that does not exist.
    let missing = dir.appendingPathComponent("not-there")
    check(!PendingNotification.appendNSEMessage(message(4, timestamp: 4), in: missing),
          "appendNSEMessage reports a failed write")
    let allFail = PendingNotification.NSERun(prepare: { $0 }, store: {
        PendingNotification.appendNSEMessage($0, in: missing)
    })
    allFail.deliver(message(5, timestamp: 5))
    let s = allFail.summary()
    check(s.newest == nil && s.others == 0 && s.failed == 1,
          "a run whose writes all fail has nothing to show and reports the failure",
          "newest=\(s.newest?.content ?? "-") failed=\(s.failed)")
}

// An append adds one entry to the file; it does not decode and re-encode
// what is already there (that peaked at six to eight times the file's size
// on every delivery, past the NSE's memory limit with a few attachments).
func testAnAppendLeavesTheExistingEntriesAlone() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("nse_messages.json")
    // Bytes JSONEncoder's defaults would not write (sorted keys, "/" not
    // escaped) but that decode the same: a re-encode would change them.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let earlier = try! encoder.encode([message(1, timestamp: 1, content: "a/b")])
    try! earlier.write(to: file)

    check(PendingNotification.appendNSEMessage(message(2, timestamp: 2), in: dir), "the append succeeds")
    let raw = (try? Data(contentsOf: file)) ?? Data()
    check(raw.starts(with: earlier.dropLast()), "the existing entries' bytes are untouched")
    let imported = PendingNotification.readAndClearNSEMessages(in: dir)
    check(imported.map(\.content) == ["a/b", "message 2"], "the extended file decodes to both, in order",
          "\(imported.map(\.content))")

    // The append no longer decodes the file, so an entry that does not
    // decode stays in it: the import must lose only that entry.
    try! Data(#"[{"not":"a message"}]"#.utf8).write(to: file)
    PendingNotification.appendNSEMessage(message(4, timestamp: 4), in: dir)
    check(PendingNotification.readAndClearNSEMessages(in: dir).map(\.content) == ["message 4"],
          "an entry that does not decode loses only itself")

    // A file the append cannot extend in place is written whole.
    try! Data("[]".utf8).write(to: file)
    check(PendingNotification.appendNSEMessage(message(3, timestamp: 3), in: dir)
            && PendingNotification.readAndClearNSEMessages(in: dir).map(\.content) == ["message 3"],
          "an empty array is replaced by the message")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["?"]
    check(leftovers.isEmpty, "the append leaves no working copy behind", "\(leftovers)")
}

// The app reads the file from its own process, without the NSE's lock, so an
// append must never leave a partly written file for it to read.
func testAReaderNeverSeesAPartialFile() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("nse_messages.json")
    let big = String(repeating: "B", count: 500_000)
    PendingNotification.appendNSEMessage(message(0, timestamp: 0, content: big), in: dir)

    final class Reads: @unchecked Sendable {
        let lock = NSLock(); var whole = 0; var partial = 0; var stop = false
        let done = DispatchSemaphore(value: 0)
    }
    let reads = Reads()
    let reader = Thread {
        while true {
            reads.lock.lock(); let stop = reads.stop; reads.lock.unlock()
            if stop { reads.done.signal(); return }
            // An append works at the end of the file, so its last byte is
            // where a partial write shows; reading only that keeps this loop
            // fast enough to land inside one.
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let end = (try? handle.seekToEnd()) ?? 0
            let last = end > 0 ? (try? handle.seek(toOffset: end - 1)).flatMap { try? handle.read(upToCount: 1) } : nil
            try? handle.close()
            guard let last else { continue }
            reads.lock.lock()
            if last == Data("]".utf8) { reads.whole += 1 } else { reads.partial += 1 }
            reads.lock.unlock()
        }
    }
    reader.start()
    for n in 1...20 {
        PendingNotification.appendNSEMessage(message(n, timestamp: Double(n), content: big), in: dir)
    }
    reads.lock.lock(); reads.stop = true; reads.lock.unlock()
    reads.done.wait()
    check(reads.partial == 0 && reads.whole > 0, "a reader in another process only ever sees a whole file",
          "\(reads.whole) whole, \(reads.partial) partial")
    check(PendingNotification.readAndClearNSEMessages(in: dir).count == 21, "all 21 appends are in the file")
}

func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

// What jetsam counts (phys_footprint) while one small message is appended
// to a 16 MB hand-off file: the append costs the message, not the file.
func testAnAppendCostsTheMessageNotTheFile() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let big = String(repeating: "A", count: 1_000_000)
    let earlier = (0..<16).map { message($0, timestamp: Double($0), content: big) }
    try! JSONEncoder().encode(earlier).write(to: dir.appendingPathComponent("nse_messages.json"))

    final class Peak: @unchecked Sendable {
        let lock = NSLock(); var value = 0; var stop = false
    }
    let peak = Peak()
    let before = physFootprint()
    let sampler = Thread {
        while true {
            let now = physFootprint()
            peak.lock.lock()
            peak.value = max(peak.value, now)
            let stop = peak.stop
            peak.lock.unlock()
            if stop { return }
            usleep(100)
        }
    }
    sampler.start()
    let ok = PendingNotification.appendNSEMessage(message(99, timestamp: 99), in: dir)
    peak.lock.lock(); peak.stop = true; let grew = max(peak.value - before, 0); peak.lock.unlock()
    usleep(10_000)
    check(ok && grew < 4_000_000, "appending to a 16 MB file does not load it into memory",
          "footprint grew \(grew / 1_000_000) MB")
}

// MARK: - NotificationService wiring (source)

func sourceFile(_ components: [String]) throws -> String {
    let url = components.reduce(
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    ) { $0.appendingPathComponent($1) }
    return try String(contentsOf: url, encoding: .utf8)
}

/// A top-level function's text: from its signature to its closing brace.
/// `indent` is the closing brace's indentation, for a method.
func function(_ signature: String, in source: String, indent: String = "") -> String {
    guard let start = source.range(of: signature) else { return "" }
    guard let end = source.range(of: "\n\(indent)}\n", range: start.upperBound..<source.endIndex) else {
        return String(source[start.lowerBound...])
    }
    return String(source[start.lowerBound..<end.upperBound])
}

/// The text from `from` up to (not including) the next `to`.
func span(from: String, to: String, in source: String) -> String {
    guard let start = source.range(of: from) else { return "" }
    let end = source.range(of: to, range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
    return String(source[start.lowerBound..<end])
}

func occurrences(_ needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

func testNotificationServiceWiring() {
    let source: String
    do {
        source = try sourceFile(["NotificationService", "NotificationService.swift"])
    } catch {
        check(false, "reads NotificationService source", String(describing: error))
        return
    }

    let delivery = function("private func nseDeliveryTrampoline(", in: source)
    check(!delivery.isEmpty, "finds the delivery trampoline")
    check(delivery.contains("NSEDelivery.run.deliver("),
          "the delivery callback hands every delivery to the run")
    check(!delivery.contains("return\n") && !delivery.contains("guard "),
          "the delivery callback has no early exit that could skip a delivery")
    check(!source.contains("ignoring extra delivery") && !source.contains("NSEDelivery.delivered"),
          "no 'first delivery only' rule remains")
    check(!delivery.contains("semaphore.signal()"),
          "a delivery does not wake the NSE: more may follow in the same run")

    let syncComplete = function("private func nseSyncCompleteTrampoline(", in: source)
    check(syncComplete.contains("NSEDelivery.semaphore.signal()")
            && !syncComplete.contains("if "),
          "sync-complete always wakes the NSE (the router raises it after the last delivery)")

    check(source.contains("let summary = NSEDelivery.run.summary()")
            && source.contains("best.body  = summary.body"),
          "the notification is built from the run's summary")
    check(!source.contains("PendingNotification.appendNSEMessage("),
          "the NSE stores only through the run, at delivery")

    // Every run stores through nseHandOffForm. With `prepare: { $0 }` a
    // distro transfer's private key would be written in plain text to the
    // container file, which goes into device backups.
    check(occurrences("NSERun(", in: source) == 1
            && source.contains("PendingNotification.NSERun(prepare: nseHandOffForm)")
            && source.contains("static var run = newRun()")
            && function("    static func reset() {", in: source, indent: "    ").contains("run = newRun()"),
          "every NSE run is built with nseHandOffForm")
    let handOff = function("private func nseHandOffForm(", in: source)
    let sentCopy = span(from: "if fields.isDistroSentCopy {", to: "\n    }\n", in: handOff)
    check(sentCopy.contains("return nil") && !sentCopy.contains("return msg"),
          "nseHandOffForm drops a distro sent copy")
    // After the transfer-key guard, every return is a stripped form.
    let afterKey = span(from: "let status = PendingNotification.stashDistroTransferKey(key, messageHash: msg.messageHash)",
                        to: "\n}\n", in: handOff)
    check(handOff.contains("guard let key = fields.distroTransferKey else { return msg }\n    let status =")
            && afterKey.contains("return msg.strippedForDistroTransfer(.keychain)")
            && afterKey.contains("return msg.strippedForDistroTransfer(.lost)")
            && occurrences("return ", in: afterKey) == 2,
          "nseHandOffForm moves a transfer key to the Keychain and stores the message without its fields",
          afterKey.isEmpty ? "transfer branch not found" : "")

    // A write that failed is not "0 new": the NSE shows the original alert
    // rather than suppress it.
    let failedBranch = span(from: "} else if summary.failed > 0 {", to: "} else if", in: source)
    check(!failedBranch.isEmpty && !failedBranch.contains("best.sound = nil")
            && !failedBranch.contains("best.body  = \"\""),
          "messages that could not be written are not suppressed")
    let suppress = source.range(of: "} else if NSEDelivery.syncComplete {")
    let failed = source.range(of: "} else if summary.failed > 0 {")
    check(failed != nil && suppress != nil && failed!.lowerBound < suppress!.lowerBound,
          "the failed-write branch comes before the '0 new' suppression")

    // With no sync started, sync-complete can never come: no wait for it.
    let request = function("    private func requestPropagation() -> Bool {", in: source, indent: "    ")
    check(request.contains("if client.sync(nodeHash: data) {") && occurrences("return true", in: request) == 1
            && request.hasSuffix("return false\n    }\n"),
          "requestPropagation says whether a sync started")
    let waitIfStarted = span(from: "if syncStarted {", to: "} else {", in: source)
    check(source.contains("let syncStarted = requestPropagation()")
            && waitIfStarted.contains("NSEDelivery.semaphore.wait(")
            && occurrences("NSEDelivery.semaphore.wait(", in: source) == 1,
          "the NSE waits for sync-complete only when a sync started")
}

@main
enum NSEDeliveryHandOffTests {
    static func main() {
        testThreeDeliveriesAreAllStored()
        testEachDeliveryIsStoredBeforeDeliverReturns()
        testOneDeliveryShowsNoCount()
        testARunKeepsEarlierRunsMessages()
        testUnstoredDeliveriesAreNotCounted()
        testTheStoredFormIsThePreparedOne()
        testConcurrentDeliveriesAreAllStored()
        testTwoRunsInOneProcessKeepEveryWrite()
        testAFailedWriteIsNeitherShownNorCounted()
        testAnAppendLeavesTheExistingEntriesAlone()
        testAnAppendCostsTheMessageNotTheFile()
        testAReaderNeverSeesAPartialFile()
        testNotificationServiceWiring()

        if failures.isEmpty {
            print("all NSE hand-off tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
