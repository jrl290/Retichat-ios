// RNodeSlotRulesTests.swift
//
// A saved RNode whose link the coordinator drops after a failure stays red
// and keeps the retry the failure chose (found 2026-10-22 while porting the
// coordinator to Android; James: "Do this task here"). Until then
// cancelPeripheralConnection led to didDisconnectPeripheral with no error,
// and handleDisconnect showed .idle (grey, so the red barely showed) and
// rescheduled with the short backoff, which cancelled the 60 s retry a
// refused subscription (an unpaired radio) had just set: the comment says
// "Don't keep hammering BLE — back off hard".
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/rnode-slot-rules \
//     Retichat-ios/Retichat/Services/RNodeSlotRules.swift \
//     Retichat-ios/tests/RNodeSlotRulesTests.swift && \
//     /private/tmp/claude-501/rnode-slot-rules
//
// The rules are pure; the coordinator needs CoreBluetooth and the FFI, so
// that it follows them is asserted on its source, like
// RNodeRadioConfigTests.swift does for the views.

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

// MARK: - After a disconnect

func testAfterDisconnect() {
    func outcome(error: Bool, afterFailure: Bool, retryScheduled: Bool) -> RNodeDisconnectOutcome {
        RNodeSlotRules.afterDisconnect(error: error, droppedAfterFailure: afterFailure, failureScheduledRetry: retryScheduled)
    }
    check(outcome(error: false, afterFailure: false, retryScheduled: false)
              == RNodeDisconnectOutcome(status: .idle, scheduleBackoff: true),
          "a clean drop is idle and reconnects with the backoff")
    check(outcome(error: true, afterFailure: false, retryScheduled: false)
              == RNodeDisconnectOutcome(status: .failed, scheduleBackoff: true),
          "a drop with an error is failed and reconnects with the backoff")
    check(outcome(error: false, afterFailure: true, retryScheduled: false)
              == RNodeDisconnectOutcome(status: .failed, scheduleBackoff: true),
          "dropped after a radio setup failure: stays failed, reconnects with the backoff")
    check(outcome(error: false, afterFailure: true, retryScheduled: true)
              == RNodeDisconnectOutcome(status: .failed, scheduleBackoff: false),
          "dropped after a refused subscription: stays failed, keeps its 60 s retry")
    check(outcome(error: true, afterFailure: true, retryScheduled: true)
              == RNodeDisconnectOutcome(status: .failed, scheduleBackoff: false),
          "an error on that drop changes neither")
}

func testRetryTimes() {
    var waits: [Int] = []
    var s = 1
    for _ in 0..<9 { waits.append(s); s = RNodeSlotRules.nextBackoff(after: s) }
    check(waits == [1, 2, 4, 8, 16, 32, 60, 60, 60], "the backoff doubles up to a minute", "\(waits)")
    check(RNodeSlotRules.unknownPeripheralRetrySeconds == 30, "an unknown peripheral is tried again after 30 s")
    check(RNodeSlotRules.subscribeFailedRetrySeconds == 60, "a refused subscription is tried again after 60 s")
}

// MARK: - The coordinator (source)

func sourceFile(_ components: [String]) throws -> String {
    let url = components.reduce(
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    ) { $0.appendingPathComponent($1) }
    return try String(contentsOf: url, encoding: .utf8)
}

/// The text of the first `func name(` up to the next member function or the
/// end of its type.
func body(_ source: String, _ name: String) -> String {
    guard let start = source.range(of: "func \(name)(") else { return "" }
    let rest = source[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n}\n"].compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

func testCoordinatorFollowsTheRules() {
    let coordinator: String
    do {
        coordinator = try sourceFile(["Retichat", "Services", "RNodeInterfaceCoordinator.swift"])
    } catch {
        check(false, "reads RNodeInterfaceCoordinator.swift", String(describing: error))
        return
    }

    let disconnect = body(coordinator, "handleDisconnect")
    check(disconnect.contains("RNodeSlotRules.afterDisconnect("), "handleDisconnect decides by the rules")
    check(!disconnect.contains("setStatus(.idle"), "handleDisconnect sets no status of its own")

    // Every link dropped after a failure goes through dropAfterFailure, which
    // marks it for handleDisconnect; stop() and stopSlot() drop the others.
    let drops = coordinator.components(separatedBy: "cancelPeripheralConnection(").count - 1
    check(drops == 3, "cancelPeripheralConnection only in stop, stopSlot and dropAfterFailure", "found \(drops)")
    let drop = body(coordinator, "dropAfterFailure")
    check(drop.contains("slot.droppedAfterFailure = true"), "dropAfterFailure marks the slot")
    check(drop.contains("setStatus(.failed, for: slot.id)"), "dropAfterFailure shows failed")

    check(coordinator.contains("dropAfterFailure(slot: slot, peripheral: peripheral, retryAfter: RNodeSlotRules.subscribeFailedRetrySeconds)"),
          "a refused subscription retries after 60 s")
    let register = body(coordinator, "startRegisterInterface")
    check(register.components(separatedBy: "dropAfterFailure(slot:").count - 1 == 2,
          "a failed create and a failed configure drop the link as failures")
    check(body(coordinator, "connect").contains("slot.droppedAfterFailure = false"),
          "a new attempt starts unmarked")
    check(body(coordinator, "scheduleReconnect").contains("RNodeSlotRules.nextBackoff(after: slot.backoffSeconds)"),
          "the reconnect backoff is the rules'")
}

@main
enum RNodeSlotRulesTests {
    static func main() {
        testAfterDisconnect()
        testRetryTimes()
        testCoordinatorFollowsTheRules()

        if failures.isEmpty {
            print("all RNode slot rules tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
