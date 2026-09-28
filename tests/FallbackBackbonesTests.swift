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

@main
enum FallbackBackbonesTests {
    static func main() {
        testDefaultTcpOnWithNoInterfaces()
        testDefaultTcpOff()
        testInterfacesPresent()
        testGenerateConfigUsesIt()
        if failures.isEmpty {
            print("all fallback backbone tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
