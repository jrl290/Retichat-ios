//
//  ConnectionStateManager.swift
//  Retichat
//
//  Event-driven connection state hierarchy.
//
//  Layers (outer → inner):
//    1. System network (NWPathMonitor) — OS tells us when connectivity changes.
//    2. TCP transport  — Rust reconnect loops handle this internally; we nudge
//                        them with rns_nudge_reconnect() on OS reconnect events.
//    3. Reticulum path — we request paths for known destinations at startup
//                        and whenever network is restored.
//    4. LXMF peer link — established on first outbound or inbound message;
//                        tracked via lxmf_peer_link_status at send time.
//
//  Peer reachability is tracked via announces — no timer polling.
//  TCP connectivity is left to the Rust transport layer (polling is fine there).
//

import Foundation
import Network

/// C trampoline for the LXMF APP_LINK status callback.
///
/// Runs on the link-actor thread.  Copies the destination hash, computes
/// its hex key, and dispatches to `ConnectionStateManager.shared` on the
/// main actor.  Declared as `@convention(c)` so it can be passed across
/// the FFI boundary as a plain function pointer.
let _appLinkStatusTrampoline: lxmf_app_link_status_callback_t = {
    (_ context: UnsafeMutableRawPointer?,
     _ destPtr: UnsafePointer<UInt8>?,
     _ destLen: UInt32,
     _ status: UInt8) -> Void in
    guard let destPtr = destPtr, destLen > 0 else { return }
    let bytes = UnsafeBufferPointer(start: destPtr, count: Int(destLen))
    let hex = Data(bytes).hexString
    Task { @MainActor in
        ConnectionStateManager.shared._appLinkStatusChanged(
            destHashHex: hex, status: status)
    }
}

@MainActor
final class ConnectionStateManager {
    static let shared = ConnectionStateManager()

    private enum RequestOpenMode {
        case none
        case ephemeral
        case persistent
    }

    // MARK: - Private state

    /// Last-seen announce time per destination hash hex.
    private var peerLastSeen: [String: Date] = [:]

    /// Peers whose direct LXMF link recently failed and have not re-announced.
    /// Sends to these peers bypass the link check and go straight to the prop node.
    /// Cleared when the peer announces again.
    private var degradedPeers: Set<String> = []

    /// Hex hashes of all peers in the currently-open conversation (empty when no chat is on screen).
    private var activeConversationHexes: Set<String> = []

    /// Cached rfed.channel destination tracked while the app is in the foreground.
    private var rfedLinkDestData: Data? = nil

    /// Weak reference to the LXMF client, set after startup.
    private weak var lxmfClient: LxmfClient? = nil

    /// Network reachability monitor — fires `appLinkNetworkChanged()` on every
    /// path-status transition so the router gets exactly one retry trigger per
    /// real network event (no polling).
    private var pathMonitor: NWPathMonitor? = nil
    private var lastPathStatus: NWPath.Status = .requiresConnection
    /// NWPathMonitor delivers an initial callback as soon as it starts, just
    /// reporting current reachability — that is NOT a network change. Swallow
    /// the first callback so we do not burn the router's single per-trigger
    /// app-link attempt before Transport has had a chance to resolve any
    /// paths. Real subsequent transitions still fire normally.
    private var pathMonitorPrimed: Bool = false

    /// Dedicated serial queue for path-table disk persistence. Decouples the
    /// (potentially slow) on-disk write from the FFI/transport queue while
    /// still preserving write order — saves are issued in the order they are
    /// requested. Path-table snapshot bytes are computed on the FFI side
    /// (transport_save_paths is internally synchronized); only the I/O hop
    /// runs here.
    private let persistQueue = DispatchQueue(
        label: "chat.retichat.path-persist", qos: .utility)

    /// APP_LINK status-change handlers, keyed by destination-hash hex.
    /// Each handler receives the new status byte (0..4).  Multiple handlers
    /// per dest are not supported — last register wins.  Handlers are
    /// dispatched on the main actor.  Used by services (RfedChannelClient,
    /// RfedNotifyRegistrar, etc.) to react to ACTIVE without polling.
    private var appLinkStatusHandlers: [String: (UInt8) -> Void] = [:]

    /// Essential-destination readiness handlers, keyed by destination-hash
    /// hex. Fired when requestEssentialPaths observes that both path and
    /// identity are available for a watched infrastructure destination.
    private var essentialReadyHandlers: [String: () -> Void] = [:]

    private init() {}

    // MARK: - Setup

    /// Call once after the LXMF stack has started.
    func register(lxmfClient: LxmfClient) {
        self.lxmfClient = lxmfClient

        // Register reconnect handlers for every rfed aspect this app uses
        // and the apns relay, so the LXMF router re-establishes app-links
        // to those destinations on announce. (The built-in delivery_announce
        // _handler only covers lxmf.delivery.)
        //
        // Per REFACTOR.md step 4: rfed.channel and rfed.notify are split
        // into per-op aspects; the legacy rfed.channel/rfed.notify aspects
        // remain registered because mixed-version servers still announce and
        // serve them for compatibility. apns.notifyRelay is renamed apns.relay.
        // Live receive paths now use rfed.channel.stream and
        // rfed.propagation.stream.
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.notify")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel.subscribe")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel.unsubscribe")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel.publish")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel.pull")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel.stream")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.propagation.stream")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.notify.register")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.notify.unregister")
        lxmfClient.appLinkRegisterReconnect(aspect: "apns.relay")
        lxmfClient.appLinkRegisterReconnect(aspect: "apns.register")
        lxmfClient.appLinkRegisterReconnect(aspect: "apns.unregister")

        // Register a single APP_LINK status-change C callback that fans out
        // to per-dest Swift handlers registered via setAppLinkStatusHandler.
        // This is how services react to ACTIVE without polling — see
        // DESIGN_PRINCIPLES.md §1, §3.
        lxmfClient.setAppLinkStatusCallback(_appLinkStatusTrampoline, context: nil)

        requestEssentialPaths()
        // Open the rfed.channel app-link immediately so the SettingsView
        // "RFed Node" status pill (which polls appLinkStatus on the
        // rfed.channel destination) reflects reality on first launch.
        // Without this the pill stayed at "No path" indefinitely on cold
        // start because openRfedNodeLink() only ran on onNetworkRecover.
        openRfedNodeLink()
        startNetworkMonitor()
    }

    /// Register a handler that fires whenever the APP_LINK to `destHash`
    /// changes status.  Replaces any previous handler for the same dest.
    /// Pass `nil` to remove.
    ///
    /// Handlers are dispatched on the main actor.  Used by services that
    /// must wait for an ACTIVE link before performing work that would
    /// otherwise blindly hit the 5 s send-budget — e.g. re-subscribe to
    /// channels after restart, register for push notifications.
    func setAppLinkStatusHandler(destHash: Data, handler: ((UInt8) -> Void)?) {
        let key = destHash.hexString
        if let h = handler {
            appLinkStatusHandlers[key] = h
        } else {
            appLinkStatusHandlers.removeValue(forKey: key)
        }
    }

    /// Register a handler that fires when an essential infrastructure
    /// destination is observed with both a live path and known identity.
    /// Pass `nil` to remove.
    func setEssentialDestinationReadyHandler(destHash: Data, handler: (() -> Void)?) {
        let key = destHash.hexString
        if let h = handler {
            essentialReadyHandlers[key] = h
        } else {
            essentialReadyHandlers.removeValue(forKey: key)
        }
    }

    @discardableResult
    func registerAppLinkPacketCallback(destHash: Data,
                                       callback: @escaping @Sendable (Data) -> Void) -> Bool {
        guard let client = lxmfClient else { return false }
        return client.setAppLinkPacketCallback(destHash: destHash, callback: callback)
    }

    /// Internal: invoked by the C trampoline on the link-actor thread.
    /// Hops to MainActor and dispatches to the per-dest handler.
    fileprivate func _appLinkStatusChanged(destHashHex: String, status: UInt8) {
        if let handler = appLinkStatusHandlers[destHashHex] {
            handler(status)
        }
    }

    /// Spawn an NWPathMonitor and forward every reachability transition into
    /// the LXMF router as a single network-change trigger. This is the only
    /// signal that retries an offline app-link — there is no polling.
    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "retichat.connection.pathmonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            let manager = self
            Task { @MainActor in
                guard let manager else { return }
                let prev = manager.lastPathStatus
                manager.lastPathStatus = path.status
                // First callback after monitor.start() is the initial state
                // report, not a transition. Record it and return without
                // triggering an app-link attempt — paths haven't resolved yet.
                guard manager.pathMonitorPrimed else {
                    manager.pathMonitorPrimed = true
                    print("[ConnState] network monitor primed: status=\(path.status), interfaces=\(path.availableInterfaces.map(\.name))")
                    return
                }
                guard prev != path.status else { return }
                print("[ConnState] network change: \(prev) → \(path.status), interfaces=\(path.availableInterfaces.map(\.name))")
                let client = manager.lxmfClient
                Task.detached(priority: .userInitiated) {
                    client?.appLinkNetworkChanged()
                }
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    // MARK: - Announce-driven reachability

    /// Call whenever an announce is received from a peer.
    /// Clears any link-degradation flag so we try direct again next time.
    func didReceiveAnnounce(destHash: Data) {
        let hex = destHash.hexString
        peerLastSeen[hex] = Date()
        degradedPeers.remove(hex)
    }

    /// True if an announce was received from this peer in the last 10 minutes.
    func isPeerRecentlySeen(destHex: String) -> Bool {
        guard let lastSeen = peerLastSeen[destHex] else { return false }
        return Date().timeIntervalSince(lastSeen) < 600
    }

    // MARK: - Link degradation

    /// Mark a peer's direct link as failed.
    /// Subsequent sends will use the propagation node until they announce again.
    /// Also re-requests their path so the incoming PATH_RESPONSE (which always
    /// passes through even with drop_announces=true) will call didReceiveAnnounce
    /// and clear the degraded flag once they're reachable again.
    func markPeerDegraded(destHex: String) {
        degradedPeers.insert(destHex)
        if let destData = Data(hexString: destHex) {
            _ = RetichatBridge.shared.transportRequestPath(destHash: destData)
        }
    }

    // MARK: - Delivery method selection

    /// How recently a peer must have announced to justify a DIRECT attempt
    /// when no active link exists yet.  Keeps us from sending on stale paths
    /// where link establishment or receipt proof will time out.
    private static let directAnnounceWindow: TimeInterval = 120  // 2 minutes

    /// Returns the LXMF delivery method to use when sending to a peer.
    /// Uses live link status and recent announce data — instant, no I/O.
    ///
    /// Strategy: always DIRECT.  AppLinks owns the full tier chain (inbound
    /// link → cached outbound → fresh path-race + link establishment) plus
    /// Timer P which starts a parallel PROPAGATED send after the normal 5 s
    /// budget, or immediately when the current APP_LINK status is already
    /// DISCONNECTED. Pre-empting to PROPAGATED here — even when
    /// transportHasPath is false — would bypass AppLinks entirely and skip
    /// the parallel-send mechanism, leading to a send failure if the prop
    /// node link is also slow or unavailable at that instant.
    /// NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
    func deliveryMethod(for destHash: Data) -> UInt8 {
        return LxmfMethod.direct
    }

    func appLinkStatus(destHash: Data) -> Int32 {
        guard let client = lxmfClient else { return 0 }
        return client.appLinkStatus(destHash)
    }

    // MARK: - APP_LINK request helper

    /// Open (idempotently) an APP_LINK to `destHash` for the given app/aspects
    /// tuple, wait up to 5 s for it to reach ACTIVE, then run a request on it.
    ///
    /// All link management is delegated to the Rust APP_LINK layer — no
    /// Swift-side one-shot links, no retries, no exponential backoff.
    /// NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
    ///
    /// Returns the response bytes from the request, or `nil` if the link
    /// did not reach ACTIVE inside the 5 s budget or the request itself
    /// failed/timed out.
    func appLinkSend(destHash: Data,
                     app: String,
                     aspects: String,
                     path: String,
                     payload: Data) async -> Data? {
        await appLinkSend(
            destHash: destHash,
            app: app,
            aspects: normalizedAspectSegments(app: app, aspects: aspects),
            path: path,
            payload: payload
        )
    }

    func appLinkSend(destHash: Data,
                     app: String,
                     aspects: [String],
                     path: String,
                     payload: Data) async -> Data? {
        guard let client = lxmfClient else { return nil }

        let normalizedAspects = normalizedAspectSegments(app: app, aspects: aspects)
        let usePersistentLink = prefersPersistentAppLink(app: app, aspects: normalizedAspects)

        switch requestOpenMode(
            usePersistentLink: usePersistentLink,
            currentStatus: client.appLinkStatus(destHash)
        ) {
        case .persistent:
            // `open()` can report ACTIVE once the path is READY even though no
            // held requestable handle exists yet. The live RFed stream endpoints
            // need the held persistent link, not just a ready route.
            client.appLinkOpenPersistent(destHash, app: app, aspects: normalizedAspects)
        case .ephemeral:
            client.appLinkOpen(destHash, app: app, aspects: normalizedAspects)
        case .none:
            break
        }

        // Wait up to 5 s for ACTIVE.
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if client.appLinkStatus(destHash) == 3 { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        guard client.appLinkStatus(destHash) == 3 else { return nil }

        if !usePersistentLink {
            let identityHandle = client.identityHandle
            guard identityHandle != 0 else { return nil }
            return await oneShotRfedRequest(
                destHash: destHash,
                app: app,
                aspects: aspectSpec(app: app, aspects: normalizedAspects),
                identityHandle: identityHandle,
                path: path,
                payload: payload
            )
        }

        // Async FFI variant: suspends the awaiting Task without parking
        // a cooperative-pool thread on a synchronous Rust receive.
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        return await client.appLinkRequestAsync(
            destHash: destHash, path: path,
            payload: payload, timeoutSecs: 5.0
        )
    }

    /// Prime an APP_LINK destination using its preferred ownership mode so
    /// announce/path readiness can be observed via the standard status callback
    /// fan-out.
    @discardableResult
    func appLinkPrime(destHash: Data,
                      app: String,
                      aspects: String) -> Bool {
        appLinkPrime(
            destHash: destHash,
            app: app,
            aspects: normalizedAspectSegments(app: app, aspects: aspects)
        )
    }

    @discardableResult
    func appLinkPrime(destHash: Data,
                      app: String,
                      aspects: [String]) -> Bool {
        guard let client = lxmfClient else { return false }
        let normalizedAspects = normalizedAspectSegments(app: app, aspects: aspects)
        if prefersPersistentAppLink(app: app, aspects: normalizedAspects) {
            return client.appLinkOpenPersistent(destHash, app: app, aspects: normalizedAspects)
        }
        return client.appLinkOpen(destHash, app: app, aspects: normalizedAspects)
    }

    /// Send a plain DATA packet via AppLinks and suspend until Reticulum
    /// delivery proof arrives or the tier chain fails.
    func appLinkSendData(destHash: Data,
                         app: String,
                         aspects: String,
                         payload: Data) async -> Bool {
        await appLinkSendData(
            destHash: destHash,
            app: app,
            aspects: normalizedAspectSegments(app: app, aspects: aspects),
            payload: payload
        )
    }

    func appLinkSendData(destHash: Data,
                         app: String,
                         aspects: [String],
                         payload: Data) async -> Bool {
        guard let client = lxmfClient else { return false }
        return await client.appLinkSendAsync(
            destHash: destHash,
            app: app,
            aspects: aspects,
            payload: payload
        )
    }

    private func normalizedAspectSegments(app: String, aspects: String) -> [String] {
        let normalizedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = aspects
            .split(whereSeparator: { $0 == "." || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if segments.first == normalizedApp {
            segments.removeFirst()
        }

        return segments
    }

    private func normalizedAspectSegments(app: String, aspects: [String]) -> [String] {
        let normalizedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = aspects
            .flatMap { $0.split(whereSeparator: { $0 == "." || $0 == "," }) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if segments.first == normalizedApp {
            segments.removeFirst()
        }

        return segments
    }

    private func prefersPersistentAppLink(app: String, aspects: [String]) -> Bool {
        let normalizedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = normalizedAspectSegments(app: app, aspects: aspects)
        return normalizedApp == "rfed" && (
            segments == ["channel", "stream"] ||
            segments == ["propagation", "stream"]
        )
    }

    private func requestOpenMode(usePersistentLink: Bool, currentStatus: Int32) -> RequestOpenMode {
        if usePersistentLink { return .persistent }
        if currentStatus != 3 { return .ephemeral }
        return .none
    }

    private func aspectSpec(app: String, aspects: [String]) -> String {
        normalizedAspectSegments(app: app, aspects: aspects).joined(separator: ".")
    }

    private func oneShotRfedRequest(destHash: Data,
                                    app: String,
                                    aspects: String,
                                    identityHandle: UInt64,
                                    path: String,
                                    payload: Data,
                                    timeoutSecs: Double = 5.0) async -> Data? {
        let bridge = RetichatBridge.shared
        return await Task.detached(priority: .utility) {
            bridge.linkRequest(
                destHash: destHash,
                appName: app,
                aspects: aspects,
                identityHandle: identityHandle,
                path: path,
                payload: payload,
                timeoutSecs: timeoutSecs
            )
        }.value
    }

    /// Legacy single-shot RFed infrastructure request.
    ///
    /// Use this only for flows that intentionally own a fresh link lifecycle.
    /// Request traffic routed over a registered APP_LINK should use
    /// `appLinkSend(destHash:app:aspects:path:payload:)` instead.
    ///
    /// Use `.utility`, not `.userInitiated`: the Rust transport/request path
    /// ultimately waits on default-QoS worker threads, and running the wrapper
    /// task hotter triggers Thread Performance Checker inversions.
    /// NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §6, §7
    @available(*, deprecated, message: "Use appLinkSend(...) for registered RFed request flows; keep raw link ownership only for intentional fresh-session probes.")
    func rfedLinkRequest(destHash: Data,
                         app: String,
                         aspects: String,
                         identityHandle: UInt64,
                         path: String,
                         payload: Data,
                         timeoutSecs: Double = 5.0) async -> Data? {
        await oneShotRfedRequest(
            destHash: destHash,
            app: app,
            aspects: aspects,
            identityHandle: identityHandle,
            path: path,
            payload: payload,
            timeoutSecs: timeoutSecs
        )
    }

    /// Call when a conversation screen appears for a peer (direct or group member).
    /// Opens an app link: watches announces, requests path, and establishes a
    /// direct link proactively while the user is on screen.
    func openConversation(peerHash: Data) {
        activeConversationHexes.insert(peerHash.hexString)
        let client = lxmfClient
        let hex = peerHash.hexString
        Task.detached(priority: .userInitiated) {
            let t = CFAbsoluteTimeGetCurrent()
            print("[DIAG][appLinkOpen] start dest=\(hex.prefix(8))")
            client?.appLinkOpen(peerHash)
            let took = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t)
            print("[DIAG][appLinkOpen] done dest=\(hex.prefix(8)) took=\(took)s")
        }
    }

    /// Call when a conversation screen disappears.
    func closeConversation(peerHash: Data) {
        activeConversationHexes.remove(peerHash.hexString)
        let client = lxmfClient
        let hex = peerHash.hexString
        Task.detached(priority: .userInitiated) {
            let t = CFAbsoluteTimeGetCurrent()
            print("[DIAG][appLinkClose] start dest=\(hex.prefix(8))")
            client?.appLinkClose(peerHash)
            let took = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t)
            print("[DIAG][appLinkClose] done dest=\(hex.prefix(8)) took=\(took)s")
        }
    }

    // MARK: - App lifecycle events

    /// Call when the app returns to foreground.
    /// Re-requests paths to infrastructure nodes and re-opens app links for
    /// any active conversation peers.
    func onAppForeground() {
        requestEssentialPaths()
        let client = lxmfClient
        // Pre-compute Data values on @MainActor before going off-thread
        let peerDatas = activeConversationHexes.compactMap { Data(hexString: $0) }
        Task.detached(priority: .userInitiated) {
            for peerData in peerDatas {
                client?.appLinkOpen(peerData)
            }
        }
    }

    // MARK: - RFed node link

    /// Request a path to the configured rfed.channel destination. RFed is
    /// infrastructure traffic and does not use AppLinks.
    func openRfedNodeLink() {
        guard let destData = rfedChannelDestData(includeHiddenDefault: true) else { return }
        rfedLinkDestData = destData
        let bridge = RetichatBridge.shared
        Task.detached(priority: .userInitiated) {
            _ = bridge.transportRequestPath(destHash: destData)
        }
    }

    /// Stop tracking the rfed node status in the foreground UI.
    func closeRfedNodeLink() {
        rfedLinkDestData = nil
    }

    /// Current reachability status for the rfed node.
    /// Returns: 0=NONE/no config, 3=path verified this session, 4=no fresh path.
    func rfedNodeLinkStatus() -> Int32 {
        guard let destData = rfedChannelDestData(includeHiddenDefault: false) else { return 0 }
        let bridge = RetichatBridge.shared
        return (bridge.transportHasPath(destHash: destData)
                && bridge.transportPathVerifiedThisSession(destHash: destData)) ? 3 : 4
    }

    /// Public access to the rfed.channel destination derived from current
    /// preferences.  Used by the SettingsView status indicator to tell
    /// "no config" apart from "config present but no link".
    func rfedChannelDestDataPublic() -> Data? {
        return rfedChannelDestData(includeHiddenDefault: false)
    }

    /// True if the routing table currently has a path to the configured
    /// rfed.channel destination.  Used by the SettingsView status indicator
    /// to distinguish a transient "link not active yet" from a genuine
    /// "no path" failure.
    func rfedChannelHasPath() -> Bool {
        guard let destData = rfedChannelDestData(includeHiddenDefault: false) else { return false }
        let bridge = RetichatBridge.shared
        return bridge.transportHasPath(destHash: destData)
            && bridge.transportPathVerifiedThisSession(destHash: destData)
    }

    /// Wait for the rfed.channel.subscribe route to become reachable.
    func waitForRfedReachable(timeoutSecs: Double) async -> Bool {
        guard let destData = rfedServiceDestData(includeHiddenDefault: true,
                                                 aspects: ["channel", "subscribe"]) else {
            return false
        }
        let bridge = RetichatBridge.shared
        let deadline = Date().addingTimeInterval(timeoutSecs)
        while Date() < deadline {
            if bridge.transportHasPath(destHash: destData)
                && bridge.transportPathVerifiedThisSession(destHash: destData) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Derives the rfed.node 16-byte dest from current prefs.
    /// Used as the reachability probe for the configured RFed node (the
    /// rfed.node aspect is always registered — see RFed-rust step 1).
    private func rfedChannelDestData(includeHiddenDefault: Bool) -> Data? {
        rfedServiceDestData(includeHiddenDefault: includeHiddenDefault, aspects: ["node"])
    }

    private func rfedServiceDestData(includeHiddenDefault: Bool,
                                     aspects: [String]) -> Data? {
        let prefs = UserPreferences.shared
        let identityHex = includeHiddenDefault
            ? prefs.effectiveRfedNodeIdentityHash
            : prefs.rfedNodeIdentityHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identityHex.isEmpty else { return nil }
        let destHex = RfedChannelClient.rfedDestHash(
            identityHashHex: identityHex, app: "rfed", aspects: aspects)
        guard !destHex.isEmpty else { return nil }
        return Data(hexString: destHex)
    }

    private func rfedNodeLinkStatusRuntime() -> Int32 {
        guard let destData = rfedLinkDestData ?? rfedChannelDestData(includeHiddenDefault: true) else { return 0 }
        let bridge = RetichatBridge.shared
        return (bridge.transportHasPath(destHash: destData)
                && bridge.transportPathVerifiedThisSession(destHash: destData)) ? 3 : 4
    }

    /// Re-requests paths to always-needed destinations and re-opens active links.
    /// Call when NWPathMonitor reports network connectivity restored.
    func onNetworkReconnect() {
        requestEssentialPaths()
        // Re-open the rfed node link — path may have been purged when TCP dropped.
        openRfedNodeLink()
        let peers = activeConversationHexes.compactMap { Data(hexString: $0) }
        let bridge = RetichatBridge.shared
        Task.detached(priority: .userInitiated) {
            for peerHash in peers {
                _ = bridge.transportRequestPath(destHash: peerHash)
            }
        }
    }

    // MARK: - Private

    /// Request Reticulum paths to destinations that the app always needs:
    /// the current propagation node, the APNs bridge endpoints, and the
    /// configured RFed notify node.
    ///
    /// Snapshot all destination Data values on the main actor (fast reads),
    /// then dispatch the actual Rust FFI calls to a detached task so the
    /// transport mutex is never contended on the main thread.
    private func requestEssentialPaths() {
        // Collect destinations synchronously — all trivial property reads.
        var destinations: [(name: String, hash: Data)] = []
        func appendDestination(_ name: String, _ hash: Data) {
            guard !destinations.contains(where: { $0.hash == hash }) else { return }
            destinations.append((name, hash))
        }

        var rfedCloneSources: [(name: String, hash: Data)] = []
        var rfedServiceTargets: [(name: String, hash: Data)] = []
        let identityHex = UserPreferences.shared.effectiveRfedNodeIdentityHash
        let effectivePropHex = UserPreferences.shared.effectiveLxmfPropagationHash
        let derivedPropHex = !identityHex.isEmpty
            ? RfedChannelClient.rfedDestHash(
                identityHashHex: identityHex, app: "lxmf", aspects: ["propagation"])
            : ""

        if let propNode = PropagationNodeManager.shared.currentNode() {
            // REFACTOR.md step 1: `propagation.current` slot dropped.
            // The same destination is already covered by the lxmf.propagation
            // clone-source block below when configured; if not, the
            // identity-gate downstream and PSYNC trigger will fetch the path
            // on demand. Keeping `propNode` referenced so the call site
            // stays in scope for the lxmf.propagation logic that follows.
            _ = propNode
        }
        // APNs bridge endpoints. The plist now carries the canonical
        // `apns.register` and `apns.relay` destination hashes directly.
        if let registration = ApnsBridgeHashes.apnsRegistration {
            appendDestination("apns.register", registration)
        }
        if let relay = ApnsBridgeHashes.effectiveRelay {
            appendDestination("apns.relay", relay)
        }

        if !identityHex.isEmpty {
            let nodeHex = RfedChannelClient.rfedDestHash(
                identityHashHex: identityHex, app: "rfed", aspects: ["node"])
            if !nodeHex.isEmpty, let nodeHash = Data(hexString: nodeHex) {
                appendDestination("rfed.node", nodeHash)
                rfedCloneSources.append(("rfed.node", nodeHash))
            }
        }

        if !derivedPropHex.isEmpty,
           effectivePropHex == derivedPropHex,
           let derivedPropHash = Data(hexString: derivedPropHex) {
            rfedCloneSources.append(("lxmf.propagation", derivedPropHash))
        }

        // The 6 split rfed aspects (subscribe/unsubscribe/publish/pull and
        // notify register/unregister) are derived per-op and pre-warmed here
        // so app-links can come up immediately after network reconnect.
        if !identityHex.isEmpty {
            let splitAspects: [(String, [String])] = [
                ("rfed.notify.register",   ["notify", "register"]),
                ("rfed.notify.unregister", ["notify", "unregister"]),
                ("rfed.channel.subscribe",   ["channel", "subscribe"]),
                ("rfed.channel.unsubscribe", ["channel", "unsubscribe"]),
                ("rfed.channel.publish",     ["channel", "publish"]),
                ("rfed.channel.pull",        ["channel", "pull"]),
                ("rfed.channel.stream",      ["channel", "stream"]),
                ("rfed.propagation.stream",  ["propagation", "stream"]),
            ]
            for (label, aspects) in splitAspects {
                let hex = RfedChannelClient.rfedDestHash(
                    identityHashHex: identityHex, app: "rfed", aspects: aspects)
                guard !hex.isEmpty, let hash = Data(hexString: hex) else { continue }
                appendDestination(label, hash)
                rfedServiceTargets.append((label, hash))
            }
        }

        // Also refresh identity for every propagation node candidate whose
        // path was loaded from disk this session.  LXMF's internal trigger
        // (or a saved outbound_propagation_node from a previous run) may
        // attempt PSYNC against any of these — bounded to the failover pool
        // and the user-configured node, deduped, no network flood because
        // the identity-gate downstream only requests paths whose identity
        // is missing.
        let bridgeRef = RetichatBridge.shared
        var nodeCandidates = PropagationNodeManager.shared.orderedNodeHashes()
        if !effectivePropHex.isEmpty, !nodeCandidates.contains(effectivePropHex) {
            nodeCandidates.append(effectivePropHex)
        }
        for nodeHex in nodeCandidates {
            if let nodeHash = Data(hexString: nodeHex),
               bridgeRef.transportHasPath(destHash: nodeHash),
               !destinations.contains(where: { $0.hash == nodeHash }) {
                let label = nodeHex == effectivePropHex ? "lxmf.propagation" : "propagation.cached"
                appendDestination(label, nodeHash)
            }
        }

        // Pre-compute hex labels on the main actor before going off-thread.
        let destPairs: [(Data, String)] = destinations.map {
            ($0.hash, "\($0.name)(\(String($0.hash.hexString.prefix(8))))")
        }
        let bridge = RetichatBridge.shared
        let persistQueue = self.persistQueue

        // All FFI work off the main thread.
        Task.detached(priority: .userInitiated) {
            let t = CFAbsoluteTimeGetCurrent()
            func hasFreshPath(_ dest: Data) -> Bool {
                bridge.transportHasPath(destHash: dest)
                    && bridge.transportPathVerifiedThisSession(destHash: dest)
            }

            func seedRfedServiceRoutesIfPossible() {
                for (sourceName, sourceHash) in rfedCloneSources {
                    guard hasFreshPath(sourceHash),
                          bridge.transportIdentityKnown(destHash: sourceHash) else { continue }

                    for (targetName, targetHash) in rfedServiceTargets {
                        let hadPath = bridge.transportHasPath(destHash: targetHash)
                        let hadFreshPath = bridge.transportPathVerifiedThisSession(destHash: targetHash)
                        let hadIdentity = bridge.transportIdentityKnown(destHash: targetHash)
                        if hadPath && hadFreshPath && hadIdentity { continue }

                        guard bridge.transportClonePathAndIdentity(from: sourceHash, to: targetHash) else { continue }

                        let hasPathNow = bridge.transportHasPath(destHash: targetHash)
                        let hasFreshPathNow = bridge.transportPathVerifiedThisSession(destHash: targetHash)
                        let hasIdentityNow = bridge.transportIdentityKnown(destHash: targetHash)
                        if hadPath != hasPathNow || hadFreshPath != hasFreshPathNow || hadIdentity != hasIdentityNow {
                            print("[DIAG][requestEssentialPaths] seeded dest=\(targetName)(\(String(targetHash.hexString.prefix(8)))) from=\(sourceName)(\(String(sourceHash.hexString.prefix(8)))) hasPath=\(hasPathNow) pathVerified=\(hasFreshPathNow) hasIdentity=\(hasIdentityNow)")
                        }
                    }
                }
            }

            seedRfedServiceRoutesIfPossible()
            print("[DIAG][requestEssentialPaths] task start count=\(destPairs.count)")
            var requested: [(Data, String, Bool, Bool)] = []
            for (dest, label) in destPairs {
                let hasPath = bridge.transportHasPath(destHash: dest)
                let hasFreshPath = bridge.transportPathVerifiedThisSession(destHash: dest)
                let hasIdentity = bridge.transportIdentityKnown(destHash: dest)
                print("[DIAG][requestEssentialPaths] dest=\(label) hasPath=\(hasPath) pathVerified=\(hasFreshPath) hasIdentity=\(hasIdentity)")
                // Infrastructure sends need both a live route and the
                // destination identity. A cold-start path table can leave us
                // with a disk-restored route whose interface is stale for this
                // run, so request a fresh path whenever the route has not been
                // verified by a PATH_RESPONSE / announce in the current session.
                let needsPath = !hasPath || !hasFreshPath
                let needsIdentity = !hasIdentity
                if needsPath || needsIdentity {
                    _ = bridge.transportRequestPath(destHash: dest)
                    print("[DIAG][requestEssentialPaths] requestPath done dest=\(label)")
                    requested.append((dest, label, needsPath, needsIdentity))
                }
            }
            let took = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t)
            print("[DIAG][requestEssentialPaths] task done took=\(took)s")

            // If we asked for any paths, poll briefly for resolution and
            // force-persist the on-disk path table once all asked-for
            // essentials have been resolved (or after a hard timeout).
            // This closes the cold-start "No path" gap caused by the
            // 5-minute periodic persist cadence.
            guard !requested.isEmpty else { return }
            let pollDeadline = CFAbsoluteTimeGetCurrent() + 20.0
            var resolvedAny = false
            while CFAbsoluteTimeGetCurrent() < pollDeadline {
                seedRfedServiceRoutesIfPossible()
                requested.removeAll { dest, label, needsPath, needsIdentity in
                    let pathReady = !needsPath || hasFreshPath(dest)
                    let identityReady = !needsIdentity || bridge.transportIdentityKnown(destHash: dest)
                    if pathReady && identityReady {
                        print("[DIAG][requestEssentialPaths] resolved dest=\(label)")
                        resolvedAny = true
                        let destHex = dest.hexString
                        Task { @MainActor in
                            if let handler = self.essentialReadyHandlers[destHex] {
                                handler()
                            }
                        }
                        return true
                    }
                    return false
                }
                if requested.isEmpty { break }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            }
            if resolvedAny {
                // Hop the actual disk-write to a dedicated serial queue so the
                // FFI/utility queue is free to handle the next path/link work
                // immediately. The serial queue preserves write ordering.
                persistQueue.async {
                    bridge.transportSavePaths()
                    print("[DIAG][requestEssentialPaths] persisted path table to disk")
                }
            } else {
                let unresolved = requested.map { $0.1 }.joined(separator: ",")
                print("[DIAG][requestEssentialPaths] no essentials resolved before timeout; unresolved=\(unresolved)")
            }
        }
    }
}
