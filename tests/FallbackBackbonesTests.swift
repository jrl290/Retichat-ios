// FallbackBackbonesTests.swift
//
// Default TCP and the public fallback backbones (2885b5e, approved by James
// 2026-09-27). generateConfig adds the fallback backbones only when the user
// left "Default TCP" on and configured no interface, as Android's
// StackRuntime does. The decision lives in FallbackBackbones.select, which
// runs here for real on every branch; no network is started (the pool is a
// closure, and the probe is startService's, not this function's).
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/fallback-backbones \
//     Retichat-ios/Retichat/Services/FallbackBackbones.swift \
//     Retichat-ios/tests/FallbackBackbonesTests.swift && \
//     /private/tmp/claude-501/fallback-backbones

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

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.lowerBound...]
    guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
    return String(rest[..<end.upperBound])
}

typealias Endpoint = (host: String, port: Int)

func keys(_ e: [Endpoint]) -> [String] { e.map { "\($0.host):\($0.port)" } }

let probed: [Endpoint] = [("probed-a.test", 4242), ("probed-b.test", 4243)]
let pool: [Endpoint] = [("pool-a.test", 1), ("pool-b.test", 2), ("pool-c.test", 3)]

/// Runs select, counting how often it asked for the pool.
func run(on: Bool, interfaces: Bool, probed p: [Endpoint]) -> (result: [String], poolCalls: Int) {
    var calls = 0
    let r = FallbackBackbones.select(defaultTcpEnabled: on, hasConfiguredInterfaces: interfaces,
                                     probed: p, pool: { calls += 1; return pool })
    return (keys(r), calls)
}

func testDefaultTcpOnWithNoInterfaces() {
    let withProbe = run(on: true, interfaces: false, probed: probed)
    check(withProbe.result == keys(probed), "on + no interfaces: the probed backbones", "\(withProbe.result)")
    check(withProbe.poolCalls == 0, "on + probed: the unprobed pool is not consulted")

    let noProbe = run(on: true, interfaces: false, probed: [])
    check(noProbe.result == keys(pool), "on + no interfaces + nothing probed: the pool's picks", "\(noProbe.result)")
    check(noProbe.poolCalls == 1, "on + nothing probed: the pool is asked once")
}

func testDefaultTcpOff() {
    for p in [probed, []] {
        let r = run(on: false, interfaces: false, probed: p)
        check(r.result.isEmpty, "off + no interfaces: no backbones (probed=\(p.count))", "\(r.result)")
        check(r.poolCalls == 0, "off: the pool is never consulted (probed=\(p.count))")
    }
}

func testInterfacesPresent() {
    for on in [true, false] {
        for p in [probed, []] {
            let r = run(on: on, interfaces: true, probed: p)
            check(r.result.isEmpty, "interfaces present, Default TCP \(on ? "on" : "off"): no backbones (probed=\(p.count))",
                  "\(r.result)")
            check(r.poolCalls == 0, "interfaces present: the pool is never consulted")
        }
    }
}

func testGenerateConfigUsesIt() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(!repo.isEmpty, "reads ChatRepository.swift")
    let gen = body(of: "private func generateConfig(", in: repo)
    check(!gen.isEmpty, "finds generateConfig")
    check(gen.contains("FallbackBackbones.select("), "generateConfig decides through FallbackBackbones.select")
    check(gen.contains("defaultTcpEnabled: prefs.defaultTcpEnabled"), "with the user's Default TCP setting")
    check(gen.contains("hasConfiguredInterfaces: addedInterfaces"), "and whether it wrote a user interface")
    check(gen.contains("probed: fallbackEndpoints"), "and startService's probed endpoints")
    check(gen.contains("DefaultBackbone"), "and writes what it returns as DefaultBackbone sections")
    check(!gen.contains("if !addedInterfaces"), "no second, inline gate beside it")
    check(!gen.contains("fallbackEndpoints.isEmpty"), "the probed-or-pool choice is not repeated inline")
}

// ---- Picking them: all at once, the first three to answer, failures skipped ----
// (James, 2026-10-21: "make Android and iOS probe all default backbones at
// once and take the first three that answer, and make Settings show the three
// actually in use", and "Add a blacklist also". Android:
// DefaultBackbonesTest.kt.)

let timeout: TimeInterval = 2
let now: Double = 1_800_000_000
let seven: [Endpoint] = (1...7).map { ("bb\($0).test", 4242) }

/// A stand-in network: a backbone answers after `ms[host]` (10 ms) unless down.
final class Network: @unchecked Sendable {
    let down: Set<String>
    let ms: [String: UInt64]
    private let lock = NSLock()
    private var testedHosts: [String] = []
    init(down: Set<String>, ms: [String: UInt64] = [:]) { self.down = down; self.ms = ms }
    var tested: [String] { lock.lock(); defer { lock.unlock() }; return testedHosts }
    private func note(_ host: String) { lock.lock(); testedHosts.append(host); lock.unlock() }
    func probe(_ e: Endpoint) async -> Bool {
        note(e.host)
        if down.contains(e.host) {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return false
        }
        try? await Task.sleep(nanoseconds: (ms[e.host] ?? 10) * 1_000_000)
        return true
    }
}

struct Picked {
    let hosts: [String]
    let ms: Double
    let recorded: AsyncStream<[String: Double]>
    func skipList() async -> [String: Double] {
        var it = recorded.makeAsyncIterator()
        return await it.next() ?? ["record never came": 0]
    }
}

func pick(_ network: Network, failedAt: [String: Double] = [:], at: Double = now) async -> Picked {
    let (recorded, sink) = AsyncStream<[String: Double]>.makeStream()
    let start = Date()
    let picked = await FallbackBackbones.pick(order: seven, failedAt: failedAt, now: at, timeout: timeout,
                                              probe: { await network.probe($0) },
                                              record: { sink.yield($0); sink.finish() })
    return Picked(hosts: picked.map { $0.host }, ms: Date().timeIntervalSince(start) * 1000, recorded: recorded)
}

func testDownBackbonesCostNothingWhileOthersAnswer() async {
    // The two down come first in the order: one at a time, they cost two timeouts.
    let network = Network(down: ["bb1.test", "bb2.test"])
    let run = await pick(network)
    check(run.hosts.count == 3 && !run.hosts.contains("bb1.test") && !run.hosts.contains("bb2.test"),
          "three that answered", "\(run.hosts)")
    check(run.ms < timeout * 1000 / 2, "picked without waiting for the ones down", "\(Int(run.ms)) ms")
    check(network.tested.count == 7, "all seven tested at once", "\(network.tested)")
}

func testFirstThreeInTheOrderTheyAnswered() async {
    let network = Network(down: [], ms: ["bb1.test": 400, "bb2.test": 300, "bb3.test": 20, "bb4.test": 120,
                                         "bb5.test": 220, "bb6.test": 500, "bb7.test": 600])
    let run = await pick(network)
    check(run.hosts == ["bb3.test", "bb4.test", "bb5.test"], "the first three to answer, in that order", "\(run.hosts)")
}

func testAFailureWhileOthersAnswerIsSkippedFor24Hours() async {
    let skip = await pick(Network(down: ["bb1.test", "bb2.test"])).skipList()
    check(skip == ["bb1.test:4242": now, "bb2.test:4242": now], "the two down are marked", "\(skip)")

    let next = Network(down: ["bb1.test", "bb2.test"])
    let second = await pick(next, failedAt: skip)
    _ = await second.skipList()
    check(!next.tested.contains("bb1.test") && !next.tested.contains("bb2.test"),
          "the next start doesn't test them", "\(next.tested)")
    check(second.hosts.count == 3, "and still has three")

    let later = Network(down: [])
    _ = await pick(later, failedAt: skip, at: now + FallbackBackbones.skipSeconds).skipList()
    check(later.tested.contains("bb1.test"), "tested again after 24 hours", "\(later.tested)")
}

func testSkippedAreTestedWhenTheRestCantMakeUpThree() async {
    // Five failed earlier; of the two left one is down. bb1, bb2 still down; bb3-bb5 back.
    let skip = Dictionary(uniqueKeysWithValues: (1...5).map { ("bb\($0).test:4242", now - 1_000) })
    let network = Network(down: ["bb6.test", "bb1.test", "bb2.test"],
                          ms: ["bb7.test": 10, "bb3.test": 150, "bb4.test": 150, "bb5.test": 150])
    let run = await pick(network, failedAt: skip)
    check(run.hosts.first == "bb7.test" && run.hosts.count == 3
          && run.hosts.dropFirst().allSatisfy { ["bb3.test", "bb4.test", "bb5.test"].contains($0) },
          "the one fresh that answered, then skipped ones that answered", "\(run.hosts)")
    check(run.ms < timeout * 1000 / 2, "no wait for the fresh one down", "\(Int(run.ms)) ms")
    let after = await run.skipList()
    check(after == ["bb1.test:4242": now, "bb2.test:4242": now, "bb6.test:4242": now],
          "the ones back are cleared, the ones down marked again", "\(after)")
}

func testOfflineMarksNothingAndStillGivesThree() async {
    let skip = ["bb7.test:4242": now - 1_000]
    let run = await pick(Network(down: Set(seven.map { $0.host })), failedAt: skip)
    check(run.hosts == ["bb1.test", "bb2.test", "bb3.test"], "padded in order, the skipped one last", "\(run.hosts)")
    // The six, then (they can't make up three) the skipped one.
    check(run.ms < timeout * 1000 * 2.5, "two timeouts at most, where one at a time took seven", "\(Int(run.ms)) ms")
    let after = await run.skipList()
    check(after == skip, "none marked while offline", "\(after)")
}

func testExpiredAndFutureEntriesAreDropped() {
    let skip = ["old:1": now - FallbackBackbones.skipSeconds, "future:1": now + 1, "fresh:1": now - 1]
    let next = FallbackBackbones.updatedSkipList(skip, results: [], now: now)
    check(next == ["fresh:1": now - 1], "expired and future entries dropped", "\(next)")
}

func testStartupAndSettingsUseIt() {
    let manager = source("Retichat/Services/DefaultEndpointManager.swift")
    let select = body(of: "static func selectFallbackEndpoints()", in: manager)
    check(select.contains("FallbackBackbones.pick("), "startService's selector picks through FallbackBackbones.pick")
    check(select.contains("prefs.backboneSkipList"), "with the skip list kept in the preferences")
    let repo = source("Retichat/Services/ChatRepository.swift")
    let gen = body(of: "private func generateConfig(", in: repo)
    check(gen.contains("defaultBackbonesInUse = endpoints.map(FallbackBackbones.key)"),
          "generateConfig records the backbones it writes")
    let settings = source("Retichat/Views/Settings/SettingsView.swift")
    let card = body(of: "private var defaultTcpCard: some View", in: settings)
    check(card.contains("repository.defaultBackbonesInUse"), "Settings shows the three in use")
    check(!card.contains("DefaultEndpointManager.endpoints"), "not the first three of the list")
}

@main
enum FallbackBackbonesTests {
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            print("FAIL  - the tests did not finish in 120 s")
            exit(1)
        }
        testDefaultTcpOnWithNoInterfaces()
        testDefaultTcpOff()
        testInterfacesPresent()
        testGenerateConfigUsesIt()
        await testDownBackbonesCostNothingWhileOthersAnswer()
        await testFirstThreeInTheOrderTheyAnswered()
        await testAFailureWhileOthersAnswerIsSkippedFor24Hours()
        await testSkippedAreTestedWhenTheRestCantMakeUpThree()
        await testOfflineMarksNothingAndStillGivesThree()
        testExpiredAndFutureEntriesAreDropped()
        testStartupAndSettingsUseIt()
        if failures.isEmpty {
            print("all fallback backbone tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
