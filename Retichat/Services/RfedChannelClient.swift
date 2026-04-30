//
//  RfedChannelClient.swift
//  Retichat
//
//  Pub-sub channel messaging via the RFed federation server.
//
//  ============================================================================
//  CHANNEL MESSAGES ARE LXMF PACKAGES.
//  ============================================================================
//  The `inner_blob` for a channel message is the EXACT SAME byte format an
//  LXMF propagation node stores and delivers — i.e. the output of
//  `LXMessage::pack(PROPAGATED)` starting at the destination_hash:
//
//      lxmf_data = [ channel_hash(16) | EC_encrypted(
//                        source_hash (16) || signature (64) || msgpack_payload
//                    ) ]
//
//  Decode it with `LXMessage::unpack_from_bytes(_, Some(PROPAGATED))` (exposed
//  via `RetichatBridge.channelLxmUnpack`). That call EC-decrypts using the
//  channel identity (derived deterministically from the channel name) and
//  validates the Ed25519 signature against the sender's identity from
//  Reticulum's known-destinations cache. If you can't prove who the message
//  is from, `signatureValidated == false` and the message is rejected.
//
//  Architecture:
//    SEND   → fire-and-forget DATA packet to rfed.channel dest
//             payload: lxmf_data [| pow_stamp(32)]
//             (lxmf_data already begins with the channel_hash; no extra
//              channel_hash prefix is added — the legacy
//              [channel_hash | inner_blob | stamp] layout is byte-equivalent.)
//    SUB    → link request /rfed/subscribe on rfed.channel, payload: msgpack bin(16)
//    UNSUB  → link request /rfed/unsubscribe on rfed.channel, payload: msgpack bin(16)
//    RECV   → inbound DATA at local rfed.delivery dest. Server hands us
//             [channel_hash(16) | inner_blob] — concatenate them and feed
//             the result to channelLxmUnpack as a complete lxmf_data.
//    PULL   → link request /rfed/pull on rfed.delivery, response: [[bin16, blob], ...]
//  ============================================================================
//

import Foundation
import Combine
import SwiftData
import CryptoKit

@MainActor
final class RfedChannelClient: ObservableObject, RfedBlobCallback {

    // MARK: - Node link status (shown in SettingsView)

    enum NodeStatus: Equatable {
        case unknown
        case establishing
        case connected
        case unreachable
    }

    // MARK: - Published state

    @Published var channels: [Channel] = []
    @Published var messages: [String: [ChannelMessage]] = [:]   // keyed by channelHash hex
    /// Monotonically increments each time the rfed link transitions INTO
    /// `.connected` from any other state.  Channel-view code uses this as
    /// the dedup key for the automatic first-open PULL: it pulls once per
    /// link establishment per channel, not once per chat-screen open.
    @Published var rfedLinkGeneration: Int = 0

    @Published var rfedNodeStatus: NodeStatus = .unknown

    /// Whether the rfed node *might* still have pending deferred blobs queued
    /// for this subscriber.  Keyed by the rfed node hash hex (since `/rfed/pull`
    /// is per-node, not per-channel).  `nil` (or `true`) means "user may try a
    /// PULL"; `false` means the last PULL returned `more_pending=false` so the
    /// UI hides the page-load action until something happens to suggest more
    /// blobs may have arrived (channel re-open, app foreground, etc.).
    @Published var canPullMore: [String: Bool] = [:]

    /// True while a `/rfed/pull` request is in flight for the given node.
    /// UI uses this to disable the page-load button to prevent double taps.
    @Published var pullInFlight: [String: Bool] = [:]

    private var linkStatusTimer: AnyCancellable?

    // MARK: - Dependencies

    private let bridge = RetichatBridge.shared
    private let prefs  = UserPreferences.shared

    private var modelContext: ModelContext?
    private var identityHandle: UInt64 = 0
    private var ownHashHex: String = ""

    /// Blobs that failed decryption — keyed by a cheap hash to avoid
    /// reprocessing the same undecryptable stored message on every delivery cycle.
    private var failedBlobKeys: Set<Int> = []

    /// Pre-decryption dedup of channel blobs. The propagation node mirrors the
    /// same encrypted blob to multiple subscribers, so the inner ciphertext is
    /// byte-identical across duplicate deliveries (same ephemeral_pub). Keying
    /// dedup on `(channelHash, blob)` short-circuits the X25519+HKDF+AEAD
    /// decrypt + LXMF unpack + signature verify pipeline for repeats — about
    /// a 3-5× CPU saving on busy channels (observed in 2026-04 log audit).
    private var seenBlobKeys: Set<Int> = []
    /// FIFO eviction queue paired with `seenBlobKeys` to bound memory.
    private var seenBlobOrder: [Int] = []
    private let seenBlobCap = 512

    // MARK: - Configuration

    func configure(modelContext: ModelContext, identityHandle: UInt64, ownHashHex: String) {
        self.modelContext = modelContext
        self.identityHandle = identityHandle
        self.ownHashHex = ownHashHex
    }

    // MARK: - Lifecycle

    func start() {
        guard identityHandle != 0 else { return }
        let ok = bridge.startRfedDelivery(identityHandle: identityHandle, callback: self)
        if ok {
            _ = bridge.rfedDeliveryAnnounce()
            print("[RfedChannel] Delivery endpoint started and announced")
        } else {
            let err = bridge.lastError() ?? "unknown"
            print("[RfedChannel] Failed to start delivery endpoint: \(err)")
        }
        loadPersistedChannels()
        loadPersistedMessages()
        resubscribePersistedChannels()
    }

    func stop() {
        bridge.stopRfedDelivery()
        stopRfedLinkMonitor()
    }

    func announceDelivery() {
        _ = bridge.rfedDeliveryAnnounce()
    }

    // MARK: - RFed node link status monitor

    /// Refcount: how many UI surfaces currently want live link-status updates.
    /// `retainRfedLinkMonitor` increments and starts the timer if needed;
    /// `releaseRfedLinkMonitor` decrements and stops the timer when it falls
    /// to zero.  This lets multiple views (Settings + channel chat) request
    /// monitoring concurrently without one cancelling the other's updates.
    private var linkMonitorRetainCount: Int = 0

    /// Start polling the app-link status every 3 s (while SettingsView is visible).
    /// The actual link is managed by ConnectionStateManager (opened/closed with app foreground).
    func startRfedLinkMonitor() {
        retainRfedLinkMonitor()
    }

    /// Stop polling (SettingsView disappeared).
    func stopRfedLinkMonitor() {
        releaseRfedLinkMonitor()
    }

    /// Increment the monitor refcount, starting the timer on the first retain.
    func retainRfedLinkMonitor() {
        linkMonitorRetainCount += 1
        guard linkMonitorRetainCount == 1 else { return }
        refreshRfedNodeStatus()
        linkStatusTimer?.cancel()
        linkStatusTimer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshRfedNodeStatus() }
    }

    /// Decrement the monitor refcount, stopping the timer on the final release.
    func releaseRfedLinkMonitor() {
        guard linkMonitorRetainCount > 0 else { return }
        linkMonitorRetainCount -= 1
        if linkMonitorRetainCount == 0 {
            linkStatusTimer?.cancel()
            linkStatusTimer = nil
        }
    }

    private func refreshRfedNodeStatus() {
        // appLinkStatus: 0=NONE, 1=PATH_REQUESTED, 2=ESTABLISHING, 3=ACTIVE, 4=DISCONNECTED.
        //
        // Semantics for the SettingsView pill:
        //   .unknown      → no rfed node configured (pill hidden)
        //   .establishing → config present, link not active (pill: "Linking…")
        //   .connected    → link ACTIVE (pill: "Linked")
        //   .unreachable  → config present but no path AND not currently
        //                   trying — i.e. genuine "No path" (pill: "No path")
        //
        // We collapse 0/1/2/4 onto .establishing when config exists because
        // appLinkStatus does not distinguish "trying" from "last attempt
        // failed" — DISCONNECTED reliably resolves once the next announce
        // arrives.  True .unreachable is reserved for the case where the
        // configured destination has no path in the routing table at all.
        let csm = ConnectionStateManager.shared
        let raw = csm.rfedNodeLinkStatus()
        let configured = csm.rfedChannelDestDataPublic() != nil
        let next: NodeStatus
        if !configured {
            next = .unknown
        } else if raw == 3 {
            next = .connected
        } else if !csm.rfedChannelHasPath() {
            next = .unreachable
        } else {
            next = .establishing
        }
        let wasConnected = rfedNodeStatus == .connected
        rfedNodeStatus = next
        // Bump the generation only on a fresh transition into .connected so
        // observers can fire link-establishment side effects (e.g. PULL)
        // exactly once per link.
        if next == .connected && !wasConnected {
            rfedLinkGeneration &+= 1
        }
    }

    // MARK: - Channel management

    /// Join (or create) a channel. Derives the channel hash from the name, subscribes
    /// on the rfed node, and persists the channel locally.
    func joinChannel(name: String, rfedNodeIdentityHashHex: String) async throws -> Channel {
        let channelHashData = try Self.channelHash(name: name)
        let channelHashHex = channelHashData.hexString

        let rfedChannelDestHex = Self.rfedDestHash(identityHashHex: rfedNodeIdentityHashHex,
                                                    app: "rfed", aspects: ["channel"])

        // Already joined? If the rfed node changed, update the stored hash and re-subscribe.
        if let existing = channels.first(where: { $0.id == channelHashHex }) {
            if existing.rfedNodeHash == rfedChannelDestHex {
                return existing
            }
            // Node hash changed — update in-memory and DB, then fall through to re-subscribe
            if let ctx = modelContext,
               let entity = try? ctx.fetch(FetchDescriptor<ChannelEntity>(
                   predicate: #Predicate { $0.channelHash == channelHashHex }
               )).first {
                entity.rfedNodeHash = rfedChannelDestHex
                try? ctx.save()
            }
            channels = channels.map { ch in
                ch.id == channelHashHex ? Channel(id: ch.id, channelName: ch.channelName,
                    rfedNodeHash: rfedChannelDestHex,
                    lastMessageTime: ch.lastMessageTime, isSubscribed: ch.isSubscribed,
                    stampCost: ch.stampCost) : ch
            }
        }
        guard let rfedChannelDest = Data(hexString: rfedChannelDestHex) else {
            throw ChannelError.invalidRfedNode
        }

        // Subscribe on the server (background thread, blocking)
        let stampCost = try await subscribeOnServer(channelHashData: channelHashData,
                                                    rfedChannelDest: rfedChannelDest)

        // Push wakeups are opt-in — do not register on join; user enables via Channel Info.
        // (No-op: channelPushEnabled defaults to absent/false for new channels.)

        // Persist (only insert if not already in DB — update case handled above)
        if let ctx = modelContext,
           (try? ctx.fetch(FetchDescriptor<ChannelEntity>(
               predicate: #Predicate { $0.channelHash == channelHashHex }
           )).isEmpty) == true {
            // Channel.lastMessageTime is stored in seconds (Apple epoch) so it
            // sorts directly against Chat.lastMessageTime.
            let now = Date().timeIntervalSince1970
            let entity = ChannelEntity(channelHash: channelHashHex, channelName: name,
                                       rfedNodeHash: rfedChannelDestHex, lastMessageTime: now,
                                       isSubscribed: true, stampCost: stampCost)
            ctx.insert(entity)
            try ctx.save()
        } else if let ctx = modelContext,
                  let entity = try? ctx.fetch(FetchDescriptor<ChannelEntity>(
                      predicate: #Predicate { $0.channelHash == channelHashHex }
                  )).first {
            // Update stamp_cost on re-subscribe (node config may have changed)
            entity.stampCost = stampCost
            try? ctx.save()
        }

        if let existing = channels.first(where: { $0.id == channelHashHex }) {
            return existing
        }

        let channel = Channel(id: channelHashHex, channelName: name,
                              rfedNodeHash: rfedChannelDestHex,
                              lastMessageTime: Date().timeIntervalSince1970,
                              isSubscribed: true, stampCost: stampCost)
        channels.append(channel)
        return channel
    }

    /// Leave a channel. Unsubscribes from the rfed node and removes local data.
    func leaveChannel(channelHashHex: String) async {
        guard let channel = channels.first(where: { $0.id == channelHashHex }) else { return }
        guard let channelHashData = Data(hexString: channelHashHex),
              let rfedDest = Data(hexString: channel.rfedNodeHash) else { return }

        let pubkey = bridge.identityPublicKey(handle: identityHandle)
        let sig    = pubkey != nil ? bridge.identitySign(handle: identityHandle, data: channelHashData) : nil
        let payload: Data
        if let pk = pubkey, let s = sig {
            payload = Self.msgpackSigned(value: channelHashData, pubkey: pk, sig: s)
        } else {
            payload = Self.msgpackBin(channelHashData)
        }
        Task.detached(priority: .background) { [bridge = self.bridge, handle = identityHandle] in
            _ = bridge.linkRequest(destHash: rfedDest, appName: "rfed", aspects: "channel",
                                   identityHandle: handle, path: "/rfed/unsubscribe",
                                   payload: payload, timeoutSecs: 10.0)
        }

        // Deregister per-channel push notification wakeup.
        let rfedNotifyHashHex = Self.rfedDestHash(identityHashHex: prefs.rfedNodeIdentityHash,
                                                  app: "rfed", aspects: ["notify"])
        if let channelHashForNotify = Data(hexString: channelHashHex), !rfedNotifyHashHex.isEmpty {
            RfedNotifyRegistrar.shared.deregisterForChannel(channelHash: channelHashForNotify,
                                                            rfedNotifyHashHex: rfedNotifyHashHex,
                                                            identityHandle: identityHandle)
        }

        // Remove from DB
        if let ctx = modelContext {
            let hash = channelHashHex
            if let entity = try? ctx.fetch(FetchDescriptor<ChannelEntity>(
                predicate: #Predicate { $0.channelHash == hash }
            )).first {
                ctx.delete(entity)
                try? ctx.save()
            }
            // Remove messages
            let msgEntities = (try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>(
                predicate: #Predicate { $0.channelHash == hash }
            ))) ?? []
            for e in msgEntities { ctx.delete(e) }
            try? ctx.save()
        }

        channels.removeAll { $0.id == channelHashHex }
        messages[channelHashHex] = nil
    }

    // MARK: - Per-channel push toggle

    /// Enable push wakeups for a channel: saves the pref and registers with rfed.notify.
    func enableChannelPush(channelHashHex: String) {
        UserPreferences.shared.enableChannelPush(channelHashHex)
        guard let channelHashData = Data(hexString: channelHashHex) else { return }
        let rfedNotifyHashHex = Self.rfedDestHash(identityHashHex: prefs.rfedNodeIdentityHash,
                                                   app: "rfed", aspects: ["notify"])
        guard !rfedNotifyHashHex.isEmpty else { return }
        RfedNotifyRegistrar.shared.registerForChannel(channelHash: channelHashData,
                                                       rfedNotifyHashHex: rfedNotifyHashHex,
                                                       identityHandle: identityHandle)
    }

    /// Disable push wakeups for a channel: saves the pref and deregisters from rfed.notify.
    func disableChannelPush(channelHashHex: String) {
        UserPreferences.shared.disableChannelPush(channelHashHex)
        guard let channelHashData = Data(hexString: channelHashHex) else { return }
        let rfedNotifyHashHex = Self.rfedDestHash(identityHashHex: prefs.rfedNodeIdentityHash,
                                                   app: "rfed", aspects: ["notify"])
        guard !rfedNotifyHashHex.isEmpty else { return }
        RfedNotifyRegistrar.shared.deregisterForChannel(channelHash: channelHashData,
                                                         rfedNotifyHashHex: rfedNotifyHashHex,
                                                         identityHandle: identityHandle)
    }

    // MARK: - Send

    // ── PoW STAMP CONTRACT (DO NOT BREAK — see config.rs HISTORICAL FAILURE MODES) ──
    //
    // Wire payload sent to rfed.channel:
    //     [ channel_id_hash(16) | EC_encrypted_tail | stamp(32) ]
    //
    // The rfed node validates the stamp as:
    //     transient_id = sha256(channel_id_hash || EC_encrypted_tail)
    //     workblock    = full_hash · expand(16)
    //     stamp_value(workblock, stamp) >= (stamp_cost - stamp_flexibility)
    //
    // The cost we pass to the FFI MUST equal the `stamp_cost` returned by
    // the rfed node's `/rfed/subscribe` response — that is the only
    // authoritative value. The cached `Channel.stampCost` may be stale
    // if the operator changed the node config, so we ALWAYS refresh it
    // from the server before the first send of a session, and ALWAYS
    // refresh + retry on a stamp-rejection failure. There is no other
    // way to learn the cost — rfed announces do not currently carry it.

    /// Refresh `stampCost` from the server by re-issuing /rfed/subscribe.
    /// Updates the in-memory `channels` array AND the persisted entity.
    /// Returns the freshly-fetched value (nil = no stamp required).
    @discardableResult
    private func refreshStampCost(for channel: Channel) async throws -> Int? {
        guard let channelHashData = Data(hexString: channel.id),
              let rfedChannelDest = Data(hexString: channel.rfedNodeHash) else {
            throw ChannelError.invalidRfedNode
        }
        let fresh = try await subscribeOnServer(channelHashData: channelHashData,
                                                 rfedChannelDest: rfedChannelDest)
        if fresh != channel.stampCost {
            print("[RfedChannel] stampCost refreshed for \(channel.channelName): \(channel.stampCost.map(String.init) ?? "nil") → \(fresh.map(String.init) ?? "nil")")
        }
        if let ctx = modelContext,
           let entity = try? ctx.fetch(FetchDescriptor<ChannelEntity>(
               predicate: { let cid = channel.id; return #Predicate { $0.channelHash == cid } }()
           )).first {
            entity.stampCost = fresh
            try? ctx.save()
        }
        channels = channels.map { ch in
            ch.id == channel.id ? Channel(id: ch.id, channelName: ch.channelName,
                rfedNodeHash: ch.rfedNodeHash, lastMessageTime: ch.lastMessageTime,
                isSubscribed: ch.isSubscribed, stampCost: fresh) : ch
        }
        return fresh
    }

    /// Channel IDs whose stampCost has been refreshed at least once this
    /// app session. Ensures the first SEND on a channel always carries a
    /// stamp built against the live node config rather than a stale value
    /// from disk (e.g. operator bumped stamp_cost while the app was off).
    private var stampCostRefreshedThisSession: Set<String> = []

    func sendMessage(content: String, toChannel channel: Channel) {
        Task { await self.sendMessageAsync(content: content, toChannel: channel) }
    }

    private func sendMessageAsync(content: String, toChannel channel: Channel) async {
        // --- Optimistic bubble: insert IMMEDIATELY in `pending` so the user
        // sees the message and a “sending” indicator without waiting on the
        // PoW stamp + FFI hop. We update its state in place once trySend
        // resolves. The id is a synthetic placeholder; on success it’s
        // replaced with the canonical sender_hex+lxmf_ts id so the echo
        // from RFed dedupes against it.
        let optimisticId = "pending_\(UUID().uuidString)"
        let optimisticTs = Date().timeIntervalSince1970 * 1000.0
        let optimisticEntity = ChannelMessageEntity(
            id: optimisticId, channelHash: channel.id,
            senderHash: ownHashHex, senderDisplayName: "",
            content: content, timestamp: optimisticTs, isOutgoing: true,
            deliveryState: DeliveryState.pending
        )
        modelContext?.insert(optimisticEntity)
        try? modelContext?.save()
        appendMessage(
            ChannelMessage(id: optimisticId, channelHash: channel.id,
                           senderHash: ownHashHex, senderDisplayName: "",
                           content: content, timestamp: optimisticTs, isOutgoing: true,
                           deliveryState: DeliveryState.pending),
            toChannelHash: channel.id
        )

        // Step 1: ensure stampCost is fresh for this session.  No persisted
        // stampCost is trusted across an app launch — operator may have
        // changed the node config.
        var liveChannel = channel
        if !stampCostRefreshedThisSession.contains(channel.id) {
            do {
                _ = try await refreshStampCost(for: channel)
                stampCostRefreshedThisSession.insert(channel.id)
                if let updated = channels.first(where: { $0.id == channel.id }) {
                    liveChannel = updated
                }
            } catch {
                print("[RfedChannel] stampCost refresh failed (\(error)) — sending with cached value \(channel.stampCost.map(String.init) ?? "nil")")
            }
        }

        if await trySend(content: content, toChannel: liveChannel, optimisticId: optimisticId) {
            return
        }

        // Step 2: a single retry after forcing a stampCost refresh.  This
        // covers the edge case where the operator changed the cost mid-session.
        print("[RfedChannel] SEND failed once — refreshing stampCost and retrying")
        do {
            _ = try await refreshStampCost(for: liveChannel)
            stampCostRefreshedThisSession.insert(liveChannel.id)
            if let updated = channels.first(where: { $0.id == liveChannel.id }) {
                liveChannel = updated
            }
        } catch {
            print("[RfedChannel] stampCost refresh on retry failed: \(error)")
            markOptimisticFailed(optimisticId: optimisticId, channelHash: channel.id)
            return
        }
        if !(await trySend(content: content, toChannel: liveChannel, optimisticId: optimisticId)) {
            markOptimisticFailed(optimisticId: optimisticId, channelHash: channel.id)
        }
    }

    /// Mark the optimistic entity (and its in-memory copy) as `failed`.
    /// Called from any terminal SEND error path so the user sees the red
    /// xmark indicator instead of an indefinite “sending” clock.
    private func markOptimisticFailed(optimisticId: String, channelHash: String) {
        if let ctx = modelContext,
           let temp = try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>(
               predicate: { let oid = optimisticId; return #Predicate { $0.id == oid } }()
           )).first {
            temp.deliveryState = DeliveryState.failed
            try? ctx.save()
        }
        if var list = messages[channelHash],
           let idx = list.firstIndex(where: { $0.id == optimisticId }) {
            list[idx].deliveryState = DeliveryState.failed
            messages[channelHash] = list
        }
    }

    /// Build the wire payload, compute the stamp, and ship it.  Returns
    /// false if any step that would produce a server-rejected packet fails
    /// (so the caller can refresh stampCost and retry).  On a successful
    /// transmission the optimistic entity identified by `optimisticId` is
    /// upgraded in place to the canonical `sender_hex+lxmf_ts` id with
    /// `deliveryState = sent` (so the echo from RFed dedupes against it
    /// in `dispatchVerifiedLxmf`).
    private func trySend(content: String, toChannel channel: Channel,
                          optimisticId: String) async -> Bool {
        // Build the wire payload as an LXMF-authenticated channel message.
        // The FFI returns both the on-wire bytes AND the LXMF timestamp it
        // baked into the signed body — we use the same timestamp as the
        // canonical id so the echo back from RFed dedupes cleanly against
        // the optimistic entity (after we rename it).
        let contentData = Data(content.utf8)
        guard let packed = bridge.channelLxmPack(name: channel.channelName,
                                                  senderIdentityHandle: identityHandle,
                                                  content: contentData,
                                                  title: Data()) else {
            print("[RfedChannel] LXMF pack failed: \(bridge.lastError() ?? "unknown")")
            return false
        }
        let lxmfData = packed.wirePayload
        let tsMs = packed.timestampMs

        guard lxmfData.count >= 16,
              lxmfData.prefix(16).hexString.lowercased() == channel.id.lowercased() else {
            print("[RfedChannel] LXMF pack produced wrong channel_id_hash prefix")
            return false
        }

        var payload = lxmfData
        if let cost = channel.stampCost, cost > 0 {
            // The rfed node REQUIRES a stamp at this cost. If FFI returns
            // nil it means the PoW search exhausted its iteration cap — we
            // refuse to ship a packet we know will be rejected.
            guard let stamp = bridge.channelComputeStamp(payload: payload, cost: Int32(cost)) else {
                print("[RfedChannel] STAMP COMPUTE FAILED for cost=\(cost): \(bridge.lastError() ?? "unknown") — aborting send")
                return false
            }
            payload += stamp
            print("[RfedChannel] stamp computed (cost=\(cost), stamp_bytes=\(stamp.count), payload_bytes=\(payload.count))")
        }

        let ok = bridge.packetSendToHash(destHash: Data(hexString: channel.rfedNodeHash)!,
                                          appName: "rfed", aspects: "channel",
                                          payload: payload)
        if !ok {
            print("[RfedChannel] Send failed: \(bridge.lastError() ?? "unknown")")
            return false
        }

        // SEND succeeded — upgrade the optimistic entity in place to the
        // canonical id (sender_hex+lxmf_ts) and mark it `sent` (= published
        // to RFed). Using the same id format as `dispatchVerifiedLxmf` so
        // the inevitable echo from RFed is suppressed by dedup.
        let canonicalId = (Data(hexString: ownHashHex) ?? Data()).hexString
            + String(format: "%016llx", tsMs)
        if let ctx = modelContext {
            // If a previous trySend attempt already promoted this entity,
            // or if the echo from a prior send beat us here, just leave the
            // existing canonical entity alone.
            let existing = (try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>(
                predicate: { let cid = canonicalId; return #Predicate { $0.id == cid } }()
            )))?.first
            if existing == nil,
               let temp = try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>(
                   predicate: { let oid = optimisticId; return #Predicate { $0.id == oid } }()
               )).first {
                temp.id = canonicalId
                temp.timestamp = Double(tsMs)
                temp.deliveryState = DeliveryState.sent
                try? ctx.save()
            } else if let existing {
                existing.deliveryState = DeliveryState.sent
                if let temp = try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>(
                    predicate: { let oid = optimisticId; return #Predicate { $0.id == oid } }()
                )).first {
                    ctx.delete(temp)
                }
                try? ctx.save()
            }
        }
        if var list = messages[channel.id] {
            if let idx = list.firstIndex(where: { $0.id == optimisticId }) {
                if list.contains(where: { $0.id == canonicalId }) {
                    // Echo already arrived; drop optimistic placeholder.
                    list.remove(at: idx)
                } else {
                    var upgraded = list[idx]
                    list.remove(at: idx)
                    list.append(ChannelMessage(
                        id: canonicalId, channelHash: upgraded.channelHash,
                        senderHash: upgraded.senderHash,
                        senderDisplayName: upgraded.senderDisplayName,
                        content: upgraded.content, timestamp: Double(tsMs),
                        isOutgoing: true,
                        deliveryState: DeliveryState.sent
                    ))
                    list.sort { $0.timestamp < $1.timestamp }
                    _ = upgraded
                }
                messages[channel.id] = list
            }
        }
        updateChannelLastMessage(channelHashHex: channel.id, time: Double(tsMs))
        return true
    }

    // MARK: - Pull deferred blobs (user-initiated paging)
    //
    // PULL is the page-loaded counterpart to chat-history "Load earlier
    // messages": the user taps a button, we drain one page from the rfed
    // node's deferred queue, dispatch the blobs, and update `canPullMore`
    // from the server's `more_pending` flag so the UI knows whether to
    // keep offering the action.
    //
    // Server wire format: msgpack 2-fixarray
    //     [ Array([ [bin(16) channel_hash, bin(*) blob], ... ]),
    //       Bool more_pending ]
    //
    // Returns `true` if the server reports more entries remain, `false`
    // otherwise (or on error — caller can retry the next page-load).
    @discardableResult
    func pullDeferred(channel: Channel) async -> Bool {
        let nodeKey = channel.rfedNodeHash
        guard let rfedDeliveryDest = Data(hexString: Self.rfedDestHash(
            identityHashHex: rfedIdentityHashFromChannelDest(nodeKey),
            app: "rfed", aspects: ["delivery"]
        )) else { return false }

        await MainActor.run { self.pullInFlight[nodeKey] = true }
        defer {
            Task { @MainActor in self.pullInFlight[nodeKey] = false }
        }

        let handle = identityHandle
        let bridge = self.bridge

        let response = await Task.detached(priority: .background) {
            bridge.linkRequest(destHash: rfedDeliveryDest, appName: "rfed", aspects: "delivery",
                               identityHandle: handle, path: "/rfed/pull",
                               payload: Data(), timeoutSecs: 15.0)
        }.value

        guard let data = response else {
            print("[RfedChannel] PULL: no response or error")
            return false
        }

        guard let decoded = Self.decodePullResponse(data) else {
            print("[RfedChannel] PULL: malformed response (\(data.count) bytes)")
            return false
        }
        let (pairs, morePending) = decoded
        print("[RfedChannel] PULL: drained \(pairs.count) blob(s), more_pending=\(morePending)")

        for (channelHashData, blob) in pairs {
            await MainActor.run {
                self.dispatchBlob(channelHashHex: channelHashData.hexString, blob: blob)
            }
        }

        await MainActor.run { self.canPullMore[nodeKey] = morePending }
        return morePending
    }

    // MARK: - RfedBlobCallback

    /// Called on a background thread by the Rust delivery endpoint.
    nonisolated func onRfedBlob(_ blob: Data) {
        // Blob format from server: channel_hash(16) | inner_blob(*)
        print("[RfedChannel] onRfedBlob total_bytes=\(blob.count)")
        guard blob.count > 16 else {
            print("[RfedChannel] onRfedBlob DROPPED: too short (\(blob.count) bytes)")
            return
        }
        let channelHashData = blob.prefix(16)
        let innerBlob = blob.dropFirst(16)
        let channelHashHex = channelHashData.hexString
        print("[RfedChannel] onRfedBlob channel_hash=\(channelHashHex) inner_bytes=\(innerBlob.count)")

        Task { @MainActor in
            self.dispatchBlob(channelHashHex: channelHashHex, blob: Data(innerBlob))
        }
    }

    // MARK: - Private

    private func dispatchBlob(channelHashHex: String, blob: Data) {
        // Skip if this channel is not known
        guard let channel = channels.first(where: { $0.id == channelHashHex }) else {
            let known = channels.map { $0.id.prefix(8) }.joined(separator: ", ")
            print("[RfedChannel] dispatchBlob NO MATCH channel=\(channelHashHex.prefix(16)) known=[\(known)]")
            return
        }

        // Pre-decryption dedup. Same encrypted blob from the propagation node
        // (mirrored to multiple subscribers) hits us multiple times with
        // byte-identical ciphertext. Drop here, before the expensive crypto.
        let blobKey = channelHashHex.hashValue &+ blob.hashValue
        if seenBlobKeys.contains(blobKey) {
            print("[RfedChannel] dispatchBlob PRE-DEDUP channel=\(channelHashHex.prefix(16)) blob_bytes=\(blob.count)")
            return
        }
        seenBlobKeys.insert(blobKey)
        seenBlobOrder.append(blobKey)
        if seenBlobOrder.count > seenBlobCap {
            let evict = seenBlobOrder.removeFirst()
            seenBlobKeys.remove(evict)
        }

        print("[RfedChannel] dispatchBlob MATCHED channel=\(channelHashHex.prefix(16)) name=\(channel.channelName) blob_bytes=\(blob.count)")

        // Reconstruct the full LXMF lxmf_data: [channel_hash(16) | inner_blob]
        // and feed it through the LXMF unpacker. This validates the Ed25519
        // signature against the sender identity from Reticulum's known-
        // destinations cache. If the sender hasn't been seen via an announce
        // (signatureValidated == false, reason == SOURCE_UNKNOWN) we drop the
        // message — we cannot prove who it's from.
        guard let channelHashData = Data(hexString: channelHashHex) else { return }
        let lxmfData = channelHashData + blob

        guard let result = bridge.channelLxmUnpack(name: channel.channelName, lxmfData: lxmfData) else {
            let blobKey = channelHashHex.hashValue &+ blob.hashValue
            if !failedBlobKeys.contains(blobKey) {
                failedBlobKeys.insert(blobKey)
                print("[RfedChannel] dispatchBlob LXMF unpack FAILED (lxmf_bytes=\(lxmfData.count), err=\(bridge.lastError() ?? "?"), suppressing repeats)")
            }
            return
        }

        guard result.signatureValidated else {
            let reasonStr: String
            switch result.unverifiedReason {
            case 1: reasonStr = "SOURCE_UNKNOWN (sender not yet announced)"
            case 2: reasonStr = "SIGNATURE_INVALID"
            default: reasonStr = "code=\(result.unverifiedReason)"
            }
            print("[RfedChannel] dispatchBlob REJECTED unsigned message: \(reasonStr) sender=\(result.sourceHash.hexString.prefix(8))")
            return
        }

        print("[RfedChannel] dispatchBlob unpack OK source=\(result.sourceHash.hexString.prefix(8)) ts_ms=\(result.timestampMs) content_bytes=\(result.content.count) sig_ok=true")
        dispatchVerifiedLxmf(channelHashHex: channelHashHex, result: result)
    }

    /// Dispatch a successfully signature-verified LXMF channel message.
    private func dispatchVerifiedLxmf(channelHashHex: String, result: RetichatBridge.ChannelLxmUnpackResult) {
        let senderHashHex = result.sourceHash.hexString
        let tsMs = result.timestampMs
        guard let content = String(data: result.content, encoding: .utf8) else {
            print("[RfedChannel] dispatchVerifiedLxmf DROPPED: content not valid UTF-8")
            return
        }

        let msgId = senderHashHex + String(format: "%016llx", tsMs)
        let existingForChannel = messages[channelHashHex]?.contains(where: { $0.id == msgId }) ?? false
        guard !existingForChannel else {
            print("[RfedChannel] dispatchVerifiedLxmf DEDUP: msgId=\(msgId.prefix(16))")
            return
        }
        print("[RfedChannel] dispatchVerifiedLxmf DELIVERING sender=\(senderHashHex.prefix(8)) content='\(content.prefix(40))'")

        let isOutgoing = senderHashHex == ownHashHex
        let entity = ChannelMessageEntity(id: msgId, channelHash: channelHashHex,
                                          senderHash: senderHashHex, senderDisplayName: "",
                                          content: content,
                                          timestamp: Double(tsMs), isOutgoing: isOutgoing)
        modelContext?.insert(entity)
        try? modelContext?.save()

        let msg = ChannelMessage(id: msgId, channelHash: channelHashHex,
                                  senderHash: senderHashHex, senderDisplayName: "", content: content,
                                  timestamp: Double(tsMs), isOutgoing: isOutgoing)
        appendMessage(msg, toChannelHash: channelHashHex)
        // updateChannelLastMessage takes seconds; tsMs is wire-format ms.
        updateChannelLastMessage(channelHashHex: channelHashHex, time: Double(tsMs) / 1000.0)

        if !isOutgoing, let channel = channels.first(where: { $0.id == channelHashHex }),
           UserPreferences.shared.isChannelNotificationsEnabled(channelHashHex) {
            let senderLabel = senderHashHex.prefix(8) + "…"
            NotificationManager.shared.postMessageNotification(
                chatId: channelHashHex,
                senderName: "#\(channel.channelName) (\(senderLabel))",
                content: content
            )
        }
    }

    private func appendMessage(_ msg: ChannelMessage, toChannelHash hash: String) {
        var list = messages[hash] ?? []
        list.append(msg)
        list.sort { $0.timestamp < $1.timestamp }
        messages[hash] = list
    }

    private func updateChannelLastMessage(channelHashHex: String, time: Double) {
        if let idx = channels.firstIndex(where: { $0.id == channelHashHex }) {
            if time > channels[idx].lastMessageTime {
                channels[idx].lastMessageTime = time
            }
        }
        if let ctx = modelContext {
            let hash = channelHashHex
            if let entity = try? ctx.fetch(FetchDescriptor<ChannelEntity>(
                predicate: #Predicate { $0.channelHash == hash }
            )).first {
                entity.lastMessageTime = max(entity.lastMessageTime, time)
                try? ctx.save()
            }
        }
    }

    /// Returns the rfed node's stamp_cost (nil = no stamp required).
    @discardableResult
    private func subscribeOnServer(channelHashData: Data,
                                   rfedChannelDest: Data) async throws -> Int? {
        // Payload: fixarray-3 [bin(16) channel_hash, bin(64) pubkey, bin(64) sig]
        // sig = Ed25519(channel_hash). Server derives subscriber_hash from pubkey and
        // verifies the signature — no timing dependency on IDENTIFY.
        guard let pubkey = bridge.identityPublicKey(handle: identityHandle),
              let sig    = bridge.identitySign(handle: identityHandle, data: channelHashData) else {
            throw ChannelError.subscribeFailed("failed to sign subscribe payload")
        }
        let payload = Self.msgpackSigned(value: channelHashData, pubkey: pubkey, sig: sig)
        let handle = identityHandle
        let bridge = self.bridge

        // ---- Preferred path: multiplex onto the persistent rfed.channel APP_LINK ----
        //
        // Make sure the APP_LINK is opening, then wait up to 30 s for it to
        // become ACTIVE.  All channel subscribes share this single link
        // instead of opening one fresh outbound link per subscribe — this
        // eliminates the cold-start "thundering herd" of parallel link
        // establishments competing for the same long path.
        ConnectionStateManager.shared.openRfedNodeLink()
        let appLinkActive = await ConnectionStateManager.shared
            .waitForRfedAppLinkActive(timeoutSecs: 30.0)

        if appLinkActive,
           let snap = ConnectionStateManager.shared.rfedAppLinkSnapshot(),
           snap.1 == rfedChannelDest
        {
            let client = snap.0
            let response = await Task.detached(priority: .background) {
                client.appLinkRequest(destHash: rfedChannelDest,
                                      path: "/rfed/subscribe",
                                      payload: payload,
                                      timeoutSecs: 20.0)
            }.value
            if let resp = response {
                let stampCost: Int? = Self.parseSubscribeResponse(resp)
                guard stampCost != nil || resp.first == 0xc3
                        || resp.first == 0x92 || resp.first == 0x91 else {
                    throw ChannelError.subscribeFailed("unexpected response: \(resp.hexString)")
                }
                print("[RfedChannel] subscribe: used persistent APP_LINK")
                return stampCost
            }
            // Fall through to legacy path on failure.
            print("[RfedChannel] subscribe: APP_LINK request returned nil — falling back to one-shot link")
        } else {
            print("[RfedChannel] subscribe: APP_LINK not ACTIVE within timeout — using one-shot link")
        }

        // ---- Fallback: legacy one-shot link request ----
        // Ensure the rfed.channel destination is known before opening a link.
        let pathKnown = await Task.detached(priority: .background) { () -> Bool in
            if bridge.transportHasPath(destHash: rfedChannelDest) { return true }
            _ = bridge.transportRequestPath(destHash: rfedChannelDest)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                if bridge.transportHasPath(destHash: rfedChannelDest) { return true }
            }
            return false
        }.value

        guard pathKnown else {
            throw ChannelError.subscribeFailed("rfed node not reachable — no announce received")
        }

        let response = await Task.detached(priority: .background) {
            bridge.linkRequest(destHash: rfedChannelDest, appName: "rfed", aspects: "channel",
                               identityHandle: handle, path: "/rfed/subscribe",
                               payload: payload, timeoutSecs: 20.0)
        }.value

        guard let resp = response else {
            throw ChannelError.subscribeFailed("link request timed out or failed")
        }
        let stampCost: Int? = Self.parseSubscribeResponse(resp)
        guard stampCost != nil || resp.first == 0xc3 || resp.first == 0x92 || resp.first == 0x91 else {
            throw ChannelError.subscribeFailed("unexpected response: \(resp.hexString)")
        }
        return stampCost
    }

    /// Parse the subscribe response: `[bool, stamp_cost_or_nil]` or legacy `true`.
    /// Returns nil on failure or when stamp is disabled (nil in msgpack).
    private static func parseSubscribeResponse(_ data: Data) -> Int? {
        // Legacy: bare 0xc3 = msgpack true (no stamp info, server pre-stamp_cost feature)
        if data.count == 1, data.first == 0xc3 { return nil }
        // New format: fixarray of 2 elements [bool, stamp_cost_or_nil]
        //   byte 0 = 0x92 (fixarray-2)
        //   byte 1 = bool (0xc3 true / 0xc2 false)
        //   byte 2+ = stamp_cost (msgpack int or nil)
        guard data.count >= 3, data[0] == 0x92 else { return nil }
        let costByte = data[2]
        // msgpack nil
        if costByte == 0xc0 { return nil }
        // Positive fixint: 0x00..0x7f
        if costByte & 0x80 == 0 { return Int(costByte) }
        // uint8: 0xcc <value>
        if costByte == 0xcc, data.count >= 4 { return Int(data[3]) }
        // uint16: 0xcd <hi> <lo>
        if costByte == 0xcd, data.count >= 5 { return Int(data[3]) << 8 | Int(data[4]) }
        // uint32: 0xce <b0> <b1> <b2> <b3>
        if costByte == 0xce, data.count >= 7 {
            return Int(data[3]) << 24 | Int(data[4]) << 16 | Int(data[5]) << 8 | Int(data[6])
        }
        return nil
    }


    private func loadPersistedChannels() {
        guard let ctx = modelContext else { return }
        let entities = (try? ctx.fetch(FetchDescriptor<ChannelEntity>())) ?? []
        channels = entities.map {
            // Migrate legacy ms-encoded timestamps written before the unit
            // switch to seconds.  Anything > 1e11 cannot be a seconds-epoch
            // value within any plausible date (year 5138+) so it must be ms.
            let raw = $0.lastMessageTime
            let seconds = raw > 1e11 ? raw / 1000.0 : raw
            if seconds != raw { $0.lastMessageTime = seconds }
            return Channel(id: $0.channelHash, channelName: $0.channelName,
                    rfedNodeHash: $0.rfedNodeHash, lastMessageTime: seconds,
                    isSubscribed: $0.isSubscribed, stampCost: $0.stampCost)
        }
        try? ctx.save()
    }

    /// Re-subscribe to all channels that were subscribed before the app was killed.
    /// Called on start() so the rfed node delivers real-time blobs after a restart.
    private func resubscribePersistedChannels() {
        let toResub = channels.filter { $0.isSubscribed }
        guard !toResub.isEmpty else { return }
        print("[RfedChannel] Re-subscribing to \(toResub.count) persisted channel(s) after restart")
        Task {
            for channel in toResub {
                guard let channelHashData = Data(hexString: channel.id),
                      let rfedChannelDest  = Data(hexString: channel.rfedNodeHash) else { continue }
                do {
                    let stampCost = try await subscribeOnServer(channelHashData: channelHashData,
                                                               rfedChannelDest: rfedChannelDest)
                    // Update in-memory stamp cost if the server returns a different value.
                    if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
                        channels[idx] = Channel(id: channel.id, channelName: channel.channelName,
                                                rfedNodeHash: channel.rfedNodeHash,
                                                lastMessageTime: channel.lastMessageTime,
                                                isSubscribed: true, stampCost: stampCost)
                    }
                    print("[RfedChannel] Re-subscribed to \(channel.channelName) (stampCost=\(stampCost.map { "\($0)" } ?? "nil"))")
                    // Re-register per-channel notify so wakeups resume after app restart,
                    // but only if the user has push enabled for this channel.
                    if UserPreferences.shared.isChannelPushEnabled(channel.id) {
                        let rfedNotifyHashHex = Self.rfedDestHash(
                            identityHashHex: prefs.rfedNodeIdentityHash,
                            app: "rfed", aspects: ["notify"])
                        RfedNotifyRegistrar.shared.registerForChannel(
                            channelHash: channelHashData,
                            rfedNotifyHashHex: rfedNotifyHashHex,
                            identityHandle: identityHandle)
                    }
                } catch {
                    print("[RfedChannel] Re-subscribe failed for \(channel.channelName): \(error)")
                }
            }
        }
    }

    private func loadPersistedMessages() {
        guard let ctx = modelContext else { return }
        let entities = (try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>())) ?? []
        var grouped: [String: [ChannelMessage]] = [:]
        for e in entities {
            let msg = ChannelMessage(id: e.id, channelHash: e.channelHash,
                                     senderHash: e.senderHash, senderDisplayName: e.senderDisplayName,
                                     content: e.content,
                                     timestamp: e.timestamp, isOutgoing: e.isOutgoing,
                                     deliveryState: e.deliveryState)
            grouped[e.channelHash, default: []].append(msg)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.timestamp < $1.timestamp }
        }
        messages = grouped
    }

    /// Extract the rfed identity hash hex from a 32-char rfed.channel dest hash.
    /// This is not directly reversible — we store the rfed node identity hash in the channel's
    /// rfedNodeHash field as the rfed.channel dest hex (not the raw identity hash).
    /// For delivery PULL, we derive rfed.delivery from the same identity hash stored in prefs.
    private func rfedIdentityHashFromChannelDest(_ channelDestHex: String) -> String {
        return prefs.rfedNodeIdentityHash
    }

    // MARK: - Static helpers

    /// Derive the 16-byte channel hash from a channel name (mirrors Rust ChannelKeypair::hash).
    nonisolated static func channelHash(name: String) throws -> Data {
        let seed = Data(SHA256.hash(data: Data(name.utf8)))
        let x25519Pub = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
                            .publicKey.rawRepresentation
        let ed25519Pub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                            .publicKey.rawRepresentation
        let bundle = x25519Pub + ed25519Pub
        return Data(SHA256.hash(data: bundle).prefix(16))
    }

    /// Compute an RNS SINGLE-destination hash (mirrors Reticulum Destination::hash()).
    nonisolated static func rfedDestHash(identityHashHex: String, app: String, aspects: [String]) -> String {
        let hex = identityHashHex.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.count == 32, let identityBytes = Data(hexString: hex) else { return "" }
        let name = ([app] + aspects).joined(separator: ".")
        let nameHashFull = SHA256.hash(data: Data(name.utf8))
        let nameHashTrunc = Data(nameHashFull.prefix(10))
        let material = nameHashTrunc + identityBytes
        return Data(SHA256.hash(data: material).prefix(16)).hexString
    }

    /// Encode inner blob v2: 0x02 | senderHash(16) | timestampMS_BE(8) | nameLen_BE(2) | utf8name | utf8content
    nonisolated static func encodeBlob(senderHash: Data, senderDisplayName: String, content: String) -> Data {
        var blob = Data([0x02])
        let hash16 = senderHash.count >= 16 ? senderHash.prefix(16) : (senderHash + Data(repeating: 0, count: 16 - senderHash.count))
        blob.append(contentsOf: hash16)
        let tsMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var tsBytes = tsMs.bigEndian
        blob.append(contentsOf: withUnsafeBytes(of: &tsBytes) { Data($0) })
        let nameBytes = Data(senderDisplayName.utf8)
        let nameLen = UInt16(min(nameBytes.count, 255))
        var nameLenBytes = nameLen.bigEndian
        blob.append(contentsOf: withUnsafeBytes(of: &nameLenBytes) { Data($0) })
        blob.append(nameBytes.prefix(Int(nameLen)))
        blob.append(Data(content.utf8))
        return blob
    }

    /// Decode inner blob. Returns (senderHashHex, timestampMS, senderDisplayName, content) or nil.
    /// Handles both v1 (0x01, no display name) and v2 (0x02, display name embedded).
    /// Encode a value as msgpack bin8: 0xc4 | len | bytes
    nonisolated static func msgpackBin(_ data: Data) -> Data {
        var out = Data([0xc4, UInt8(data.count)])
        out.append(data)
        return out
    }

    /// Encode msgpack fixarray-3 [bin(value), bin(pubkey), bin(sig)].
    /// Used for all rfed requests that require proof of identity ownership.
    nonisolated static func msgpackSigned(value: Data, pubkey: Data, sig: Data) -> Data {
        var out = Data([0x93])   // fixarray of 3
        out.append(msgpackBin(value))
        out.append(msgpackBin(pubkey))
        out.append(msgpackBin(sig))
        return out
    }

    /// Decode a paged PULL response from `/rfed/pull`.
    ///
    /// Wire format: msgpack 2-element fixarray
    ///     `[ Array([ [bin(16), bin(*)], ... ]), Bool more_pending ]`
    ///
    /// Returns `nil` if the envelope is malformed.  Returns
    /// `(pairs, morePending)` on success.  Hand-rolled to avoid pulling in
    /// a full msgpack dependency for one decode.
    nonisolated static func decodePullResponse(_ data: Data) -> (pairs: [(Data, Data)], morePending: Bool)? {
        // Fixed-length read helpers.  `available(_:from:n:)` returns the slice
        // start..<start+n only if all `n` bytes lie within `data`; otherwise
        // nil.  This avoids the previous `limitedBy: endIndex` confusion where
        // the result was compared against `endIndex` instead of `nil`.
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
            case 0xc4:                                  // bin8
                guard let r = available(d, from: idx, n: 1) else { return nil }
                len = Int(d[r.lowerBound])
                idx = r.upperBound
            case 0xc5:                                  // bin16
                guard let r = available(d, from: idx, n: 2) else { return nil }
                len = (Int(d[r.lowerBound]) << 8) | Int(d[d.index(after: r.lowerBound)])
                idx = r.upperBound
            case 0xc6:                                  // bin32
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

        /// Read a msgpack array header at `idx` and return its element count.
        func readArrayCount(_ d: Data, _ idx: inout Data.Index) -> Int? {
            guard idx < d.endIndex else { return nil }
            let tag = d[idx]
            idx = d.index(after: idx)
            if tag & 0xf0 == 0x90 {                     // fixarray
                return Int(tag & 0x0f)
            } else if tag == 0xdc {                     // array16
                guard let r = available(d, from: idx, n: 2) else { return nil }
                let n = (Int(d[r.lowerBound]) << 8) | Int(d[d.index(after: r.lowerBound)])
                idx = r.upperBound
                return n
            } else if tag == 0xdd {                     // array32
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

        // Outer envelope: 2-element array [pairs, more_pending].
        guard let outerCount = readArrayCount(data, &i), outerCount == 2 else {
            return nil
        }

        // Inner array of [channel_hash, blob] pairs.
        guard let pairsCount = readArrayCount(data, &i) else { return nil }

        var pairs: [(Data, Data)] = []
        pairs.reserveCapacity(pairsCount)
        for _ in 0..<pairsCount {
            // Each element is a 2-element fixarray.
            guard let innerCount = readArrayCount(data, &i), innerCount == 2 else {
                return nil
            }
            guard let channelHash = readBin(data, &i),
                  let blob = readBin(data, &i) else { return nil }
            pairs.append((channelHash, blob))
        }

        // Trailing bool: msgpack `false` = 0xc2, `true` = 0xc3.
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
}

// MARK: - Errors

enum ChannelError: LocalizedError {
    case invalidRfedNode
    case subscribeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRfedNode:    return "Invalid rfed node identity hash in settings."
        case .subscribeFailed(let msg): return "Subscribe failed: \(msg)"
        }
    }
}
