//
//  RfedLink.swift
//  Retichat
//
//  `rfed.link`: one held link to the RFed node that carries every RFed
//  operation, both ways (RFed-spec/Link.md). The client's requests go as
//  requests on their path (`/channel/subscribe`, `/channel/publish`,
//  `/distro/pull`, ...); the node's pushes come back on the same link as
//  requests to `/channel/delivery` (channel posts; `/delivery` from a node
//  before the 2026-11-13 revision), `/lxmf/delivery` (LXMF messages for this
//  device or its distro) and `/notify` (a wake), and this client's answer to
//  each is the delivery proof. With a node of protocol version 2 the link also
//  carries the router's LXMF propagation (`RfedPropagationCarrier`, below), so
//  this device holds no second link to the node's `lxmf.propagation`.
//
//  Before 2026-10-18 iOS used a destination per operation: a link per
//  aspect, publishes as unanswered DATA, and pushes on two stream links.
//  The web moved to rfed.link in September (Retichat-js `_rfedRequest`,
//  `_onRfedLinkPush`); Android and iOS moved together on 2026-10-18 (Android
//  RfedLink.kt).
//
//  The link identifies as this device once established, before ACTIVE, so
//  the pulls that authenticate by link identity can follow at once, and its
//  push handlers are set before the link is created (a link captures its
//  destination at creation). Pushes are bound per link: every ACTIVE edge
//  runs the binders (the two stream opens) again.
//
//  Over a slow route the device holds no link (`holdsNoLink`, James
//  2026-11-05: "for LoRa/Slow connections we can't maintain a link to
//  RFed"): RFed wakes its own wake address instead of pushing, the link
//  opens for requests only, and it closes once none waits.
//

import Foundation

@MainActor
final class RfedLink {
    static let shared = RfedLink()

    /// The channel push (RFed-spec/Link.md), from a node of protocol version 2.
    nonisolated static let pushChannelDelivery = "/channel/delivery"
    /// The channel push's name before the 2026-11-13 revision, deprecated: older nodes push it.
    nonisolated static let pushDelivery = "/delivery"
    nonisolated static let pushLxmf = "/lxmf/delivery"
    nonisolated static let pushNotify = "/notify"

    /// Nodes whose rfed.link this stack has set up.
    private var setUp = Set<String>()

    /// Others that follow a node's link status (the registrations owed on
    /// it): node → owner → handler. ConnectionStateManager keeps one status
    /// handler per destination, and on rfed.link that one is this object's.
    private var statusListeners: [String: [String: (UInt8) -> Void]] = [:]

    /// What every fresh link is bound for (owner → bind), run with the node
    /// on each ACTIVE edge: the channel stream and the propagation stream.
    private var binders: [String: (String) -> Void] = [:]

    /// The binders that only ask the node to push (the stream opens), skipped
    /// on a link this device doesn't hold.
    private var pushBinders = Set<String>()

    /// What a fresh link this device doesn't hold runs (`setCollector`).
    private var collector: ((String) -> Void)?

    /// Runs of requests (`holding`) under way on each node: hex → how many.
    private var runs: [String: Int] = [:]

    /// Who takes each push (path → handler). Called on a link worker thread,
    /// which waits for the answer: true only when this device now holds the
    /// blob. Set by the services that hold what is pushed.
    nonisolated private static let pushHandlers = PushHandlers()

    private init() {}

    // MARK: - Setup by the services

    /// Take the pushes on `path` with `handler` (one per path, replaced on a
    /// repeat). `handler` runs on a link worker thread and answers in place.
    nonisolated static func setPushHandler(path: String, _ handler: @escaping @Sendable (Data) -> Bool) {
        pushHandlers.set(path, handler)
    }

    /// Run `bind(node)` on every ACTIVE edge of an rfed.link, as `owner`;
    /// `forPushes` when all it does is ask the node to push on the link.
    func setBinder(owner: String, forPushes: Bool = false, _ bind: @escaping (String) -> Void) {
        binders[owner] = bind
        if forPushes { pushBinders.insert(owner) } else { pushBinders.remove(owner) }
    }

    /// Run `collect(node)` on each fresh link this device doesn't hold
    /// (`holdsNoLink`), after the binders: RfedCollect, set by the app.
    func setCollector(_ collect: @escaping (String) -> Void) {
        collector = collect
    }

    /// Follow `nodeHex`'s rfed.link status as `owner` (one handler per
    /// owner, replaced on a repeat); nil removes it.
    func setStatusListener(nodeHex: String, owner: String, _ handler: ((UInt8) -> Void)?) {
        let node = nodeHex.lowercased()
        if let handler {
            statusListeners[node, default: [:]][owner] = handler
        } else {
            statusListeners[node]?.removeValue(forKey: owner)
        }
    }

    // MARK: - The link

    /// The protocol version `nodeHex` announces on its rfed.link (RFed SPEC
    /// §12), from the announce the stack holds; 0 when none is known.
    nonisolated static func protocolVersion(nodeHex: String) -> UInt32 {
        guard let dest = destHash(nodeHex: nodeHex) else { return 0 }
        return dest.withUnsafeBytes { buf -> UInt32 in
            lxmf_rfed_node_protocol_version(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(dest.count))
        }
    }

    /// The `rfed.link` destination hash of `nodeHex`.
    nonisolated static func destHash(nodeHex: String) -> Data? {
        let hex = RfedChannelClient.rfedDestHash(
            identityHashHex: nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            app: "rfed", aspects: ["link"])
        guard hex.count == 32, let dest = Data(hexString: hex) else { return nil }
        return dest
    }

    /// Set up the link to `nodeHex` (once per node and stack) and start
    /// opening it. Returns its destination hash, or nil with no stack or a
    /// bad node hash.
    @discardableResult
    func ensure(nodeHex: String) -> Data? {
        let node = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let dest = Self.destHash(nodeHex: node) else { return nil }
        let csm = ConnectionStateManager.shared
        if !setUp.contains(node) {
            // Both channel push names: a node of version 2 pushes the new one
            // to a client that binds saying so, an older node the old one.
            let ok = csm.setAppLinkOutboundSetup(
                destHash: dest, identify: true,
                paths: [Self.pushChannelDelivery, Self.pushDelivery, Self.pushLxmf, Self.pushNotify]
            ) { path, data in
                RfedLink.onPush(path: path, data: data)
            }
            guard ok else {
                print("[RfedLink] rfed.link setup refused for \(node.prefix(8)): \(RetichatBridge.shared.rnsLastError() ?? "no stack")")
                return nil
            }
            setUp.insert(node)
            csm.setAppLinkStatusHandler(destHash: dest) { [weak self] status in
                self?.onStatus(node: node, status: status)
            }
            // What the node announced, remembered from before, decides at once
            // where the router's propagation goes; each ACTIVE edge decides again.
            RfedPropagationCarrier.shared.sync(nodeHex: node)
        }
        if csm.appLinkStatus(destHash: dest) != 3 {
            csm.openHeldAppLink(destHash: dest, app: "rfed", aspects: ["link"])
        }
        return dest
    }

    /// The link's status (3 is ACTIVE), 0 with no node.
    func status(nodeHex: String) -> Int32 {
        guard let dest = Self.destHash(nodeHex: nodeHex) else { return 0 }
        return ConnectionStateManager.shared.appLinkStatus(destHash: dest)
    }

    /// A request on `nodeHex`'s rfed.link. Returns the response bytes, or nil
    /// when the link or the request failed inside the 5 s budget.
    func request(nodeHex: String, path: String, payload: Data) async -> Data? {
        guard let dest = ensure(nodeHex: nodeHex) else { return nil }
        let answer = await ConnectionStateManager.shared.appLinkSend(
            destHash: dest, app: "rfed", aspects: ["link"], path: path, payload: payload)
        closeIfIdle(nodeHex: nodeHex, dest: dest)
        return answer
    }

    /// Whether this device holds no link to `nodeHex`: its route was measured
    /// slow (ConnectionStateManager.slowRouteSend) and it hosts its own wake
    /// address (MeshWake.swift), so RFed wakes it when something waits. Then
    /// nothing opens the link just to be pushed to.
    func holdsNoLink(nodeHex: String) -> Bool {
        guard let dest = Self.destHash(nodeHex: nodeHex) else { return false }
        return ConnectionStateManager.shared.appLinkRouteSpeed(destHash: dest) == 2
            && RfedNotifyRegistrar.shared.hostsMeshRelay
    }

    /// Run `run`, a run of requests to `nodeHexes` sent one after another,
    /// holding each node's link from one request to the next: a link this
    /// device doesn't hold (`holdsNoLink`) closes when the run ends, not
    /// between its requests (staging, 2026-11-05: closed after each channel
    /// pull, every pull opened a link of its own over LoRa).
    func holding<T>(nodeHexes: [String], _ run: () async -> T) async -> T {
        let nodes = Set(nodeHexes.map { $0.lowercased() })
        for node in nodes { runs[node, default: 0] += 1 }
        defer {
            for node in nodes {
                let left = (runs[node] ?? 1) - 1
                runs[node] = left > 0 ? left : nil
                if let dest = Self.destHash(nodeHex: node) { closeIfIdle(nodeHex: node, dest: dest) }
            }
        }
        return await run()
    }

    /// After a request or a run: a link this device doesn't hold closes once
    /// no run holds it and no other request waits its turn on it.
    private func closeIfIdle(nodeHex: String, dest: Data) {
        let csm = ConnectionStateManager.shared
        guard holdsNoLink(nodeHex: nodeHex), runs[nodeHex.lowercased()] == nil, csm.slowRouteIdle(destHash: dest),
              csm.appLinkStatus(destHash: dest) != 0 else { return }
        print("[RfedLink] \(nodeHex.prefix(8)): slow route, no request waiting: link closed; RFed wakes this device")
        csm.closeAppLink(destHash: dest)
    }

    /// The stack stopped: the next stack sets every link up again. The
    /// binders and push handlers stay: their services outlive the stack.
    func reset() {
        setUp.removeAll()
        statusListeners.removeAll()
    }

    private func onStatus(node: String, status: UInt8) {
        for handler in Array((statusListeners[node] ?? [:]).values) { handler(status) }
        guard status == 3 else { return }
        // The path response before the link carried the node's announce: its
        // protocol version decides where the router's propagation goes.
        RfedPropagationCarrier.shared.sync(nodeHex: node)
        // A fresh link: bind it for LXMF and channel pushes (Link.md "The
        // client re-binds on every link"), in `bindOrder`. A link this device
        // doesn't hold opened for requests and closes after them: what RFed
        // holds is collected in order instead, the channels with push on
        // only (RfedCollect).
        let pushes = !holdsNoLink(nodeHex: node)
        for owner in Self.bindOrder(Array(binders.keys)) where pushes || !pushBinders.contains(owner) {
            binders[owner]?(node)
        }
        if !pushes { collector?(node) }
    }

    /// The order binders run in on a fresh link: the posts that waited for
    /// it, then the propagation stream with its pull of the distro queue,
    /// then the channel stream (James, 2026-11-05: "distro and propagation
    /// should be first"); any other after them, by name.
    nonisolated static func bindOrder(_ owners: [String]) -> [String] {
        let first = ["channel-queue", "propagation", "channel"]
        return owners.sorted { (first.firstIndex(of: $0) ?? first.count, $0) < (first.firstIndex(of: $1) ?? first.count, $1) }
    }

    /// A push from the node. True only when this device now holds the blob;
    /// false is a refusal the node records instead of deferring (Link.md
    /// "The response is the delivery proof"). Runs on a link worker thread.
    nonisolated private static func onPush(path: String, data: Data) -> Bool {
        if path == pushNotify {
            // A wake: something was deferred for this device, collected with
            // /distro/pull. Acknowledged at once; the pull is its own request
            // (Retichat-js _onRfedLinkPush).
            Task { @MainActor in
                if RfedDistroClient.shared.distro != nil { _ = await RfedDistroClient.shared.pull() }
            }
            return true
        }
        // The channel push under either name goes to the channel client.
        let taker = path == pushChannelDelivery ? pushDelivery : path
        guard let handler = pushHandlers.get(taker) else {
            print("[RfedLink] push on \(path) with no taker: refused")
            return false
        }
        return handler(data)
    }

    /// Push handlers, read on the link worker threads.
    nonisolated private final class PushHandlers: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: @Sendable (Data) -> Bool] = [:]
        func set(_ path: String, _ handler: @escaping @Sendable (Data) -> Bool) {
            lock.lock(); handlers[path] = handler; lock.unlock()
        }
        func get(_ path: String) -> (@Sendable (Data) -> Bool)? {
            lock.lock(); defer { lock.unlock() }
            return handlers[path]
        }
    }
}

/// `HeldLinkOps` for a registration owed on rfed.link: the request on `path`
/// is its delivery proof when answered true. The link is shared, so it is
/// never closed for one registration.
@MainActor
final class RfedLinkHeldOps: HeldLinkOps {
    private let nodeHex: String
    private let path: String
    private let owner: String

    init(nodeHex: String, path: String) {
        self.nodeHex = nodeHex.lowercased()
        self.path = path
        self.owner = "held \(path)"
    }

    func status(_ destHash: Data) -> Int32 { RfedLink.shared.status(nodeHex: nodeHex) }
    func openHeld(_ destHash: Data, app: String, aspects: [String]) { RfedLink.shared.ensure(nodeHex: nodeHex) }
    func close(_ destHash: Data) {}
    func setStatusHandler(_ destHash: Data, _ handler: @escaping (UInt8) -> Void) {
        RfedLink.shared.setStatusListener(nodeHex: nodeHex, owner: owner, handler)
    }
    func sendData(_ destHash: Data, app: String, aspects: [String], payload: Data) async -> Bool {
        await RfedLink.shared.request(nodeHex: nodeHex, path: path, payload: payload) == Data([0xc3])
    }
    func inOneRun(_ run: () async -> Void) async {
        await RfedLink.shared.holding(nodeHexes: [nodeHex], run)
    }
}

/// LXMF propagation over rfed.link (RFed-spec/Link.md, "LXMF propagation on
/// `rfed.link`", 2026-11-13). An RFed node that announces protocol version 2
/// takes the router's uploads and message get as requests on its rfed.link,
/// so this device holds one link to the node and none to its
/// `lxmf.propagation`. The router hands each request here, and it goes as
/// every other request on the link does (`RfedLink.request`): over a slow
/// route the link opens for it and closes once nothing waits. With a node
/// that announces version 1, or none yet, the carrier is removed and the
/// router links to `lxmf.propagation` as before. A port of Android's
/// RfedPropagationCarrier.kt.
@MainActor
final class RfedPropagationCarrier {
    static let shared = RfedPropagationCarrier()

    /// The `lxmf.propagation` the carrier is installed for (hex).
    private(set) var carried: String?

    /// The nodes requests are carried for, kept alive while the router may
    /// call with them: the callback's context.
    private var targets: [String: Target] = [:]

    private init() {}

    /// Whether the router's propagation to `node` (an `lxmf.propagation`
    /// hash) goes on rfed.link.
    func carries(_ node: Data) -> Bool { carried == node.hexString }

    /// Install the router's carrier to `nodeHex`'s rfed.link when the node
    /// announces version 2 with a propagation stamp cost, and remove it
    /// otherwise; only for the RFed node this device propagates through
    /// (Settings, else the default). True when installed: the router uses it
    /// while the node's lxmf.propagation is its propagation node.
    @discardableResult
    func sync(nodeHex: String, client given: LxmfClient? = nil) -> Bool {
        let node = nodeHex.lowercased()
        // Only the RFed node this device propagates through decides: it also
        // links to the nodes its channels live on, and a carrier to one of
        // those would take this one's place.
        guard node == UserPreferences.shared.effectiveRfedNodeIdentityHash.lowercased() else { return false }
        guard let client = given ?? ConnectionStateManager.shared.registeredLxmfClient,
              let dest = RfedLink.destHash(nodeHex: node) else { return false }
        let target = targets[node] ?? Target(node: node)
        targets[node] = target
        let installed = client.syncRfedCarrier(
            rfedLinkHash: dest, callback: rfedCarrierRequest,
            context: Unmanaged.passUnretained(target).toOpaque())
        let propagation = RfedChannelClient.rfedDestHash(identityHashHex: node, app: "lxmf", aspects: ["propagation"])
        let now = installed && propagation.count == 32 ? propagation : nil
        if now != carried {
            carried = now
            print("[RfedPropagation] \(node.prefix(8)): LXMF propagation on \(now != nil ? "rfed.link (protocol version 2)" : "lxmf.propagation")")
            // What the distro outbox owes follows the propagation to its link.
            DistroOutboxRuntime.linkChanged()
        }
        return installed
    }

    /// Answer carrier request `token`: the node's response, or nil when the
    /// request failed. Once, whatever happened.
    nonisolated static func complete(token: UInt64, answer: Data?) {
        guard let answer, !answer.isEmpty else {
            _ = lxmf_propagation_carrier_complete(token, nil, 0)
            return
        }
        answer.withUnsafeBytes { buf in
            _ = lxmf_propagation_carrier_complete(
                token, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(answer.count))
        }
    }

    /// A node the requests are for (the callback's context).
    final class Target: @unchecked Sendable {
        let node: String
        init(node: String) { self.node = node }
    }
}

/// The router's carrier request (`lxmf_client_sync_rfed_carrier`), on a thread
/// of its own: copied out, then sent on the node's rfed.link, and answered.
private let rfedCarrierRequest: lxmf_propagation_carrier_callback_t = { context, token, path, data, dataLen in
    guard let context, let path else {
        RfedPropagationCarrier.complete(token: token, answer: nil)
        return
    }
    let target = Unmanaged<RfedPropagationCarrier.Target>.fromOpaque(context).takeUnretainedValue()
    let requestPath = String(cString: path)
    let payload = data.map { Data(bytes: $0, count: Int(dataLen)) } ?? Data()
    Task { @MainActor in
        let answer = await RfedLink.shared.request(nodeHex: target.node, path: requestPath, payload: payload)
        RfedPropagationCarrier.complete(token: token, answer: answer)
    }
}
