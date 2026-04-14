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

    /// Destination hash of the currently-open conversation (nil when no chat is on screen).
    private(set) var activeConversationHash: Data? = nil

    /// Weak reference to the LXMF client, set after startup.
    private weak var lxmfClient: LxmfClient? = nil

    private init() {}

    // MARK: - Setup

    /// Call once after the LXMF stack has started.
    func register(lxmfClient: LxmfClient) {
        self.lxmfClient = lxmfClient
        requestEssentialPaths()
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

    /// Returns the LXMF delivery method to use when sending to a peer.
    /// Uses live link status — instant, no I/O.
    func deliveryMethod(for destHash: Data) -> UInt8 {
        let hex = destHash.hexString
        // Peer's direct link recently failed and they haven't re-announced → use prop.
        if degradedPeers.contains(hex) { return LxmfMethod.propagated }
        // A path exists in the routing table (peer has announced, route is known) → send direct.
        // Rust will establish a link on demand.  If direct delivery fails, onMessageState
        // catches 0xFF/0xFE/0xFD and retries via the propagation node.
        if RetichatBridge.shared.transportHasPath(destHash: destHash) { return LxmfMethod.direct }
        // No known path → use prop node and wait for peer to come online.
        return LxmfMethod.propagated
    }

    // MARK: - Conversation lifecycle

    /// Call when a conversation screen appears for a direct (non-group) chat.
    /// Triggers path discovery and watches for peer announces so we know
    /// when they come online.  Does nothing for group chats (pass nil).
    func openConversation(peerHash: Data) {
        activeConversationHash = peerHash
        RetichatBridge.shared.watchAnnounce(destHash: peerHash)
        lxmfClient?.watch(destHash: peerHash)
        let bridge = RetichatBridge.shared
        if !bridge.transportHasPath(destHash: peerHash) {
            _ = bridge.transportRequestPath(destHash: peerHash)
        }
    }

    /// Call when a conversation screen disappears.
    func closeConversation(peerHash: Data) {
        if activeConversationHash == peerHash {
            activeConversationHash = nil
        }
    }

    // MARK: - App lifecycle events

    /// Call when the app returns to foreground.
    /// Re-triggers path discovery for the active conversation peer (if any).
    func onAppForeground() {
        guard let peerHash = activeConversationHash else { return }
        openConversation(peerHash: peerHash)
    }

    /// Call when NWPathMonitor reports network connectivity restored.
    /// Re-requests paths to always-needed destinations and the active peer.
    func onNetworkReconnect() {
        requestEssentialPaths()
        if let peerHash = activeConversationHash {
            _ = RetichatBridge.shared.transportRequestPath(destHash: peerHash)
        }
    }

    // MARK: - Private

    /// Request Reticulum paths to destinations that the app always needs:
    /// the APNs bridge registration endpoint, its notify relay, and the
    /// configured RFed notify node.
    private func requestEssentialPaths() {
        let bridge = RetichatBridge.shared
        for dest in [ApnsBridgeHashes.apnsRegistration, ApnsBridgeHashes.notifyRelay].compactMap({ $0 }) {
            if !bridge.transportHasPath(destHash: dest) {
                _ = bridge.transportRequestPath(destHash: dest)
            }
        }
        let rfedHex = UserPreferences.shared.rfedNotifyHash
        if !rfedHex.isEmpty, let rfedHash = Data(hexString: rfedHex),
           !bridge.transportHasPath(destHash: rfedHash) {
            _ = bridge.transportRequestPath(destHash: rfedHash)
        }
    }
}
