// HeldSendsTests.swift
//
// Regression tests for sends made while the stack is starting (James,
// 2026-09-24: a message sent while connections are initializing is queued
// until initialization has finished). Before this, sendMessage returned at
// `guard let client = lxmfClient` before the bubble was inserted, so the
// message was lost with no trace; group sends did the same.
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/held-sends \
//     Retichat-ios/Retichat/Services/HeldSends.swift \
//     Retichat-ios/tests/HeldSendsTests.swift && \
//     /private/tmp/claude-501/held-sends
//
// The HeldSends checks drive the pure type. The ChatRepository checks read
// the source, like DirectFallbackBufferTests.swift: ChatRepository needs the
// FFI and SwiftData, so the wiring (where the gate opens, what a held send
// keeps) is asserted on the code itself.

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

// MARK: - HeldSends

func testHeldInOrderAndReleasedOnce() {
    var sends = HeldSends<String>()
    check(!sends.isOpen, "gate starts closed")
    sends.hold("a")
    sends.hold("b")
    sends.hold("c")
    check(sends.count == 3, "holds every send made while closed")

    let released = sends.open()
    check(released == ["a", "b", "c"], "releases held sends oldest first", "got \(released)")
    check(sends.isOpen, "open() opens the gate")
    check(sends.count == 0, "release empties the queue")
    let again = sends.open()
    check(again.isEmpty, "a second open() releases nothing twice", "got \(again)")
}

func testStopKeepsHeldSendsForTheNextStart() {
    var sends = HeldSends<String>()
    // Typed during a start that failed, then Settings → Apply stopped and
    // restarted the stack: nothing opened the gate in between.
    sends.hold("x")
    sends.close()
    sends.hold("y")
    check(sends.open() == ["x", "y"], "sends held across a stop go on the next start, in order")

    sends.close()
    check(!sends.isOpen, "close() closes the gate")
    sends.hold("z")
    check(sends.open() == ["z"], "after a restart only sends held since are released")
}

/// ChatRepository's rule in miniature: hold while closed, otherwise hand
/// straight to the router; the release is the router's first input.
func testSendAfterReleaseGoesBehindHeldSends() {
    var sends = HeldSends<String>()
    var router: [String] = []
    func send(_ m: String) {
        if sends.isOpen { router.append(m) } else { sends.hold(m) }
    }
    send("1")
    send("2")
    router.append(contentsOf: sends.open())
    send("3")
    check(router == ["1", "2", "3"], "a send after startup goes behind those held through it",
          "got \(router)")
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

    let finish = method("private func finishStartService(", in: source)
    for dependency in [
        "self.lxmfClient = client",
        "bridge.wireCallbacks(",
        "ConnectionStateManager.shared.register(lxmfClient: client)",
        "startPropagationPolling()",
        "RfedDistroClient.shared.onStackStarted(client: client)",
        "NetworkMonitor.shared.onConnect = ",
        "importNSEMessages()",
    ] {
        check(inOrder([dependency, "releaseHeldSends()"], in: finish),
              "held sends are released after \(dependency)")
    }

    let polling = method("private func startPropagationPolling()", in: source)
    check(inOrder(["client.setPropagationNode(nodeHash: nodeHash)", "DispatchQueue.main.asyncAfter"],
                  in: polling),
          "the router's propagation node is set at start, not only by the delayed first poll")

    let send = method("func sendMessage(chatId: String", in: source)
    check(!send.contains("ABORT - lxmfClient is nil"),
          "sendMessage no longer drops a message sent before the client exists")
    check(inOrder(["insertMessage(msgEntity, into: ctx)", "guard heldSends.isOpen, let client = lxmfClient",
                   "heldSends.hold(.direct(", "submitDirectMessage("], in: send),
          "sendMessage inserts the pending bubble, then holds or submits")

    let submit = method("private func submitDirectMessage(", in: source)
    check(submit.contains("ffiQueue.async"), "a direct send's FFI work stays on ffiQueue")
    check(!submit.isEmpty && !submit.contains("Task.detached"),
          "a direct send is enqueued on ffiQueue in order, with no detached hop to reorder it")

    let group = method("private func sendGroupMessage(", in: source)
    check(!group.contains("let client = lxmfClient else { return }"),
          "sendGroupMessage no longer drops a message sent before the client exists")
    check(inOrder(["insertMessage(msgEntity, into: ctx)", "heldSends.hold(.group(", "fanOutGroupMessage("],
                  in: group),
          "sendGroupMessage inserts the bubble, then holds or fans out")
    check(group.contains("? DeliveryState.pending"), "a held group send shows pending, not sent")

    let release = method("private func releaseHeldSends()", in: source)
    check(inOrder(["guard let client = lxmfClient", "heldSends.open()"], in: release),
          "the gate opens only once the client exists")
    check(release.contains("submitDirectMessage(") && release.contains("fanOutGroupMessage("),
          "held sends go through the normal send paths")
    // open() hands them back oldest first; the loop must keep that order and
    // send each once (a second submit is a second router send and a second
    // §17.11 sent-copy).
    check(release.contains("for send in sends {") && !release.contains("reversed()"),
          "held sends are released in the order they were held")
    check(release.components(separatedBy: "submitDirectMessage(").count == 2,
          "each held 1:1 send is submitted exactly once")
    check(release.components(separatedBy: "fanOutGroupMessage(").count == 2,
          "each held group send is fanned out exactly once")
    check(!release.isEmpty && !release.contains("MessageEntity("),
          "a released send reuses its bubble and never inserts a second one")

    let stop = method("func stopService()", in: source)
    check(stop.contains("heldSends.close()"), "stopService closes the gate")
    check(!stop.contains("heldSends = ") && !stop.contains("heldSends.open()"),
          "stopService keeps held sends for the next start")
}

@main
enum HeldSendsTests {
    static func main() {
        testHeldInOrderAndReleasedOnce()
        testStopKeepsHeldSendsForTheNextStart()
        testSendAfterReleaseGoesBehindHeldSends()
        testChatRepositoryWiring()

        if failures.isEmpty {
            print("all held-send tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
