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

    private init() {}

    // MARK: - Setup

    /// Call once after the LXMF stack has started.
    func register(lxmfClient: LxmfClient) {
        self.lxmfClient = lxmfClient

        // Register reconnect handlers for rfed.channel and rfed.notify so the
        // LXMF router re-establishes app-links to those destinations on announce.
        // (The built-in delivery_announce_handler only covers lxmf.delivery.)
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.channel")
        lxmfClient.appLinkRegisterReconnect(aspect: "rfed.notify")

        requestEssentialPaths()
        // Open the rfed.channel app-link immediately so the SettingsView
        // "RFed Node" status pill (which polls appLinkStatus on the
        // rfed.channel destination) reflects reality on first launch.
        // Without this the pill stayed at "No path" indefinitely on cold
        // start because openRfedNodeLink() only ran on onNetworkRecover.
        openRfedNodeLink()
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

    // MARK: - Conversation lifecycle

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
            client?.appLinkOpen(destData)
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

        // All FFI work off the main thread.
        Task.detached(priority: .userInitiated) {
            let t = CFAbsoluteTimeGetCurrent()
            print("[DIAG][requestEssentialPaths] task start count=\(destPairs.count)")
            for (dest, label) in destPairs {
                let hasPath = bridge.transportHasPath(destHash: dest)
                print("[DIAG][requestEssentialPaths] dest=\(label) hasPath=\(hasPath)")
                if !hasPath {
                    _ = bridge.transportRequestPath(destHash: dest)
                    print("[DIAG][requestEssentialPaths] requestPath done dest=\(label)")
                }
            }
            let took = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t)
            print("[DIAG][requestEssentialPaths] task done took=\(took)s")
        }
    }
}
