// DistroFirstTests.swift
//
// The app's start with a distro: the distro's queue first, then the persisted
// channels (DESIGN_PRINCIPLES §5). Found on Android in private staging,
// 2026-10-10: the start re-subscribed a channel the distro had left on another
// device, the pull applied that leave 0.3 s later, and a post fanned out
// between the two reached the device. iOS had the same order:
// RfedChannelClient re-subscribed on rfed.channel reachability while
// RfedDistroClient pulled after its registration, unsynchronised. Also the
// truth rule: no answer is never a refusal, and a pull the stack's stop cuts
// is said as cancelled. A port of Retichat-android's DistroFirstResubscribeTest
// and Retichat-js distro_first.test.mjs.
//
// DistroFirst and DistroCodec.notAYes run for real; the wiring needs SwiftData,
// the FFI and the stack, so it is pinned on the source, as the other wiring
// tests here do.
//
// Run from the workspace root with:
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-first \
//     Retichat-ios/Retichat/Services/DistroCodec.swift \
//     Retichat-ios/tests/DistroFirstTests.swift && \
//     /private/tmp/claude-501/distro-first

import Foundation

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0

func check(_ ok: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures.append(what)
        print("FAIL: \(what) (line \(line))")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func read(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// The text from `from` to the next `to` after it ("" and a failed check when either is missing).
func body(_ text: String, _ from: String, _ to: String) -> String {
    guard let start = text.range(of: from) else { check(false, "found: \(from)"); return "" }
    guard let end = text.range(of: to, range: start.upperBound..<text.endIndex) else { check(false, "found after it: \(to)"); return "" }
    return String(text[start.lowerBound..<end.lowerBound])
}

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

/// A device with persisted channels; RFed's queue holds a sibling's leave of #b.
@MainActor
final class Device {
    var channels: [String]
    var wire: [String] = []
    var said: [(String, Bool)] = []

    init(_ channels: [String]) { self.channels = channels }

    func pullApplyingLeaveOfB() async -> DistroFirst.PullOutcome {
        wire.append("/rfed/pull")
        if let i = channels.firstIndex(of: "b") {
            channels.remove(at: i)
            wire.append("/rfed/unsubscribe #b")
        }
        return .init(blobs: 1, unfinished: nil, morePending: false)
    }

    func start(hasDistro: Bool, pull: () async -> DistroFirst.PullOutcome) async {
        await DistroFirst.thenResubscribe(hasDistro: hasDistro, pull: pull,
                                          say: { line, warning in self.said.append((line, warning)) }) {
            for c in self.channels { self.wire.append("/rfed/subscribe #\(c)") }
        }
    }
}

let later = "a sibling's leave still queued at RFed, if any, is applied when a later pull brings it"

@main
enum DistroFirstTests {
    @MainActor
    static func main() async {
        // The order: the leave the pull applies, then the channels that are left.
        do {
            let d = Device(["a", "b"])
            await d.start(hasDistro: true) { await d.pullApplyingLeaveOfB() }
            check(d.wire == ["/rfed/pull", "/rfed/unsubscribe #b", "/rfed/subscribe #a"],
                  "the leave is applied before any channel is subscribed again, and the left one is not: \(d.wire)")
            check(d.said.count == 1 && d.said[0].0 == "Distro queue pulled and applied first (1 blob(s)): re-subscribing persisted channels"
                  && d.said[0].1 == false, "the applied pull is said: \(d.said)")
        }
        // No distro: at once, no pull.
        do {
            let d = Device(["a", "b"])
            var pulled = false
            await d.start(hasDistro: false) { pulled = true; return .init(blobs: 0, unfinished: nil, morePending: false) }
            check(!pulled && d.wire == ["/rfed/subscribe #a", "/rfed/subscribe #b"] && d.said.isEmpty, "no distro: no pull, no wait")
        }
        // No answer (no interface): the outcome is known, the channels go, and it is said.
        do {
            let d = Device(["a"])
            await d.start(hasDistro: true) {
                .init(blobs: 0, unfinished: "no answer from RFed (no link inside 5 s, or the request went unanswered)", morePending: false)
            }
            check(d.wire == ["/rfed/subscribe #a"], "a pull with no answer still lets the re-subscription go")
            check(d.said.count == 1 && d.said[0].1 && d.said[0].0 ==
                  "Distro pull before re-subscribing stopped after 0 blob(s): no answer from RFed (no link inside 5 s, or the request went unanswered); "
                  + "re-subscribing persisted channels now; \(later)", "said, as a warning: \(d.said)")
        }
        // The stack stopped under it: cancelled, and the re-subscription still is not dropped silently.
        do {
            let d = Device(["a"])
            await d.start(hasDistro: true) {
                .init(blobs: 2, unfinished: "cancelled: the stack stopped or the distro changed while round 1 waited for RFed", morePending: false)
            }
            check(d.wire == ["/rfed/subscribe #a"], "a cancelled pull still lets the re-subscription go")
            check(d.said.first?.0.hasPrefix("Distro pull before re-subscribing stopped after 2 blob(s): cancelled: the stack stopped") == true,
                  "said as cancelled, never failed")
        }
        // The round cap.
        do {
            let s = DistroFirst.said(.init(blobs: 24, unfinished: nil, morePending: true))
            check(s.warning && s.line == "Distro pull before re-subscribing applied 24 blob(s) and stopped at its round cap with more pending: "
                  + "re-subscribing persisted channels now; the rest is applied when a later pull brings it", "the round cap is said")
        }

        // No answer is never a refusal (the truth rule).
        check(DistroCodec.notAYes("pre-signed announce", nil) == "RFed did not answer the pre-signed announce", "no answer")
        check(DistroCodec.notAYes("pre-signed announce", Data([0xC2])) == "RFed refused the pre-signed announce (it answered false)", "false")
        check(DistroCodec.notAYes("pre-signed announce", Data([0xC0])) == "RFed refused the pre-signed announce (it answered nil)", "nil")
        check(DistroCodec.notAYes("pre-signed announce", Data([0x91, 0xC2])) == "RFed refused the pre-signed announce (it answered 2 byte(s): 91c2)", "other")
        check(DistroCodec.describeAnswer(Data(0..<17)) == "17 byte(s): 000102030405060708090a0b0c0d0e0f…", "long answers are cut")
        check(DistroCodec.notAYes("registration", nil) == "RFed did not answer the registration", "registration")

        // The wiring.
        let channel = read("Retichat/Services/RfedChannelClient.swift")
        let schedule = body(channel, "private func scheduleResubscribeOnRfedChannelActive() {", "private func resubscribePersistedChannels()")
        check(schedule.contains("await DistroFirst.thenResubscribe(") && schedule.contains("hasDistro: DistroManager.shared.has,")
              && schedule.contains("pull: { await RfedDistroClient.shared.pullForStart() },"), "the start's re-subscription is gated on the distro pull")
        check(before(schedule, "pullForStart()", "waitForRfedReachable(timeoutSecs: 5.0)")
              && before(schedule, "pullForStart()", "self.resubscribePersistedChannels()"),
              "the pull comes before the reachability wait and the re-subscription (and with it the push re-registration)")
        check(schedule.contains("print(\"[RfedChannel] RFed not reachable within 5 s: \\(n) persisted channel(s) not re-subscribed at this start\")"),
              "an unreachable node is said, not dropped silently")
        check(channel.components(separatedBy: "scheduleResubscribeOnRfedChannelActive()").count - 1 == 2, "one definition, one call (start)")
        let resub = body(channel, "private func resubscribePersistedChannels()", "await MainActor.run")
        check(resub.contains("RfedNotifyRegistrar.shared.registerForChannel("), "push re-registration is inside the gated re-subscription")

        let distro = read("Retichat/Services/RfedDistroClient.swift")
        let start = body(distro, "func pullForStart() async -> DistroFirst.PullOutcome {", "nonisolated static func ingested() async {")
        check(before(start, "Self.importNSEBlobs()", "await pullOutcome()") && before(start, "await pullOutcome()", "await Self.ingested()"),
              "what the NSE pulled, then RFed's queue, then every blob of both applied")
        let barrier = body(distro, "nonisolated static func ingested() async {", "/// Rounds are sequential")
        check(barrier.contains("blobQueue.async {") && barrier.contains("Task { @MainActor in done.resume() }"),
              "the barrier queues behind the unwraps and their main-actor hand-offs")
        check(!barrier.contains("sleep") && !barrier.contains("asyncAfter"), "a completion signal, never a wait for time")
        let run = body(distro, "private func runPull(_ k: RegKey, _ dest: Data) async -> DistroFirst.PullOutcome {", "// MARK: - Inbound")
        check(run.contains("unfinished = \"cancelled: the stack stopped or the distro changed while round \\(round) waited for RFed\""),
              "a stop under a round is said as cancelled")
        check(run.contains("unfinished = \"cancelled: the stack stopped or the distro changed before round \\(round)\""), "and before one")
        check(!run.contains("guard isCurrent(k) else { break }"), "a superseded pull never breaks off without a word")
        check(!run.contains("status.lastError = \"RFed pull: link not reachable\"") && !run.contains("): link not reachable\")"),
              "no answer is not called \"link not reachable\"")
        let announce = body(distro, "private func publishAnnounce(", "func republishAnnounce()")
        check(announce.contains("let said = DistroCodec.notAYes(\"pre-signed announce\", aresp)") && announce.contains("print(\"[Distro] \\(said)\")"),
              "the announce says no answer or the refusal with what came back")
        check(!announce.contains("status.lastError = \"RFed refused the pre-signed announce\""), "never a refusal for no answer")
        let register = body(distro, "private func register(_ k: RegKey) async {", "private func publishAnnounce(")
        check(register.contains("fail(k, DistroCodec.notAYes(\"registration\", nil))") && register.contains("fail(k, DistroCodec.notAYes(\"registration\", resp))")
              && !register.contains("fail(k, \"RFed link not reachable\")"), "the registration too")

        // An unset hash is the default node: the destinations are unusable only for a set
        // one that is not 32 hex characters, never "no RFed node configured".
        check(distro.contains("private static let noNode = \"the RFed node identity hash set here is not 32 hex characters\"")
              && distro.contains("print(\"[Distro] pull: \\(Self.noNode)\")") && distro.contains("fail(k, Self.noNode)")
              && distro.contains("print(\"[Distro] unregister: \\(Self.noNode)\")") && !distro.contains("no RFed node configured"),
              "an unusable node hash is said as what it is")

        // The NSE's twin: a round with no answer, after its path was found, is not "RFed not reachable".
        let nse = read("NotificationService/NSEDistroPull.swift")
        check(nse.contains("NSLog(\"[NSE-Distro] pull round %d: no answer from RFed (the link did not come up, or the request went unanswered)\", round)")
              && !nse.contains("NSLog(\"[NSE-Distro] pull round %d: RFed not reachable\", round)"), "the NSE says no answer")
        // The NSE subscribes nothing and registers no channel push: it has no re-subscription to order.
        for file in ["NotificationService/NotificationService.swift", "NotificationService/NSEDistroPull.swift", "NotificationService/NSEChannelPull.swift"] {
            let text = read(file)
            check(!text.isEmpty && !text.contains("/rfed/subscribe") && !text.contains("/channel/subscribe")
                  && !text.contains("registerForChannel("), "\(file) never subscribes a channel")
        }

        print("\(checks) checks, \(failures.count) failed")
        if !failures.isEmpty { exit(1) }
    }
}
