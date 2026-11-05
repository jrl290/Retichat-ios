//
//  RfedLink.swift
//  Retichat
//
//  `rfed.link`: one held link to the RFed node that carries every RFed
//  operation, both ways (RFed-spec/Link.md). The client's requests go as
//  requests on their path (`/channel/subscribe`, `/channel/publish`,
//  `/distro/pull`, ...); the node's pushes come back on the same link as
//  requests to `/delivery` (channel posts), `/lxmf/delivery` (LXMF messages
//  for this device or its distro) and `/notify` (a wake), and this client's
//  answer to each is the delivery proof.
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
            let ok = csm.setAppLinkOutboundSetup(
                destHash: dest, identify: true,
                paths: [Self.pushDelivery, Self.pushLxmf, Self.pushNotify]
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
        guard let handler = pushHandlers.get(path) else {
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
