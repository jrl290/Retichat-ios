//
//  FallbackBackbones.swift
//  Retichat
//
//  Which public fallback backbones generateConfig writes into the stack
//  config. Foundation only and free of the network, so
//  tests/FallbackBackbonesTests.swift runs both branches as they are.
//

import Foundation

enum FallbackBackbones {
    /// The fallback backbones for a generated config.
    ///
    /// Only when the user left "Default TCP" on AND configured no interface
    /// of their own, as the setting documents and Android's StackRuntime
    /// does (`useDefault = interfaces.isEmpty() && isDefaultTcpEnabled`).
    /// Otherwise none: a first launch with the setting off once dialled
    /// three public backbones before the user could add an interface.
    ///
    /// - probed: the endpoints startService's probe found reachable (empty
    ///   when it skipped the probe or found none).
    /// - pool: the unprobed pool to pick from when `probed` is empty; called
    ///   only when fallbacks are wanted.
    static func select(defaultTcpEnabled: Bool,
                       hasConfiguredInterfaces: Bool,
                       probed: [(host: String, port: Int)],
                       pool: () -> [(host: String, port: Int)]) -> [(host: String, port: Int)] {
        guard defaultTcpEnabled, !hasConfiguredInterfaces else { return [] }
        return probed.isEmpty ? pool() : probed
    }

    // MARK: - Picking them (James, 2026-10-21)
    //
    // "Make Android and iOS probe all default backbones at once and take the
    // first three that answer", and "Add a blacklist also". Tested one at a
    // time, each backbone that was down cost its whole 5 s before the stack
    // could start: with two of the seven down, 5.5 s on average, up to 10.5 s.
    // Android: DefaultEndpointManager.pick.

    typealias Endpoint = (host: String, port: Int)

    /// How long a backbone that failed its start-up test is skipped.
    static let skipSeconds: TimeInterval = 24 * 60 * 60

    static func key(_ endpoint: Endpoint) -> String { "\(endpoint.host):\(endpoint.port)" }

    static func isSkipped(_ failedAt: [String: Double], _ endpoint: Endpoint, now: Double) -> Bool {
        guard let at = failedAt[key(endpoint)] else { return false }
        return now - at >= 0 && now - at < skipSeconds
    }

    /// Tests `order`'s backbones at once and returns the first `count` to
    /// answer, in the order they answered. Those `failedAt` marks within
    /// `skipSeconds` are tested only once the rest can't make up `count`.
    /// Fewer answering are padded in `order`, skipped ones last, so the stack
    /// has backbones to reconnect to once the network is back. Tests still
    /// running carry on after the return; when all are done, `record` gets
    /// the updated skip list (`updatedSkipList`).
    static func pick(order: [Endpoint],
                     failedAt: [String: Double],
                     now: Double,
                     timeout: TimeInterval,
                     count: Int = 3,
                     probe: @escaping (Endpoint) async -> Bool,
                     record: @escaping ([String: Double]) -> Void) async -> [Endpoint] {
        let skipped = order.filter { isSkipped(failedAt, $0, now: now) }
        let fresh = order.filter { !isSkipped(failedAt, $0, now: now) }
        let (outcomes, sink) = AsyncStream<(index: Int, ok: Bool)>.makeStream()
        var tested: [Endpoint] = []
        var tests: [Task<Bool, Never>] = []
        func test(_ endpoints: [Endpoint]) {
            for endpoint in endpoints {
                let index = tested.count
                tested.append(endpoint)
                tests.append(Task {
                    let ok = await answer(within: timeout) { await probe(endpoint) }
                    sink.yield((index: index, ok: ok))
                    return ok
                })
            }
        }

        test(fresh)
        var pending = fresh.count
        var skippedTested = false
        var answered: [Endpoint] = []
        var iterator = outcomes.makeAsyncIterator()
        while answered.count < count {
            if !skippedTested && answered.count + pending < count {
                skippedTested = true
                test(skipped)
                pending += skipped.count
            }
            if pending == 0 { break }
            guard let outcome = await iterator.next() else { break }
            pending -= 1
            if outcome.ok { answered.append(tested[outcome.index]) }
        }

        let all = Array(zip(tested, tests))
        Task {
            var results: [(Endpoint, Bool)] = []
            for (endpoint, test) in all { results.append((endpoint, await test.value)) }
            record(updatedSkipList(failedAt, results: results, now: now))
        }
        var picked: [Endpoint] = []
        for endpoint in answered + fresh + skipped
        where picked.count < count && !picked.contains(where: { key($0) == key(endpoint) }) {
            picked.append(endpoint)
        }
        return picked
    }

    /// The skip list after a start's tests: expired entries dropped, and, if
    /// any backbone answered, each that failed marked `now` and each that
    /// answered cleared. With none answering the device was offline, which
    /// says nothing about the backbones.
    static func updatedSkipList(_ failedAt: [String: Double], results: [(Endpoint, Bool)], now: Double) -> [String: Double] {
        var next = failedAt.filter { now - $0.value >= 0 && now - $0.value < skipSeconds }
        guard results.contains(where: { $0.1 }) else { return next }
        for (endpoint, ok) in results {
            next[key(endpoint)] = ok ? nil : now
        }
        return next
    }

    /// `probe`'s answer, or false once `timeout` has passed.
    static func answer(within timeout: TimeInterval, _ probe: @escaping () async -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let first = FirstAnswer(continuation)
            Task { first.give(await probe()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                first.give(false)
            }
        }
    }

    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func give(_ ok: Bool) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: ok)
        }
    }
}
