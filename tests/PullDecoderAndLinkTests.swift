// PullDecoderAndLinkTests.swift
//
// Self-contained Swift test script — no XCTest target required.
// Run with:
//
//     swift Retichat-ios/tests/PullDecoderAndLinkTests.swift
//
// Exits with status 0 on success, 1 on any failure.
//
// What it covers
// ──────────────
// These are the iOS-side regression tests for the bug fixes that produced
// the current PULL paging + link-management behaviour:
//
//   1. `decodePullResponse` decodes the 2-element envelope
//        [ [[bin(16) channel_hash, bin(*) blob], ...], Bool more_pending ]
//      shipped by `rfed.delivery /rfed/pull`.  This is a copy of the
//      production decoder in `RfedChannelClient.swift` — when the production
//      decoder changes the copy here MUST be updated in lockstep, otherwise
//      this script silently passes against the wrong shape.
//
//   2. The historical bounds-check bug (`limitedBy: endIndex` compared with
//      `!= endIndex` instead of `!= nil`) returned a valid index when the
//      requested length ran past the buffer.  We assert that truncated
//      buffers now decode to nil instead of crashing or returning garbage.
//
//   3. bin32 / array32 tags decode correctly — earlier code only handled the
//      fixarray and bin8/bin16 paths.
//
//   4. Reachability-generation primitive: a monotonic Int that bumps only on the
//      transition INTO `.connected`.  Stays put while `.connected` is held.
//      Bumps again on every fresh re-establishment.  Wraps with `&+=` so a
//      decade of reconnects doesn't trap.
//
//   5. Refcounted retain/release pattern for the link-status monitor: the
//      timer is started on the first retain and cancelled only on the LAST
//      release.  Two surfaces (Settings + channel chat) must be able to
//      observe concurrently without one cancelling the other.
//
//   6. Channel-stream filter policy: the persistent `rfed.channel.stream`
//      link keeps a runtime-only filter set of channels whose conversation
//      screen has been opened in this process. Subscribed-but-never-opened
//      channels do not stream live, and opened channels remain in the set
//      until process teardown or unsubscribe.
//
//   7. App-link request ownership policy: only the live RFed stream endpoints
//      use held persistent links. Channel backlog pull stays on the ephemeral
//      path and uses a one-shot raw request after AppLinks reports readiness.
//
//   8. Source-level hooks: channel backlog pull must target `rfed.channel.pull`
//      with an addressed channel-hash payload, and the channel conversation
//      must trigger that pull again on app foreground.

import Foundation

// ── Test harness ─────────────────────────────────────────────────────────────

var failures: [String] = []

func check(_ cond: @autoclosure () -> Bool, _ name: String, _ detail: String = "") {
    if cond() {
        print("ok    - \(name)")
    } else {
        let msg = detail.isEmpty ? name : "\(name) — \(detail)"
        print("FAIL  - \(msg)")
        failures.append(msg)
    }
}

func sourceFile(_ components: [String]) throws -> String {
    let sourceURL = components.reduce(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    ) { partial, component in
        partial.appendingPathComponent(component)
    }
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

func sourceFragment(_ source: String, start: String, end: String) -> String? {
    guard let startRange = source.range(of: start) else { return nil }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

// ── msgpack encoder helpers (mirror rmpv output the server emits) ───────────

func mpFixArray(_ count: Int) -> Data {
    precondition(count <= 15)
    return Data([0x90 | UInt8(count)])
}

func mpArray16(_ count: Int) -> Data {
    var d = Data([0xdc])
    let n = UInt16(count)
    d.append(UInt8(n >> 8))
    d.append(UInt8(n & 0xff))
    return d
}

func mpArray32(_ count: Int) -> Data {
    var d = Data([0xdd])
    let n = UInt32(count)
    d.append(UInt8((n >> 24) & 0xff))
    d.append(UInt8((n >> 16) & 0xff))
    d.append(UInt8((n >>  8) & 0xff))
    d.append(UInt8( n        & 0xff))
    return d
}

func mpBin8(_ bytes: Data) -> Data {
    precondition(bytes.count <= 0xff)
    var d = Data([0xc4, UInt8(bytes.count)])
    d.append(bytes)
    return d
}

func mpBin16(_ bytes: Data) -> Data {
    precondition(bytes.count <= 0xffff)
    var d = Data([0xc5])
    let n = UInt16(bytes.count)
    d.append(UInt8(n >> 8))
    d.append(UInt8(n & 0xff))
    d.append(bytes)
    return d
}

func mpBin32(_ bytes: Data) -> Data {
    var d = Data([0xc6])
    let n = UInt32(bytes.count)
    d.append(UInt8((n >> 24) & 0xff))
    d.append(UInt8((n >> 16) & 0xff))
    d.append(UInt8((n >>  8) & 0xff))
    d.append(UInt8( n        & 0xff))
    d.append(bytes)
    return d
}

func mpBool(_ b: Bool) -> Data { Data([b ? 0xc3 : 0xc2]) }

func encodePullEnvelope(pairs: [(Data, Data)],
                        morePending: Bool,
                        outerTag: (Int) -> Data = mpFixArray,
                        binTag: (Data) -> Data = mpBin8) -> Data {
    var out = outerTag(2)
    out.append(outerTag(pairs.count))
    for (ch, blob) in pairs {
        out.append(mpFixArray(2))
        out.append(binTag(ch))
        out.append(binTag(blob))
    }
    out.append(mpBool(morePending))
    return out
}

// ── Decoder under test (mirror of RfedChannelClient.decodePullResponse) ─────
//
// IMPORTANT: keep this byte-for-byte equivalent to the production decoder.
// If you change one, change both.

func decodePullResponse(_ data: Data) -> (pairs: [(Data, Data)], morePending: Bool)? {
    func available(_ d: Data, from idx: Data.Index, n: Int) -> Range<Data.Index>? {
        guard n >= 0,
              let end = d.index(idx, offsetBy: n, limitedBy: d.endIndex)
        else { return nil }
        return idx..<end
    }
    func readBin(_ d: Data, _ idx: inout Data.Index) -> Data? {
        guard idx < d.endIndex else { return nil }
        let tag = d[idx]
        idx = d.index(after: idx)
        let len: Int
        switch tag {
        case 0xc4:
            guard let r = available(d, from: idx, n: 1) else { return nil }
            len = Int(d[r.lowerBound])
            idx = r.upperBound
        case 0xc5:
            guard let r = available(d, from: idx, n: 2) else { return nil }
            len = (Int(d[r.lowerBound]) << 8) | Int(d[d.index(after: r.lowerBound)])
            idx = r.upperBound
        case 0xc6:
            guard let r = available(d, from: idx, n: 4) else { return nil }
            len = (Int(d[r.lowerBound]) << 24)
                | (Int(d[d.index(r.lowerBound, offsetBy: 1)]) << 16)
                | (Int(d[d.index(r.lowerBound, offsetBy: 2)]) << 8)
                |  Int(d[d.index(r.lowerBound, offsetBy: 3)])
            idx = r.upperBound
        default: return nil
        }
        guard let body = available(d, from: idx, n: len) else { return nil }
        idx = body.upperBound
        return Data(d[body])
    }
    func readArrayCount(_ d: Data, _ idx: inout Data.Index) -> Int? {
        guard idx < d.endIndex else { return nil }
        let tag = d[idx]
        idx = d.index(after: idx)
        if tag & 0xf0 == 0x90 { return Int(tag & 0x0f) }
        if tag == 0xdc {
            guard let r = available(d, from: idx, n: 2) else { return nil }
            let n = (Int(d[r.lowerBound]) << 8) | Int(d[d.index(after: r.lowerBound)])
            idx = r.upperBound
            return n
        }
        if tag == 0xdd {
            guard let r = available(d, from: idx, n: 4) else { return nil }
            let n = (Int(d[r.lowerBound]) << 24)
                  | (Int(d[d.index(r.lowerBound, offsetBy: 1)]) << 16)
                  | (Int(d[d.index(r.lowerBound, offsetBy: 2)]) << 8)
                  |  Int(d[d.index(r.lowerBound, offsetBy: 3)])
            idx = r.upperBound
            return n
        }
        return nil
    }

    var i = data.startIndex
    guard let outerCount = readArrayCount(data, &i), outerCount == 2 else { return nil }
    guard let pairsCount = readArrayCount(data, &i) else { return nil }
    var pairs: [(Data, Data)] = []
    pairs.reserveCapacity(pairsCount)
    for _ in 0..<pairsCount {
        guard let innerCount = readArrayCount(data, &i), innerCount == 2 else { return nil }
        guard let channelHash = readBin(data, &i),
              let blob = readBin(data, &i) else { return nil }
        pairs.append((channelHash, blob))
    }
    guard i < data.endIndex else { return nil }
    let boolTag = data[i]
    i = data.index(after: i)
    let morePending: Bool
    switch boolTag {
    case 0xc2: morePending = false
    case 0xc3: morePending = true
    default:   return nil
    }
    return (pairs, morePending)
}

// ── PULL decoder tests ──────────────────────────────────────────────────────

func testEmptyEnvelope() {
    let d = encodePullEnvelope(pairs: [], morePending: false)
    guard let (pairs, more) = decodePullResponse(d) else {
        check(false, "empty envelope decodes")
        return
    }
    check(pairs.isEmpty, "empty envelope: 0 pairs")
    check(more == false, "empty envelope: more_pending=false")
}

func testTwoPairsMoreTrue() {
    let ch1 = Data(repeating: 0x11, count: 16)
    let ch2 = Data(repeating: 0x22, count: 16)
    let blob1 = Data("hello".utf8)
    let blob2 = Data("world".utf8)
    let d = encodePullEnvelope(pairs: [(ch1, blob1), (ch2, blob2)], morePending: true)
    guard let (pairs, more) = decodePullResponse(d) else {
        check(false, "two-pair envelope decodes")
        return
    }
    check(pairs.count == 2, "two pairs returned")
    check(pairs[0].0 == ch1 && pairs[0].1 == blob1, "first pair preserved")
    check(pairs[1].0 == ch2 && pairs[1].1 == blob2, "second pair preserved")
    check(more == true, "more_pending=true survives the wire")
}

func testBin16Blob() {
    // Force bin16 path with a >255-byte blob.
    let ch = Data(repeating: 0xAA, count: 16)
    let blob = Data(repeating: 0x5A, count: 300)
    let d = encodePullEnvelope(pairs: [(ch, blob)], morePending: false, binTag: mpBin16)
    guard let (pairs, _) = decodePullResponse(d) else {
        check(false, "bin16 envelope decodes")
        return
    }
    check(pairs.count == 1 && pairs[0].1.count == 300, "bin16: 300-byte blob preserved")
}

func testBin32Blob() {
    // Smaller payload but explicitly tagged bin32 — guards the bin32 branch.
    let ch = Data(repeating: 0xCC, count: 16)
    let blob = Data(repeating: 0xDE, count: 4)
    let d = encodePullEnvelope(pairs: [(ch, blob)], morePending: false, binTag: mpBin32)
    guard let (pairs, _) = decodePullResponse(d) else {
        check(false, "bin32 envelope decodes")
        return
    }
    check(pairs.count == 1 && pairs[0].1 == blob, "bin32 blob round-trips")
}

func testArray16Outer() {
    // Force array16 outer + array16 inner pairs list with a 1-pair payload.
    let ch = Data(repeating: 0xEE, count: 16)
    let blob = Data("ok".utf8)
    let d = encodePullEnvelope(pairs: [(ch, blob)], morePending: false, outerTag: mpArray16)
    guard let (pairs, more) = decodePullResponse(d) else {
        check(false, "array16 envelope decodes")
        return
    }
    check(pairs.count == 1 && more == false, "array16 envelope decoded with one pair")
}

func testArray32Outer() {
    let ch = Data(repeating: 0xEF, count: 16)
    let blob = Data("ok32".utf8)
    let d = encodePullEnvelope(pairs: [(ch, blob)], morePending: true, outerTag: mpArray32)
    guard let (pairs, more) = decodePullResponse(d) else {
        check(false, "array32 envelope decodes")
        return
    }
    check(pairs.count == 1 && more == true, "array32 envelope decoded with one pair")
}

func testTruncatedBufferRejected() {
    // The historical bug: `limitedBy: endIndex` compared with `!= endIndex`
    // instead of `!= nil`, so a request to read past the buffer succeeded.
    // After the fix, ANY truncated suffix MUST yield nil.
    let ch = Data(repeating: 0x11, count: 16)
    let blob = Data("payload".utf8)
    let full = encodePullEnvelope(pairs: [(ch, blob)], morePending: true)
    var anyOob = false
    var firstFailure = -1
    for cut in 1..<full.count {
        let truncated = full.prefix(cut)
        if decodePullResponse(Data(truncated)) != nil {
            anyOob = true
            firstFailure = cut
            break
        }
    }
    check(!anyOob,
          "all truncated prefixes rejected",
          anyOob ? "decoder accepted prefix of length \(firstFailure) (out-of-bounds read)" : "")
}

func testMissingTrailingBoolRejected() {
    // Build a PULL envelope but omit the trailing bool.
    var d = mpFixArray(2)
    d.append(mpFixArray(0))
    check(decodePullResponse(d) == nil, "envelope missing trailing bool MUST decode to nil")
}

func testWrongOuterArityRejected() {
    // 3-element outer envelope — should not be silently accepted.
    var d = mpFixArray(3)
    d.append(mpFixArray(0))
    d.append(mpBool(false))
    d.append(mpBool(true))
    check(decodePullResponse(d) == nil, "non-2-element outer MUST decode to nil")
}

// ── Reachability generation + refcounted monitor (mirror RfedChannelClient logic) ──

enum NodeStatus { case unknown, unreachable, connected }

/// Pure-logic stand-in for RfedChannelClient's reachability state machine.
/// No timers, no Combine — just the deterministic transitions we need to
/// pin down with tests.
final class LinkMonitorModel {
    private(set) var status: NodeStatus = .unknown
    private(set) var generation: Int = 0

    /// Refcount: how many surfaces want live monitoring.
    private(set) var retainCount: Int = 0
    /// True when the (notional) timer is running.
    private(set) var timerRunning: Bool = false

    func retain() {
        retainCount += 1
        if retainCount == 1 { timerRunning = true }
    }
    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        if retainCount == 0 { timerRunning = false }
    }

    /// Mirror of `refreshRfedNodeStatus` in production.
    func apply(rawReachabilityStatus: Int) {
        let next: NodeStatus
        switch rawReachabilityStatus {
        case 3:  next = .connected
        case 4:  next = .unreachable
        default: next = .unknown
        }
        let wasConnected = status == .connected
        status = next
        if next == .connected && !wasConnected {
            generation &+= 1
        }
    }
}

func testGenerationStartsAtZero() {
    let m = LinkMonitorModel()
    check(m.generation == 0, "rfedReachabilityGeneration starts at 0")
}

func testGenerationBumpsOnEstablishment() {
    let m = LinkMonitorModel()
    m.apply(rawReachabilityStatus: 3) // reachable
    check(m.generation == 1, "first .connected bumps generation to 1")
}

func testGenerationDoesNotBumpWhileHeldConnected() {
    let m = LinkMonitorModel()
    m.apply(rawReachabilityStatus: 3)
    m.apply(rawReachabilityStatus: 3)
    m.apply(rawReachabilityStatus: 3)
    check(m.generation == 1,
          "polling while .connected MUST NOT bump generation")
}

func testGenerationBumpsAgainAfterReestablishment() {
    let m = LinkMonitorModel()
    m.apply(rawReachabilityStatus: 3) // reachable
    m.apply(rawReachabilityStatus: 4) // unreachable
    m.apply(rawReachabilityStatus: 0) // unknown
    m.apply(rawReachabilityStatus: 3) // reachable again
    check(m.generation == 2,
          "fresh .connected after a drop MUST bump generation again")
}

func testGenerationMonotonicAcrossManyCycles() {
    let m = LinkMonitorModel()
    for _ in 0..<10 {
        m.apply(rawReachabilityStatus: 3)
        m.apply(rawReachabilityStatus: 4)
    }
    check(m.generation == 10,
          "ten establish/drop cycles bump generation exactly ten times")
}

func testGenerationIgnoresTransitionsBetweenNonConnected() {
    let m = LinkMonitorModel()
    m.apply(rawReachabilityStatus: 0) // no config / unknown
    m.apply(rawReachabilityStatus: 1) // legacy non-reachable value
    m.apply(rawReachabilityStatus: 2) // legacy non-reachable value
    m.apply(rawReachabilityStatus: 4) // unreachable
    check(m.generation == 0,
          "no .connected transition → no generation bump")
}

func testRetainStartsTimerOnceForMultipleRetains() {
    let m = LinkMonitorModel()
    m.retain()
    check(m.timerRunning, "first retain starts the monitor")
    m.retain()
    check(m.timerRunning && m.retainCount == 2,
          "second retain keeps monitor running, retainCount=2")
}

func testReleaseStopsTimerOnlyOnFinalRelease() {
    let m = LinkMonitorModel()
    m.retain()
    m.retain()
    m.release()
    check(m.timerRunning, "intermediate release MUST NOT stop the monitor")
    m.release()
    check(!m.timerRunning && m.retainCount == 0,
          "final release stops the monitor and zeros the count")
}

func testReleaseIsClampedAtZero() {
    // Spurious release MUST NOT take retainCount negative or thrash the timer.
    let m = LinkMonitorModel()
    m.release()
    m.release()
    check(m.retainCount == 0 && !m.timerRunning,
          "release with no outstanding retain is a no-op")
}

func testSettingsAndChannelChatCoexist() {
    // Reproduces the lifecycle conflict that the refcount fix addressed:
    // SettingsView and a channel chat both want live status; whichever
    // disappears first MUST NOT cancel the other one's monitor.
    let m = LinkMonitorModel()
    m.retain()                // SettingsView appears
    m.retain()                // Channel chat appears
    m.release()               // SettingsView disappears first
    check(m.timerRunning,
          "monitor still running while channel chat retains it")
    m.release()               // Channel chat disappears
    check(!m.timerRunning, "monitor stops once the last surface releases")
}

// ── Channel-stream filter policy (mirror RfedChannelClient logic) ──────────

struct StreamedChannel {
    let id: String
    let nodeId: String
    let isSubscribed: Bool
}

final class ChannelStreamPolicyModel {
    private(set) var openedChannelIds: Set<String> = []

    func markChannelOpened(_ channelId: String) {
        openedChannelIds.insert(channelId.lowercased())
    }

    func removeChannel(_ channelId: String) {
        openedChannelIds.remove(channelId.lowercased())
    }

    func filtersByNode(channels: [StreamedChannel]) -> [String: [String]] {
        let subscribed = channels.filter { $0.isSubscribed }
        let nodes = Set(subscribed.map { $0.nodeId.lowercased() })
        let openedByNode = Dictionary(grouping: subscribed.filter {
            openedChannelIds.contains($0.id.lowercased())
        }) {
            $0.nodeId.lowercased()
        }

        var result: [String: [String]] = [:]
        for node in nodes {
            result[node] = openedByNode[node, default: []].map { $0.id.lowercased() }
        }
        return result
    }
}

func testSubscribedChannelsStartWithEmptyLiveFilters() {
    let model = ChannelStreamPolicyModel()
    let filters = model.filtersByNode(channels: [
        StreamedChannel(id: "aa", nodeId: "node1", isSubscribed: true),
        StreamedChannel(id: "bb", nodeId: "node1", isSubscribed: true)
    ])
    check(filters["node1"] == [],
          "subscribed-but-never-opened channels MUST NOT stream live")
}

func testOpeningChannelAddsOnlyThatChannelToLiveFilters() {
    let model = ChannelStreamPolicyModel()
    model.markChannelOpened("aa")
    let filters = model.filtersByNode(channels: [
        StreamedChannel(id: "aa", nodeId: "node1", isSubscribed: true),
        StreamedChannel(id: "bb", nodeId: "node1", isSubscribed: true)
    ])
    check(filters["node1"] == ["aa"],
          "opening one channel streams only that channel")
}

func testOpenedChannelsStayStreamedAcrossLaterOpens() {
    let model = ChannelStreamPolicyModel()
    model.markChannelOpened("aa")
    model.markChannelOpened("bb")
    let filters = model.filtersByNode(channels: [
        StreamedChannel(id: "aa", nodeId: "node1", isSubscribed: true),
        StreamedChannel(id: "bb", nodeId: "node1", isSubscribed: true),
        StreamedChannel(id: "cc", nodeId: "node1", isSubscribed: true)
    ])
    check(filters["node1"] == ["aa", "bb"],
          "later opens extend the live filter set without dropping earlier opens")
}

func testUnsubscribeDropsChannelFromRuntimeLiveFilters() {
    let model = ChannelStreamPolicyModel()
    model.markChannelOpened("aa")
    model.removeChannel("aa")
    let filters = model.filtersByNode(channels: [
        StreamedChannel(id: "aa", nodeId: "node1", isSubscribed: true)
    ])
    check(filters["node1"] == [],
          "unsubscribed channel MUST be removed from the runtime live filter set")
}

// ── App-link request ownership policy (mirror ConnectionStateManager logic) ──

enum RequestOpenMode: Equatable {
    case none
    case ephemeral
    case persistent
}

struct AppLinkRequestModel {
    static func prefersPersistent(app: String, aspects: [String]) -> Bool {
        let normalizedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = aspects
        if segments.first == normalizedApp {
            segments.removeFirst()
        }
        return normalizedApp == "rfed" && (
            segments == ["channel", "stream"] ||
            segments == ["propagation", "stream"]
        )
    }

    static func requestOpenMode(usePersistentLink: Bool, currentStatus: Int) -> RequestOpenMode {
        if usePersistentLink { return .persistent }
        if currentStatus != 3 { return .ephemeral }
        return .none
    }
}

func testLiveStreamsPreferPersistentAppLinks() {
    check(
        AppLinkRequestModel.prefersPersistent(app: "rfed", aspects: ["channel", "stream"]),
        "channel.stream MUST prefer persistent AppLinks"
    )
    check(
        AppLinkRequestModel.prefersPersistent(app: "rfed", aspects: ["propagation", "stream"]),
        "propagation.stream MUST prefer persistent AppLinks"
    )
    check(
        !AppLinkRequestModel.prefersPersistent(app: "rfed", aspects: ["channel", "pull"]),
        "channel.pull MUST stay on the ephemeral AppLinks path"
    )
}

func testPersistentRequestStillUpgradesReadyOnlyActiveToHeldLink() {
    check(
        AppLinkRequestModel.requestOpenMode(usePersistentLink: true, currentStatus: 3) == .persistent,
        "persistent request helper MUST call openPersistent even when status is already ACTIVE"
    )
}

func testEphemeralActiveRequestDoesNotReopen() {
    check(
        AppLinkRequestModel.requestOpenMode(usePersistentLink: false, currentStatus: 3) == .none,
        "ephemeral active request MUST reuse the ready app-link state without reopening"
    )
}

func testEphemeralInactiveRequestOpensEphemeralLink() {
    check(
        AppLinkRequestModel.requestOpenMode(usePersistentLink: false, currentStatus: 1) == .ephemeral,
        "ephemeral inactive request MUST open the non-persistent app-link path"
    )
}

func testChannelPullSourceUsesSplitDestinationAndAddressedPayload() {
    do {
        let source = try sourceFile(["Retichat", "Services", "RfedChannelClient.swift"])
        guard let fragment = sourceFragment(
            source,
            start: "func pullDeferred(channel: Channel) async -> Bool {",
            end: "    // MARK: - Live channel stream receive"
        ) else {
            check(false, "extracts pullDeferred source fragment")
            return
        }

        check(
            fragment.contains("aspects: [\"channel\", \"pull\"]"),
            "channel pull uses rfed.channel.pull"
        )
        check(
            fragment.contains("payload: Self.msgpackBin(channelHashData)"),
            "channel pull sends the addressed channel hash payload"
        )
        check(
            !fragment.contains("aspects: [\"delivery\"]"),
            "channel pull no longer targets the legacy delivery destination"
        )
    } catch {
        check(false, "reads RfedChannelClient source", String(describing: error))
    }
}

func testConversationSourcePullsChannelOnForeground() {
    do {
        let source = try sourceFile(["Retichat", "Views", "Conversation", "ConversationView.swift"])

        check(
            source.contains("@Environment(\\.scenePhase) private var scenePhase"),
            "conversation view watches scenePhase for foreground pulls"
        )

        guard let fragment = sourceFragment(
            source,
            start: ".onChange(of: scenePhase)",
            end: ".onReceive(Timer.publish"
        ) else {
            check(false, "extracts scenePhase foreground source fragment")
            return
        }

        check(
            fragment.contains("channelClient.canPullMore[channelKey] = nil"),
            "foreground channel pull re-enables the paging affordance before requesting"
        )
        check(
            fragment.contains("await channelClient.pullDeferred(channel: channel)"),
            "foreground channel pull requests channel backlog on app active"
        )
    } catch {
        check(false, "reads ConversationView source", String(describing: error))
    }
}

// ── Early startup + queued RFed ops (mirror RfedChannelClient logic) ─────

enum ChannelClientStartAction: Equatable {
    case loadPersistedState
    case startNetworkFlows
}

final class ChannelClientStartModel {
    var didLoadPersistedState = false
    var didStartNetworkFlows = false
    var identityReady = false

    func start() -> [ChannelClientStartAction] {
        var actions: [ChannelClientStartAction] = []
        if !didLoadPersistedState {
            didLoadPersistedState = true
            actions.append(.loadPersistedState)
        }
        guard identityReady else { return actions }
        if !didStartNetworkFlows {
            didStartNetworkFlows = true
            actions.append(.startNetworkFlows)
        }
        return actions
    }
}

enum QueuedChannelOperation: Equatable {
    case send(channelId: String)
    case pull(channelId: String)
}

final class PendingRfedOpModel {
    var identityReady = false
    var ownHashReady = false
    private(set) var queued: [QueuedChannelOperation] = []
    private var queuedPullIds: Set<String> = []

    private var canIssueRfedOperations: Bool {
        identityReady && ownHashReady
    }

    func send(channelId: String) -> [QueuedChannelOperation] {
        guard canIssueRfedOperations else {
            queued.append(.send(channelId: channelId.lowercased()))
            return []
        }
        return [.send(channelId: channelId.lowercased())]
    }

    func pull(channelId: String) -> [QueuedChannelOperation] {
        let normalized = channelId.lowercased()
        guard canIssueRfedOperations else {
            if queuedPullIds.insert(normalized).inserted {
                queued.append(.pull(channelId: normalized))
            }
            return []
        }
        return [.pull(channelId: normalized)]
    }

    func drainIfReady() -> [QueuedChannelOperation] {
        guard canIssueRfedOperations else { return [] }
        let drained = queued
        queued = []
        queuedPullIds = []
        return drained
    }
}

func testPersistedStateLoadsBeforeIdentityReady() {
    let model = ChannelClientStartModel()
    check(model.start() == [.loadPersistedState],
          "channel state MUST hydrate before the RFed identity is ready")
    model.identityReady = true
    check(model.start() == [.startNetworkFlows],
          "network flows start later, once identity becomes ready")
}

func testQueuedRfedOpsDrainInOriginalOrderOnceReady() {
    let model = PendingRfedOpModel()
    _ = model.send(channelId: "aa")
    _ = model.pull(channelId: "bb")
    model.identityReady = true
    model.ownHashReady = true
    check(model.drainIfReady() == [
        .send(channelId: "aa"),
        .pull(channelId: "bb")
    ], "queued RFed send/pull requests MUST drain in FIFO order once ready")
}

func testQueuedPullCollapsesDuplicateRequestsUntilReady() {
    let model = PendingRfedOpModel()
    _ = model.pull(channelId: "aa")
    _ = model.pull(channelId: "AA")
    check(model.queued == [.pull(channelId: "aa")],
          "duplicate queued pulls for the same channel MUST collapse before readiness")
}

// ── Verified channel-message delivery state (mirror RfedChannelClient) ─────

func verifiedChannelMessageDeliveryState(isOutgoing: Bool) -> Int {
    isOutgoing ? 1 : 2
}

func testOutgoingVerifiedChannelMessageStaysSingleCheck() {
    check(verifiedChannelMessageDeliveryState(isOutgoing: true) == 1,
          "outgoing echoed channel messages MUST stay at sent, not delivered")
}

func testIncomingVerifiedChannelMessageShowsDelivered() {
    check(verifiedChannelMessageDeliveryState(isOutgoing: false) == 2,
          "incoming channel messages still render as delivered")
}

// ── Run all ─────────────────────────────────────────────────────────────────

print("─── PULL decoder tests ─────────────────────────────")
testEmptyEnvelope()
testTwoPairsMoreTrue()
testBin16Blob()
testBin32Blob()
testArray16Outer()
testArray32Outer()
testTruncatedBufferRejected()
testMissingTrailingBoolRejected()
testWrongOuterArityRejected()

print("─── Reachability-generation + refcount tests ───────")
testGenerationStartsAtZero()
testGenerationBumpsOnEstablishment()
testGenerationDoesNotBumpWhileHeldConnected()
testGenerationBumpsAgainAfterReestablishment()
testGenerationMonotonicAcrossManyCycles()
testGenerationIgnoresTransitionsBetweenNonConnected()
testRetainStartsTimerOnceForMultipleRetains()
testReleaseStopsTimerOnlyOnFinalRelease()
testReleaseIsClampedAtZero()
testSettingsAndChannelChatCoexist()

print("─── Channel-stream policy tests ─────────────────────")
testSubscribedChannelsStartWithEmptyLiveFilters()
testOpeningChannelAddsOnlyThatChannelToLiveFilters()
testOpenedChannelsStayStreamedAcrossLaterOpens()
testUnsubscribeDropsChannelFromRuntimeLiveFilters()

print("─── App-link request policy tests ───────────────────")
testLiveStreamsPreferPersistentAppLinks()
testPersistentRequestStillUpgradesReadyOnlyActiveToHeldLink()
testEphemeralActiveRequestDoesNotReopen()
testEphemeralInactiveRequestOpensEphemeralLink()
testChannelPullSourceUsesSplitDestinationAndAddressedPayload()
testConversationSourcePullsChannelOnForeground()

print("─── Early startup + queued RFed op tests ────────────")
testPersistedStateLoadsBeforeIdentityReady()
testQueuedRfedOpsDrainInOriginalOrderOnceReady()
testQueuedPullCollapsesDuplicateRequestsUntilReady()

print("─── Channel delivery-state tests ─────────────────────")
testOutgoingVerifiedChannelMessageStaysSingleCheck()
testIncomingVerifiedChannelMessageShowsDelivered()

print("────────────────────────────────────────────────────")
if failures.isEmpty {
    print("ALL PASS")
    exit(0)
} else {
    print("\(failures.count) FAILURE(S):")
    for f in failures { print("  - \(f)") }
    exit(1)
}
