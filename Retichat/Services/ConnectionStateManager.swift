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

    // MARK: - Private state

    /// Last-seen announce time per destination hash hex.
    private var peerLastSeen: [String: Date] = [:]

    /// Peers whose direct LXMF link recently failed and have not re-announced.
    /// Sends to these peers bypass the link check and go straight to the prop node.
    /// Cleared when the peer announces again.
    private var degradedPeers: Set<String> = []

    /// Hex hashes of all peers in the currently-open conversation (empty when no chat is on screen).
    private var activeConversationHexes: Set<String> = []

    /// Cached rfed.channel destination kept open while the app is in the foreground.
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

    private init() {}

    // MARK: - Setup

    /// Call once after the LXMF stack has started.
    func register(lxmfClient: LxmfClient) {
        self.lxmfClient = lxmfClient

        // Register reconnect handlers for rfed.channel, rfed.notify, rfed.delivery
        // so the LXMF router re-establishes app-links to those destinations on
        // announce. (The built-in delivery_announce_handler only covers lxmf.delivery.)
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.notify")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.delivery")

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
            Task { @MainActor in
                guard let self = self else { return }
                let prev = self.lastPathStatus
                self.lastPathStatus = path.status
                // First callback after monitor.start() is the initial state
                // report, not a transition. Record it and return without
                // triggering an app-link attempt — paths haven't resolved yet.
                guard self.pathMonitorPrimed else {
                    self.pathMonitorPrimed = true
                    print("[ConnState] network monitor primed: status=\(path.status), interfaces=\(path.availableInterfaces.map(\.name))")
                    return
                }
                guard prev != path.status else { return }
                print("[ConnState] network change: \(prev) → \(path.status), interfaces=\(path.availableInterfaces.map(\.name))")
                let client = self.lxmfClient
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
    /// Strategy: prefer DIRECT whenever there is any routing path.  The
    /// app-level 5-second fallback in ChatRepository will send a parallel
    /// PROPAGATED copy if the direct attempt doesn't deliver in time.
    /// This avoids the old problem where degradedPeers forced PROPAGATED
    /// before even attempting DIRECT.
    func deliveryMethod(for destHash: Data) -> UInt8 {
        // An ACTIVE app link or direct/backchannel link exists — use it.
        if let client = lxmfClient {
            if client.appLinkStatus(destHash) == 3 { return LxmfMethod.direct }  // ACTIVE app link
            if client.peerLinkStatus(destHash) == 2 { return LxmfMethod.direct }
        }

        // If we have any routing path to the peer, try DIRECT.
        // The 5-second prop fallback will cover the case where
        // the peer is unreachable.
        if RetichatBridge.shared.transportHasPath(destHash: destHash) {
            return LxmfMethod.direct
        }

        // No path at all — propagation node is the only option.
        return LxmfMethod.propagated
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
                     aspects: [String],
                     path: String,
                     payload: Data) async -> Data? {
        guard let client = lxmfClient else { return nil }

        // Idempotent open: no-op if already registered/active.
        if client.appLinkStatus(destHash) != 3 {
            client.appLinkOpen(destHash, app: app, aspects: aspects)
        }

        // Wait up to 5 s for ACTIVE.
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if client.appLinkStatus(destHash) == 3 { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        guard client.appLinkStatus(destHash) == 3 else { return nil }

        // Async FFI variant: suspends the awaiting Task without parking
        // a cooperative-pool thread on a synchronous Rust receive.
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        return await client.appLinkRequestAsync(
            destHash: destHash, path: path,
            payload: payload, timeoutSecs: 5.0
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

    /// Open (or re-open) an app link to the configured rfed.channel destination.
    /// Call on app foreground; the link is kept alive until `closeRfedNodeLink()`.
    func openRfedNodeLink() {
        guard let destData = rfedChannelDestData() else { return }
        rfedLinkDestData = destData
        let client = lxmfClient
        Task.detached(priority: .userInitiated) {
            // rfed.channel — NOT lxmf.delivery. Without the right aspects the
            // router would resolve the destination identity wrong on every
            // (re)establishment and the link would never reach ACTIVE.
            client?.appLinkOpen(destData, app: "rfed", aspects: ["channel"])
        }
    }

    /// Tear down the app link to the rfed node. Call on app background.
    func closeRfedNodeLink() {
        guard let destData = rfedLinkDestData else { return }
        rfedLinkDestData = nil
        let client = lxmfClient
        Task.detached(priority: .userInitiated) {
            client?.appLinkClose(destData)
        }
    }

    /// Current app-link status for the rfed node.
    /// Returns: 0=NONE, 1=PATH_REQUESTED, 2=ESTABLISHING, 3=ACTIVE, 4=DISCONNECTED.
    func rfedNodeLinkStatus() -> Int32 {
        guard let destData = rfedLinkDestData ?? rfedChannelDestData(),
              let client = lxmfClient else { return 0 }
        return client.appLinkStatus(destData)
    }

    /// Snapshot the (LxmfClient, rfed.channel destData) pair for use from a
    /// background thread.  Returns nil if either is unavailable.
    func rfedAppLinkSnapshot() -> (LxmfClient, Data)? {
        guard let destData = rfedLinkDestData ?? rfedChannelDestData(),
              let client = lxmfClient else { return nil }
        return (client, destData)
    }

    /// Public access to the rfed.channel destination derived from current
    /// preferences.  Used by the SettingsView status indicator to tell
    /// "no config" apart from "config present but no link".
    func rfedChannelDestDataPublic() -> Data? {
        return rfedChannelDestData()
    }

    /// True if the routing table currently has a path to the configured
    /// rfed.channel destination.  Used by the SettingsView status indicator
    /// to distinguish a transient "link not active yet" from a genuine
    /// "no path" failure.
    func rfedChannelHasPath() -> Bool {
        guard let destData = rfedChannelDestData() else { return false }
        return RetichatBridge.shared.transportHasPath(destHash: destData)
    }

    /// Wait for the rfed.channel app-link to reach ACTIVE (status == 3).
    /// Polls every 250 ms.  Safe to call from any context (re-enters MainActor
    /// for each status check).
    func waitForRfedAppLinkActive(timeoutSecs: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSecs)
        while Date() < deadline {
            if rfedNodeLinkStatus() == 3 { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Derives the rfed.channel 16-byte dest from current prefs.
    private func rfedChannelDestData() -> Data? {
        let identityHex = UserPreferences.shared.rfedNodeIdentityHash
        guard !identityHex.isEmpty else { return nil }
        let destHex = RfedChannelClient.rfedDestHash(
            identityHashHex: identityHex, app: "rfed", aspects: ["channel"])
        guard !destHex.isEmpty else { return nil }
        return Data(hexString: destHex)
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
        var destinations: [Data] = []
        if let propNode = PropagationNodeManager.shared.currentNode() {
            destinations.append(propNode)
        }
        for dest in [ApnsBridgeHashes.apnsRegistration, ApnsBridgeHashes.notifyRelay].compactMap({ $0 }) {
            destinations.append(dest)
        }
        let rfedHex = UserPreferences.shared.rfedNotifyHash
        if !rfedHex.isEmpty, let rfedHash = Data(hexString: rfedHex) {
            destinations.append(rfedHash)
        }
        // Also request paths to rfed.channel and rfed.delivery so the app
        // link has a fresh route immediately after network reconnect.
        if let rfedChannel = rfedChannelDestData() {
            destinations.append(rfedChannel)
        }
        let identityHex = UserPreferences.shared.rfedNodeIdentityHash
        if !identityHex.isEmpty {
            let deliveryHex = RfedChannelClient.rfedDestHash(
                identityHashHex: identityHex, app: "rfed", aspects: ["delivery"])
            if !deliveryHex.isEmpty, let deliveryHash = Data(hexString: deliveryHex) {
                destinations.append(deliveryHash)
            }
        }

        // Pre-compute hex labels on the main actor before going off-thread.
        let destPairs: [(Data, String)] = destinations.map { ($0, String($0.hexString.prefix(8))) }
        let bridge = RetichatBridge.shared
        let persistQueue = self.persistQueue

        // All FFI work off the main thread.
        Task.detached(priority: .userInitiated) {
            let t = CFAbsoluteTimeGetCurrent()
            print("[DIAG][requestEssentialPaths] task start count=\(destPairs.count)")
            var requested: [(Data, String)] = []
            for (dest, label) in destPairs {
                let hasPath = bridge.transportHasPath(destHash: dest)
                print("[DIAG][requestEssentialPaths] dest=\(label) hasPath=\(hasPath)")
                if !hasPath {
                    _ = bridge.transportRequestPath(destHash: dest)
                    print("[DIAG][requestEssentialPaths] requestPath done dest=\(label)")
                    requested.append((dest, label))
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
                requested.removeAll { dest, label in
                    if bridge.transportHasPath(destHash: dest) {
                        print("[DIAG][requestEssentialPaths] resolved dest=\(label)")
                        resolvedAny = true
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
                print("[DIAG][requestEssentialPaths] no essentials resolved before timeout; skipping persist")
            }
        }
    }
}
