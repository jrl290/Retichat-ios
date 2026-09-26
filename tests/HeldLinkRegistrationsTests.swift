// HeldLinkRegistrationsTests.swift
//
// APNs token and rfed.notify registrations (2026-09-26): sent only on an
// established held link, never lost to an ACTIVE edge that came while a send
// was running, owed until proved. Port of Retichat-android
// HeldLinkRegistrationsTest.kt.
//
// The type lives in ConnectionStateManager.swift between the BEGIN/END
// HeldLinkRegistrations markers (Foundation only); the test lifts that block
// out, as the web tests lift handlers out of app.js. Run from the workspace
// root with:
//
//   { echo 'import Foundation'; \
//     sed -n '/^\/\/ BEGIN HeldLinkRegistrations/,/^\/\/ END HeldLinkRegistrations/p' \
//     Retichat-ios/Retichat/Services/ConnectionStateManager.swift; } \
//     > /private/tmp/claude-501/HeldLinkRegistrations.swift && \
//   swiftc -o /private/tmp/claude-501/held-link-registrations \
//     /private/tmp/claude-501/HeldLinkRegistrations.swift \
//     Retichat-ios/tests/HeldLinkRegistrationsTests.swift && \
//     /private/tmp/claude-501/held-link-registrations

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if !ok { failures.append(what); print("FAIL: \(what)") }
}

@MainActor
final class FakeOps: HeldLinkOps {
    var status: Int32 = 0
    var handler: ((UInt8) -> Void)?
    var opens = 0
    var closes = 0
    var sent: [String] = []
    /// Results for successive sends; a send beyond them is proved.
    var results: [() async -> Bool] = []

    func status(_ destHash: Data) -> Int32 { status }
    func openHeld(_ destHash: Data, app: String, aspects: [String]) { opens += 1 }
    func close(_ destHash: Data) { closes += 1 }
    func setStatusHandler(_ destHash: Data, _ handler: @escaping (UInt8) -> Void) { self.handler = handler }
    func sendData(_ destHash: Data, app: String, aspects: [String], payload: Data) async -> Bool {
        sent.append(String(decoding: payload, as: UTF8.self))
        if results.isEmpty { return true }
        return await results.removeFirst()()
    }
}

@MainActor
func registrations(_ ops: FakeOps) -> HeldLinkRegistrations {
    HeldLinkRegistrations(destHash: Data(count: 16), app: "apns", aspects: ["register"], ops: ops, log: { _ in })
}

/// Let the tasks the type starts run to their next suspension.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
func testNothingIsSentBeforeTheHeldLinkIsEstablished() async {
    let ops = FakeOps()
    let reg = registrations(ops)
    reg.owe(key: "token", payload: Data("p".utf8))
    await settle()
    check(ops.opens == 1, "the held link is opened")
    check(ops.sent.isEmpty, "no send before its ACTIVE edge")
    ops.status = 3
    await reg.onActive()
    check(ops.sent == ["p"], "sent on the ACTIVE edge")
    check(reg.owedKeys.isEmpty, "nothing owed after the proof")
    check(ops.closes == 1, "closed once nothing is owed")
}

/// The Android phone, 2026-09-26 03:45 UTC: the ACTIVE edge came while the
/// first send was running, was skipped, and the send failed; nothing sent the
/// registration again. The edge now runs another round after the send.
@MainActor
func testAnActiveEdgeDuringAFailingSendIsNotLost() async {
    let ops = FakeOps()
    ops.status = 3
    var release: CheckedContinuation<Void, Never>?
    ops.results.append {
        await withCheckedContinuation { release = $0 }
        return false
    }
    let reg = registrations(ops)
    reg.owe(key: "token", payload: Data("p".utf8))
    await settle()
    check(ops.sent.count == 1 && release != nil, "the first send is running")
    await reg.onActive()          // the edge that comes mid-send
    release?.resume()
    await settle()
    check(ops.sent == ["p", "p"], "sent again for the edge that came mid-send (\(ops.sent))")
    check(reg.owedKeys.isEmpty, "delivered by the second round")
    check(ops.closes == 1, "closed once")
}

@MainActor
func testAnUnprovedRegistrationStaysOwedUntilTheNextEdge() async {
    let ops = FakeOps()
    ops.status = 3
    ops.results.append { false }
    let reg = registrations(ops)
    reg.owe(key: "token", payload: Data("p".utf8))
    await settle()
    check(reg.owedKeys == ["token"], "still owed")
    check(ops.closes == 0, "the link stays for the next edge")
    await reg.onActive()
    check(ops.sent.count == 2 && reg.owedKeys.isEmpty, "sent on the next edge")
}

@MainActor
func testADeliveredRegistrationIsNotSentAgain() async {
    let ops = FakeOps()
    ops.status = 3
    let reg = registrations(ops)
    reg.owe(key: "token", payload: Data("p".utf8))
    await settle()
    reg.owe(key: "token", payload: Data("p".utf8))
    await settle()
    check(ops.sent.count == 1, "sent once")
    check(ops.opens == 0, "no second link for it")
}

@MainActor
func testTheHandlerSendsOnActiveOnly() async {
    let ops = FakeOps()
    let reg = registrations(ops)
    reg.owe(key: "token", payload: Data("p".utf8))
    ops.handler?(2)
    ops.handler?(4)
    await settle()
    check(ops.sent.isEmpty, "ESTABLISHING and DISCONNECTED send nothing")
    ops.status = 3
    ops.handler?(3)
    await settle()
    check(ops.sent == ["p"], "ACTIVE sends")
}

@MainActor
func testAForgottenRegistrationIsNotSent() async {
    let ops = FakeOps()
    let reg = registrations(ops)
    reg.owe(key: "channel", payload: Data("p".utf8))
    reg.forget(key: "channel")
    ops.status = 3
    await reg.onActive()
    check(ops.sent.isEmpty, "a forgotten registration is not sent")
}

@main
enum HeldLinkRegistrationsTests {
    static func main() async {
        await testNothingIsSentBeforeTheHeldLinkIsEstablished()
        await testAnActiveEdgeDuringAFailingSendIsNotLost()
        await testAnUnprovedRegistrationStaysOwedUntilTheNextEdge()
        await testADeliveredRegistrationIsNotSentAgain()
        await testTheHandlerSendsOnActiveOnly()
        await testAForgottenRegistrationIsNotSent()
        if failures.isEmpty {
            print("all held-link registration tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
