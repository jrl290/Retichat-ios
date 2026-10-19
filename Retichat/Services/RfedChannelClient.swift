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
//    SEND   → AppLinks DATA send on legacy rfed.channel compatibility dest
//             payload: lxmf_data [| pow_stamp(32)]
//             (lxmf_data already begins with the channel_hash; no extra
//              channel_hash prefix is added — the legacy
//              [channel_hash | inner_blob | stamp] layout is byte-equivalent.)
//    SUB    → AppLinks request /rfed/subscribe on legacy rfed.channel, payload: msgpack bin(16)
//    UNSUB  → AppLinks request /rfed/unsubscribe on legacy rfed.channel, payload: msgpack bin(16)
//    RECV   → live DATA over persistent rfed.channel.stream. Server hands us
//             [channel_hash(16) | inner_blob] — concatenate them and feed
//             the result to channelLxmUnpack as a complete lxmf_data.
//    PULL   → AppLinks request /rfed/pull on rfed.channel.pull,
//             payload: msgpack bin(16) channel_hash,
//             response: [ [[bin16, blob], ...], bool more_pending ]
//             (legacy rfed.delivery /rfed/pull remains server-side for
//              compatibility with older clients.)
//  ============================================================================
//

import Foundation
import Combine
import SwiftData
import CryptoKit

@MainActor
final class RfedChannelClient: ObservableObject {

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

    /// Whether the requested channel *might* still have pending deferred blobs.
    /// Keyed by channel hash hex because `rfed.channel.pull` is channel-scoped.
    /// `nil` (or `true`) means "user may try a PULL"; `false` means the last
    /// addressed PULL returned `more_pending=false` so the UI hides the page-load
    /// action until something happens to suggest more blobs may have arrived
    /// (channel re-open, app foreground, etc.).
    @Published var canPullMore: [String: Bool] = [:]

    /// True while a `/rfed/pull` request is in flight for the given channel.
    /// UI uses this to disable the page-load button to prevent double taps.
    @Published var pullInFlight: [String: Bool] = [:]

    /// Channel Display Names (DISPLAY_NAMES.md §5.1): channel hash → sender
    /// hash → the name that sender's posts in that channel carry. Persisted
    /// in ChannelSenderEntity; it never becomes the contact's messageName.
    @Published private(set) var senderNames: [String: [String: String]] = [:]
    /// What the NSE gets (channel_sender_names.json): every sender's
    /// channelName with the post time that set or cleared it, cleared
    /// names included, so its titles follow §5.2's ordering too.
    private var sharedSenderNames: [String: [String: DisplayNames.SharedChannelName]] = [:]

    /// The contact resolver without the hash fallback, with the slot the
    /// name came from (ChatRepository.contactSharedName), for channel labels
    /// in notifications: a local-slot name leads a channel name (§5.3). Set
    /// by the app when both exist.
    var contactEntry: (@MainActor (String) -> DisplayNames.SharedName?)?

    private var linkStatusTimer: AnyCancellable?
    private var trackedChannelStreamNodes: Set<String> = []
    private var didInstallRfedLinkHandlers = false
    /// Runtime-only set of channel hashes whose conversation view has been
    /// opened in this app process. `rfed.channel.stream` filters are derived
    /// from this set so the persistent link only streams channels the user has
    /// actually opened, while keeping them live until process teardown.
    private var openedChannelStreamHashes: Set<String> = []

    /// One-shot guard: re-subscribe to persisted channels exactly once
    /// per app run, the first time the rfed.channel route is reachable.
    /// Set to true after the first successful re-subscribe pass kicks off.
    private var didResubscribeOnActive = false
    private var didLoadPersistedState = false
    private var didStartNetworkFlows = false
    /// RfedDistroClient.stackStops as the latest start() with an identity saw it:
    /// equal to the current count, that start came after the latest stop, so the
    /// restarted stack is running (startEnded).
    private var stopsAtLastStart: UInt64 = 0
    /// ChannelEntity's own name state is adopted by the device once per process
    /// (adoptLegacyNameState).
    private var legacyNameStateAdopted = false
    /// Membership messages that arrived before the channel list was loaded, applied by
    /// `start()` once it is (handleDistroChannelSync).
    private var pendingChannelSync: [(marker: DistroChannelSync.Marker, fromDistro: Bool, signedByDistro: Bool)] = []

    /// A pull asked for before the stack could issue it. Posts wait in the
    /// store instead, queued (queuePost), so they outlive the process.
    private enum PendingRfedOperation {
        case pull(channel: Channel)
    }

    private var pendingRfedOperations: [PendingRfedOperation] = []
    private var pendingPullChannelHashes: Set<String> = []

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
        if !didLoadPersistedState {
            loadPersistedChannels()
            loadPersistedMessages()
            loadSenderNames()
            didLoadPersistedState = true
        }

        drainPendingChannelSync()
        installRfedLinkHandlers()

        guard identityHandle != 0 else { return }
        stopsAtLastStart = RfedDistroClient.shared.stackStops
        if !didStartNetworkFlows {
            didStartNetworkFlows = true

            // Drive re-subscribe from rfed.channel reachability instead of
            // routing RFed through the direct-chat AppLinks mechanism.
            // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
            scheduleResubscribeOnRfedChannelActive()
        }

        drainPendingRfedOperationsIfReady()
        releaseQueuedPosts()
        importNSEBlobs()
    }

    func stop() {
        didStartNetworkFlows = false
        didResubscribeOnActive = false
        stopRfedLinkMonitor()
    }

    /// Judge the membership messages held until the channel list was loaded (§17.12
    /// rules 1-6), in the order they came. Needs this device's address, which the
    /// stack gives `configure`: with it still unknown they stay held.
    private func drainPendingChannelSync() {
        guard didLoadPersistedState, modelContext != nil, !ownHashHex.isEmpty,
              !pendingChannelSync.isEmpty else { return }
        let held = pendingChannelSync
        pendingChannelSync.removeAll()
        print("[RfedChannel] judging \(held.count) membership message(s) held until the channel list was loaded")
        for item in held {
            _ = handleDistroChannelSync(marker: item.marker, fromDistro: item.fromDistro, signedByDistro: item.signedByDistro)
        }
    }

    private var canIssueRfedOperations: Bool {
        identityHandle != 0 && !ownHashHex.isEmpty
    }

    private func liveChannel(channelHashHex: String) -> Channel? {
        let normalized = Self.normalizedHex(channelHashHex)
        return channels.first { Self.normalizedHex($0.id) == normalized }
    }

    private func enqueuePendingPull(channel: Channel) {
        let normalized = Self.normalizedHex(channel.id)
        guard pendingPullChannelHashes.insert(normalized).inserted else { return }
        pendingRfedOperations.append(.pull(channel: channel))
        print("[RfedChannel] queued PULL until RFed stack is ready channel=\(channel.channelName) pending=\(pendingRfedOperations.count)")
    }

    private func drainPendingRfedOperationsIfReady() {
        guard canIssueRfedOperations else { return }
        guard !pendingRfedOperations.isEmpty else { return }

        let queued = pendingRfedOperations
        pendingRfedOperations.removeAll()
        pendingPullChannelHashes.removeAll()
        print("[RfedChannel] draining \(queued.count) queued RFed channel op(s)")

        for operation in queued {
            switch operation {
            case .pull(let channel):
                guard let live = liveChannel(channelHashHex: channel.id) else {
                    pullInFlight[channel.id] = false
                    continue
                }
                Task { _ = await self.pullDeferred(channel: live) }
            }
        }
    }

    func markChannelOpenedForStreaming(channelHashHex: String) {
        let normalized = Self.normalizedHex(channelHashHex)
        guard !normalized.isEmpty else { return }
        let inserted = openedChannelStreamHashes.insert(normalized).inserted
        guard inserted else { return }
        reconfigureChannelStreams()
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
        //   .connected    → node reachable (pill: "Reachable")
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
    ///
    /// `ChannelEntity.rfedNodeHash` stores the **rfed identity hash hex**
    /// (32 chars). Per-op destinations (subscribe / unsubscribe / publish /
    /// pull) are derived on demand from this identity. See REFACTOR.md step 4.
    func joinChannel(name: String, rfedNodeIdentityHashHex: String) async throws -> Channel {
        let channelHashData = try Self.channelHash(name: name)
        let channelHashHex = channelHashData.hexString

        let identityHex = Self.normalizedHex(rfedNodeIdentityHashHex)

        // Already joined? If the rfed node changed, update the stored identity and re-subscribe.
        if let existing = channels.first(where: { $0.id == channelHashHex }) {
            if existing.rfedNodeHash == identityHex {
                return existing
            }
            // Node identity changed — update in-memory and DB, then fall through to re-subscribe
            if let ctx = modelContext,
               let entity = try? ctx.fetch(FetchDescriptor<ChannelEntity>(
                   predicate: #Predicate { $0.channelHash == channelHashHex }
               )).first {
                entity.rfedNodeHash = identityHex
                try? ctx.save()
            }
            channels = channels.map { ch in
                ch.id == channelHashHex ? Channel(id: ch.id, channelName: ch.channelName,
                    rfedNodeHash: identityHex,
                    lastMessageTime: ch.lastMessageTime, isSubscribed: ch.isSubscribed,
                    stampCost: ch.stampCost) : ch
            }
        }
        // Subscribe on the server (background thread, blocking)
        let stampCost = try await subscribeOnServer(channelHashData: channelHashData,
                                                    rfedNodeIdentityHashHex: identityHex)

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
                                       rfedNodeHash: identityHex, lastMessageTime: now,
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
            reconfigureChannelStreams()
            return existing
        }

        let channel = Channel(id: channelHashHex, channelName: name,
                              rfedNodeHash: identityHex,
                              lastMessageTime: Date().timeIntervalSince1970,
                              isSubscribed: true, stampCost: stampCost)
        channels.append(channel)
        reconfigureChannelStreams()
        // The user's own join of a channel not in the list: recorded for RFed SPEC §17.12
        // rule 5 and, with a distro, owed to the other devices as a membership message.
        // A join of one already in the list (above) is no change. Applying a sibling's join
        // is applyDistroChannelSync, which sends nothing.
        await recordUsersAction(op: DistroChannelSync.opJoin, channelHash: channelHashHex, channelName: name)
        return channel
    }

    /// Leave a channel. Unsubscribes from the rfed node and removes local data.
    /// The user's own leave is recorded for RFed SPEC §17.12 rule 5 and, with a
    /// distro, owed to the other devices ([recordUsersAction]); the list changed
    /// when the user acted, whatever becomes of the message.
    func leaveChannel(channelHashHex: String) async {
        guard let channel = channels.first(where: { $0.id == channelHashHex }) else { return }
        guard leaveHere(channelHashHex: channelHashHex) else { return }
        await recordUsersAction(op: DistroChannelSync.opLeave, channelHash: channelHashHex, channelName: channel.channelName)
    }

    /// Leave a channel on this device, by the user's action or a sibling's (§17.12
    /// rule 6): unsubscribe with the device key, remove the channel's push
    /// registration, its posts, its senders and its names, and drop it from the
    /// stream's filter. Sends no membership message, and leaves rule 5's record
    /// alone. False, with nothing done, when the channel is unknown or its hash is
    /// not one.
    @discardableResult
    private func leaveHere(channelHashHex: String) -> Bool {
        guard let channel = channels.first(where: { $0.id == channelHashHex }) else { return false }
        let rfedNode = channel.rfedNodeHash
        guard let channelHashData = Data(hexString: channelHashHex),
              RfedLink.destHash(nodeHex: rfedNode) != nil else { return false }

        let pubkey = bridge.identityPublicKey(handle: identityHandle)
        let sig    = pubkey != nil ? bridge.identitySign(handle: identityHandle, data: channelHashData) : nil
        let payload: Data
        if let pk = pubkey, let s = sig {
            payload = Self.msgpackSigned(value: channelHashData, pubkey: pk, sig: s)
        } else {
            payload = Self.msgpackBin(channelHashData)
        }
        Task(priority: .background) {
            _ = await RfedLink.shared.request(nodeHex: rfedNode, path: "/channel/unsubscribe", payload: payload)
        }

        // Deregister per-channel push notification wakeup.
        let notifyNode = prefs.effectiveRfedNodeIdentityHash
        if let channelHashForNotify = Data(hexString: channelHashHex), !notifyNode.isEmpty {
            RfedNotifyRegistrar.shared.deregisterForChannel(channelHash: channelHashForNotify,
                                                            nodeHex: notifyNode,
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
            let senderEntities = (try? ctx.fetch(FetchDescriptor<ChannelSenderEntity>(
                predicate: #Predicate { $0.channelHash == hash }
            ))) ?? []
            for e in senderEntities { ctx.delete(e) }
            try? ctx.save()
            // The channel's name state, for every posting identity, goes with it.
            ChannelNameStateStore.forget(channelHash: hash, in: ctx)
        }
        let hadNames = senderNames.removeValue(forKey: channelHashHex) != nil
        if sharedSenderNames.removeValue(forKey: channelHashHex) != nil || hadNames {
            shareSenderNames()
        }

        channels.removeAll { $0.id == channelHashHex }
        publishPushDirectory()
        openedChannelStreamHashes.remove(Self.normalizedHex(channelHashHex))
        messages[channelHashHex] = nil
        reconfigureChannelStreams()
        return true
    }

    // MARK: - Channels and the distro (RFed SPEC §17.12)

    /// The user's own join or leave of a channel on this device: recorded for rule
    /// 5, stamped after any record held (so an action made after this device took
    /// a sibling's record is newer than it on every device, even with this
    /// device's clock behind), with or without a distro. With a distro the change
    /// is owed to its other devices as one membership message
    /// (DistroOutboxRuntime.oweChannelSync), kept until the propagation node
    /// proves it. Nothing else sends one: not applying a received message, not
    /// the start's re-subscription, not a stamp refresh, not a join of a channel
    /// already in the list.
    private func recordUsersAction(op: String, channelHash: String, channelName: String) async {
        guard let ctx = modelContext else { return }
        do {
            let recorded = ChannelMembershipStore.record(channelHash: channelHash, in: ctx)
            let atMs = try DistroChannelSync.stampLocal(recorded: recorded,
                                                        nowMs: Int64(Date().timeIntervalSince1970 * 1000))
            ChannelMembershipStore.upsert(channelHash: channelHash,
                                          record: .init(op: op, atMs: atMs), in: ctx)
            if !DistroManager.shared.has { return }
            await DistroOutboxRuntime.shared.oweChannelSync(op: op, channelName: channelName,
                                                            channelHashHex: channelHash, atMs: atMs)
        } catch {
            // The list changed when the user acted, whatever becomes of the message: said, never thrown at the screen.
            print("[RfedChannel] The \(op) of #\(channelName) was not recorded or sent to the distro (§17.12): \(error)")
        }
    }

    /// A membership message C unwrapped from the distro (§17.12 "Receiving"):
    /// rules 1-5 (DistroChannelSync.disposition), then rule 6
    /// (applyDistroChannelSync). `fromDistro` and `signedByDistro` are rules 1
    /// and 2's facts, which the caller knows from the unwrap. Returns true when
    /// C is held (applied, this device's own echo, or stale: each recorded as
    /// seen), false when it is dropped (rules 1, 2 and 4, each with a log line),
    /// so a later copy of it is judged again.
    func handleDistroChannelSync(marker: DistroChannelSync.Marker, fromDistro: Bool, signedByDistro: Bool) -> Bool {
        // A membership message that arrives before the channel list is loaded (the NSE's saved
        // blobs are ingested while the app starts) is held, and judged once it is: it is
        // recorded as seen when handed over, and a blob the NSE pulled will not come again.
        guard didLoadPersistedState, modelContext != nil, !ownHashHex.isEmpty else {
            pendingChannelSync.append((marker, fromDistro, signedByDistro))
            print("[RfedChannel] channel membership message held until the channel list is loaded")
            return true
        }
        let name = marker.sync?.name ?? "?"
        let ctx = modelContext
        let disposition = DistroChannelSync.disposition(
            marker: marker, fromDistro: fromDistro, signedByDistro: signedByDistro,
            ownDeviceHex: ownHashHex,
            joinNameAccepted: ChannelNameRules.joinNameAccepted,
            channelHashOf: { (try? Self.channelHash(name: $0).hexString) ?? "" },
            recordOf: { hash in ctx.flatMap { ChannelMembershipStore.record(channelHash: hash, in: $0) } })
        let device = marker.byHex.isEmpty ? "?" : String(marker.byHex.prefix(12))
        switch disposition {
        case .drop(let rule, let reason):
            print("[RfedChannel] Channel membership message for #\(name) from device \(device) dropped: \(reason) (§17.12 rule \(rule))")
            return false
        case .echo:
            print("[RfedChannel] own channel \(marker.sync?.op ?? "membership") echo for #\(name) — dropped (§17.12 rule 3)")
            return true
        case .stale(let op, _, let atMs, _, let recorded):
            print("[RfedChannel] channel \(op) of #\(name) at \(atMs) is older than the \(recorded.op) at \(recorded.atMs) held here — dropped (§17.12 rule 5)")
            return true
        case .apply(let op, let name, let atMs, let channelHash):
            applyDistroChannelSync(op: op, name: name, atMs: atMs, channelHash: channelHash, byHex: marker.byHex)
            return true
        }
    }

    /// §17.12 rule 6: apply a sibling's join or leave on this device, with this
    /// device's own key and its own configured RFed node, as the user's own join
    /// or leave here would, then record it. No membership message is sent
    /// (nothing loops), and nothing asks the user anything: the channel list
    /// simply changes.
    ///  - join of a channel not in the list: stored, then subscribed. It is stored
    ///    first, so a subscription that cannot be made now is made by the start's
    ///    subscription of stored channels (resubscribePersistedChannels), never by
    ///    a retry (DESIGN_PRINCIPLES §3, §5). Not opened: its posts wait at RFed
    ///    until the user opens it, as for any stored channel;
    ///  - join of a channel already in the list: nothing but the record;
    ///  - leave of a channel in the list: leaveHere;
    ///  - leave of a channel not in the list: nothing but the record.
    private func applyDistroChannelSync(op: String, name: String, atMs: Int64, channelHash: String, byHex: String) {
        let held = channels.first(where: { $0.id == channelHash })
        var applied = "recorded"
        if op == DistroChannelSync.opJoin && held == nil {
            let node = prefs.effectiveRfedNodeIdentityHash.trimmingCharacters(in: .whitespaces).lowercased()
            if node.count < 32 {
                // Not this device's to join without a node; the record still orders a later message.
                print("[RfedChannel] Channel join of #\(name) from device \(byHex.prefix(12)): no RFed node configured here — recorded, not joined")
            } else {
                let now = Date().timeIntervalSince1970
                if let ctx = modelContext {
                    ctx.insert(ChannelEntity(channelHash: channelHash, channelName: name, rfedNodeHash: node,
                                             lastMessageTime: now, isSubscribed: true, stampCost: nil))
                    try? ctx.save()
                }
                let channel = Channel(id: channelHash, channelName: name, rfedNodeHash: node,
                                      lastMessageTime: now, isSubscribed: true, stampCost: nil)
                channels.append(channel)
                applied = "joined"
                reconfigureChannelStreams()
                Task { await self.subscribeStoredChannel(channel) }
            }
        } else if op == DistroChannelSync.opLeave && held != nil {
            leaveHere(channelHashHex: channelHash)
            applied = "left"
        }
        if let ctx = modelContext {
            ChannelMembershipStore.upsert(channelHash: channelHash, record: .init(op: op, atMs: atMs), in: ctx)
        }
        print("[RfedChannel] Channel \(op) of #\(name) at \(atMs) from device \(byHex.prefix(12)): \(applied) (§17.12)")
    }

    /// Subscribe a channel the device has stored but not subscribed (a sibling's
    /// join), with the device's own key, once: the readiness of the link is the
    /// only wait, and a failure is logged, never retried. The start's
    /// resubscribePersistedChannels subscribes it if this could not.
    private func subscribeStoredChannel(_ channel: Channel) async {
        guard identityHandle != 0, let channelHashData = Data(hexString: channel.id) else { return }
        do {
            let stampCost = try await subscribeOnServer(channelHashData: channelHashData,
                                                        rfedNodeIdentityHashHex: channel.rfedNodeHash)
            if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
                channels[idx] = Channel(id: channel.id, channelName: channel.channelName,
                                        rfedNodeHash: channel.rfedNodeHash,
                                        lastMessageTime: channels[idx].lastMessageTime,
                                        isSubscribed: true, stampCost: stampCost)
            }
            if let ctx = modelContext {
                let hash = channel.id
                if let entity = try? ctx.fetch(FetchDescriptor<ChannelEntity>(
                    predicate: #Predicate { $0.channelHash == hash })).first {
                    entity.stampCost = stampCost
                    try? ctx.save()
                }
            }
            reconfigureChannelStreams()
            print("[RfedChannel] Subscribed to '\(channel.channelName)' joined on another device (stampCost=\(stampCost.map { "\($0)" } ?? "nil"))")
        } catch {
            print("[RfedChannel] Subscribing to '\(channel.channelName)', joined on another device, failed: \(error)")
        }
    }

    // MARK: - Channel push, for the NSE

    /// Share with the NSE, per channel with push on, what its pull needs
    /// (PendingNotification.ChannelPushEntry): the name the message key
    /// derives from, the rfed.link destination of the channel's node
    /// and the node destinations its path can be seeded from, and the
    /// channel's Notifications toggle. Written whenever one of those changes.
    func publishPushDirectory() {
        let entries: [PendingNotification.ChannelPushEntry] = channels.compactMap { channel in
            guard UserPreferences.shared.isChannelPushEnabled(channel.id) else { return nil }
            let node = channel.rfedNodeHash
            let pull = Self.rfedDestHash(identityHashHex: node, app: "rfed", aspects: ["link"])
            guard pull.count == 32 else { return nil }
            let sources = [
                Self.rfedDestHash(identityHashHex: node, app: "rfed", aspects: ["node"]),
                Self.rfedDestHash(identityHashHex: node, app: "lxmf", aspects: ["propagation"]),
            ].filter { $0.count == 32 }
            return PendingNotification.ChannelPushEntry(
                channel: Self.normalizedHex(channel.id), name: channel.channelName, pull: pull,
                sources: sources, notify: UserPreferences.shared.isChannelNotificationsEnabled(channel.id))
        }
        PendingNotification.writeChannelPushDirectory(entries)
    }

    /// Channel blobs the NSE pulled for a push while the app was not running,
    /// dispatched as a pull of our own (dedupe, signature check, storage),
    /// without a second notification. Left in the App Group until the stored
    /// channels AND messages are loaded (dispatchBlob drops a blob for a
    /// channel it does not know, and its dedupe checks the loaded messages)
    /// and this device's hash is known (our own echo is told apart by it):
    /// start() calls this again once configure() has the identity.
    func importNSEBlobs() {
        guard didLoadPersistedState, !ownHashHex.isEmpty, !channels.isEmpty else { return }
        let pairs = PendingNotification.readAndClearNSEChannelBlobs()
        guard !pairs.isEmpty else { return }
        print("[RfedChannel] importing \(pairs.count) blob(s) the NSE pulled")
        for pair in pairs {
            // The NSE already showed them: stored, not notified again.
            dispatchBlob(channelHashHex: pair.channel.hexString, blob: pair.blob, notify: false)
        }
    }

    // MARK: - Per-channel push toggle

    /// Enable push wakeups for a channel: saves the pref and registers with rfed.notify.register.
    func enableChannelPush(channelHashHex: String) {
        UserPreferences.shared.enableChannelPush(channelHashHex)
        publishPushDirectory()
        guard let channelHashData = Data(hexString: channelHashHex) else { return }
        let notifyNode = prefs.effectiveRfedNodeIdentityHash
        guard !notifyNode.isEmpty else { return }
        RfedNotifyRegistrar.shared.registerForChannel(channelHash: channelHashData,
                                                       nodeHex: notifyNode,
                                                       identityHandle: identityHandle)
    }

    /// Disable push wakeups for a channel: saves the pref and deregisters via rfed.notify.unregister.
    func disableChannelPush(channelHashHex: String) {
        UserPreferences.shared.disableChannelPush(channelHashHex)
        publishPushDirectory()
        guard let channelHashData = Data(hexString: channelHashHex) else { return }
        // The node the registration was owed to: deregisterForChannel
        // forgets the owed or delivered registration under it, so switching
        // push back on in the same run sends it again (until 2026-09-26 the
        // wrong hash was passed here and nothing was forgotten).
        let notifyNode = prefs.effectiveRfedNodeIdentityHash
        guard !notifyNode.isEmpty else { return }
        RfedNotifyRegistrar.shared.deregisterForChannel(channelHash: channelHashData,
                                                         nodeHex: notifyNode,
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
                guard let channelHashData = Data(hexString: channel.id) else {
            throw ChannelError.invalidRfedNode
        }
        let fresh = try await subscribeOnServer(channelHashData: channelHashData,
                                                                                                 rfedNodeIdentityHashHex: channel.rfedNodeHash)
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

    /// RFed-spec/Channel.md "Distro holders" (James, 2026-10-03): a post is signed by
    /// the posting identity, the distro when this device holds one (as a DM is,
    /// DistroManager.sendingIdentity), otherwise the device: its source, the key in
    /// its prelude and its signature are that identity's, so readers see one sender
    /// for all of the user's devices. Decided once per post: the record, the echo
    /// id, the packing and the name state all take this one. Subscribing, the
    /// stream, pulls and push registrations stay the device's (`identityHandle`):
    /// RFed keys all of them by subscriber hash.
    private func postingIdentity() -> (hex: String, handle: UInt64) {
        let device = Data(hexString: ownHashHex) ?? Data()
        let (hash, handle) = DistroManager.shared.sendingIdentity(deviceHash: device, deviceHandle: identityHandle)
        return (hash.hexString, handle)
    }

    private func sendMessageAsync(content: String,
                                  toChannel channel: Channel,
                                  optimisticId existingOptimisticId: String? = nil) async {
        let (postingHex, postingHandle) = postingIdentity()
        // --- Optimistic bubble: insert IMMEDIATELY in `pending` so the user
        // sees the message and a “sending” indicator without waiting on the
        // PoW stamp + FFI hop. We update its state in place once trySend
        // resolves. The id is a synthetic placeholder; on success it’s
        // replaced with the canonical sender_hex+lxmf_ts id so the echo
        // from RFed dedupes against it.
        let optimisticId: String
        if let existingOptimisticId {
            optimisticId = existingOptimisticId
        } else {
            optimisticId = "pending_\(UUID().uuidString)"
            let optimisticTs = Date().timeIntervalSince1970 * 1000.0
            let optimisticEntity = ChannelMessageEntity(
                id: optimisticId, channelHash: channel.id,
                senderHash: postingHex,
                content: content, timestamp: optimisticTs, isOutgoing: true,
                deliveryState: DeliveryState.pending
            )
            modelContext?.insert(optimisticEntity)
            try? modelContext?.save()
            appendMessage(
                ChannelMessage(id: optimisticId, channelHash: channel.id,
                               senderHash: postingHex,
                               content: content, timestamp: optimisticTs, isOutgoing: true,
                               deliveryState: DeliveryState.pending),
                toChannelHash: channel.id
            )
        }

        // A post that cannot go now waits, queued, as Android's does (James,
        // 2026-10-19): with no stack yet, or with its rfed.link not up, back
        // from the background while the connections come back. Until then it
        // waited 5 s for the link, then 5 s more, and failed (the red mark).
        guard canIssueRfedOperations, Self.linkUp(RfedLink.shared.status(nodeHex: channel.rfedNodeHash)) else {
            queuePost(optimisticId: optimisticId, channel: channel)
            return
        }

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

        switch await trySend(content: content, toChannel: liveChannel, optimisticId: optimisticId,
                             postingHex: postingHex, postingHandle: postingHandle) {
        case .sent:
            releaseQueuedPosts()
            return
        case .unanswered:
            // The link read ACTIVE and nothing came back: a link that died in
            // the background reads ACTIVE until its own request timeout tears
            // it down, and AppLinks then opens it again (its re-open arm).
            // The post waits for that link's ACTIVE edge, not the red mark.
            queuePost(optimisticId: optimisticId, channel: liveChannel)
            return
        case .failed:
            if requeueIfLinkDown(optimisticId: optimisticId, channel: liveChannel) { return }
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
            if requeueIfLinkDown(optimisticId: optimisticId, channel: liveChannel) { return }
            markOptimisticFailed(optimisticId: optimisticId, channelHash: channel.id)
            return
        }
        switch await trySend(content: content, toChannel: liveChannel, optimisticId: optimisticId,
                             postingHex: postingHex, postingHandle: postingHandle) {
        case .sent:
            releaseQueuedPosts()
        case .unanswered:
            queuePost(optimisticId: optimisticId, channel: liveChannel)
        case .failed:
            if requeueIfLinkDown(optimisticId: optimisticId, channel: liveChannel) { return }
            markOptimisticFailed(optimisticId: optimisticId, channelHash: channel.id)
        }
    }

    // MARK: - Queued posts

    /// rfed.link status 3 is ACTIVE (AppLinks).
    nonisolated static func linkUp(_ status: Int32) -> Bool { status == 3 }

    /// One release of the queued posts at a time (releaseQueuedPosts); one
    /// asked for meanwhile runs after it, reading the queue afresh.
    private var releasingQueuedPosts = false
    private var releaseQueuedPostsAgain = false

    /// Keep a post that cannot go now, queued: stored with the pending clock
    /// (DeliveryState.queued), and sent by releaseQueuedPosts when the stack
    /// starts or its rfed.link comes up. Opening the link starts here, so its
    /// ACTIVE edge comes.
    private func queuePost(optimisticId: String, channel: Channel) {
        setOutgoingState(optimisticId: optimisticId, channelHash: channel.id, state: DeliveryState.queued)
        if canIssueRfedOperations { RfedLink.shared.ensure(nodeHex: channel.rfedNodeHash) }
        print("[RfedChannel] SEND queued until \(canIssueRfedOperations ? "rfed.link is up" : "the stack is ready") channel=\(channel.channelName) id=\(optimisticId)")
    }

    /// A send that failed with its rfed.link down (it went while the post was
    /// sent) is queued again, for the link's return, rather than failed.
    private func requeueIfLinkDown(optimisticId: String, channel: Channel) -> Bool {
        guard !Self.linkUp(RfedLink.shared.status(nodeHex: channel.rfedNodeHash)) else { return false }
        queuePost(optimisticId: optimisticId, channel: channel)
        return true
    }

    /// Send the queued posts, oldest first: when the stack starts (start) and
    /// on every ACTIVE edge of an rfed.link (the "channel-queue" binder),
    /// Android's releaseQueuedPosts. Each is taken from the queue (queued →
    /// pending) before it is sent, so a release sends it once; one whose link
    /// is not up waits for that link's edge, and one whose link goes while it
    /// is sent, or whose send is not answered, is queued again. A post rfed
    /// took releases the rest too: that link is up. Ordering, not a retry: no
    /// timer, each release follows a signal.
    private func releaseQueuedPosts() {
        guard canIssueRfedOperations, let ctx = modelContext else { return }
        if releasingQueuedPosts {
            releaseQueuedPostsAgain = true
            return
        }
        releasingQueuedPosts = true
        Task { @MainActor in
            repeat {
                releaseQueuedPostsAgain = false
                let queued = DeliveryState.queued
                let rows = (try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>(
                    predicate: #Predicate { $0.isOutgoing == true && $0.deliveryState == queued },
                    sortBy: [SortDescriptor(\.timestamp)]
                ))) ?? []
                if !rows.isEmpty { print("[RfedChannel] SEND: releasing \(rows.count) queued post(s)") }
                for row in rows {
                    guard row.deliveryState == DeliveryState.queued else { continue }
                    let (id, content, channelHash) = (row.id, row.content, row.channelHash)
                    guard let channel = liveChannel(channelHashHex: channelHash) else {
                        print("[RfedChannel] SEND: queued \(id) has no channel \(channelHash) — failed")
                        markOptimisticFailed(optimisticId: id, channelHash: channelHash)
                        continue
                    }
                    guard Self.linkUp(RfedLink.shared.status(nodeHex: channel.rfedNodeHash)) else {
                        RfedLink.shared.ensure(nodeHex: channel.rfedNodeHash)
                        continue
                    }
                    setOutgoingState(optimisticId: id, channelHash: channelHash, state: DeliveryState.pending)
                    await sendMessageAsync(content: content, toChannel: channel, optimisticId: id)
                }
            } while releaseQueuedPostsAgain
            releasingQueuedPosts = false
        }
    }

    /// Mark the optimistic entity (and its in-memory copy) as `failed`.
    /// Called from any terminal SEND error path so the user sees the red
    /// xmark indicator instead of an indefinite “sending” clock.
    private func markOptimisticFailed(optimisticId: String, channelHash: String) {
        setOutgoingState(optimisticId: optimisticId, channelHash: channelHash, state: DeliveryState.failed)
    }

    /// Set an outgoing post's state in the store and on screen.
    private func setOutgoingState(optimisticId: String, channelHash: String, state: Int) {
        if let ctx = modelContext,
           let temp = try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>(
               predicate: { let oid = optimisticId; return #Predicate { $0.id == oid } }()
           )).first {
            temp.deliveryState = state
            try? ctx.save()
        }
        if var list = messages[channelHash],
           let idx = list.firstIndex(where: { $0.id == optimisticId }) {
            list[idx].deliveryState = state
            messages[channelHash] = list
        }
    }

    /// How a trySend ended: rfed took the post, the post was refused or
    /// could not be built (failed), or the link read ACTIVE and nothing came
    /// back (unanswered).
    private enum SendOutcome { case sent, failed, unanswered }

    /// Build the wire payload, compute the stamp, and ship it.  Returns
    /// .failed if any step that would produce a server-rejected packet fails
    /// (so the caller can refresh stampCost and retry), and .unanswered when
    /// rfed's answer did not come.  On a successful
    /// transmission the optimistic entity identified by `optimisticId` is
    /// upgraded in place to the canonical `sender_hex+lxmf_ts` id with
    /// `deliveryState = sent` (so the echo from RFed dedupes against it
    /// in `dispatchVerifiedLxmf`).
    private func trySend(content: String, toChannel channel: Channel,
                          optimisticId: String,
                          postingHex: String, postingHandle: UInt64) async -> SendOutcome {
        // Build the wire payload as an LXMF-authenticated channel message.
        // The FFI returns both the on-wire bytes AND the LXMF timestamp it
        // baked into the signed body — we use the same timestamp as the
        // canonical id so the echo back from RFed dedupes cleanly against
        // the optimistic entity (after we rename it).
        let contentData = Data(content.utf8)
        // The Channel Display Name, by the §4.2 rule (DISPLAY_NAMES.md):
        // never the Message Display Name.
        let postName = channelPostName(for: channel, postingHex: postingHex)
        guard let packed = bridge.channelLxmPack(name: channel.channelName,
                                                  senderIdentityHandle: postingHandle,
                                                  content: contentData,
                                                  title: Data(),
                                                  displayName: postName) else {
            print("[RfedChannel] LXMF pack failed: \(bridge.lastError() ?? "unknown")")
            return .failed
        }
        let lxmfData = packed.wirePayload
        let tsMs = packed.timestampMs

        guard lxmfData.count >= 16,
              lxmfData.prefix(16).hexString.lowercased() == channel.id.lowercased() else {
            print("[RfedChannel] LXMF pack produced wrong channel_id_hash prefix")
            return .failed
        }

        var payload = lxmfData
        if let cost = channel.stampCost, cost > 0 {
            // The rfed node REQUIRES a stamp at this cost. If FFI returns
            // nil it means the PoW search exhausted its iteration cap — we
            // refuse to ship a packet we know will be rejected.
            guard let stamp = bridge.channelComputeStamp(payload: payload, cost: Int32(cost)) else {
                print("[RfedChannel] STAMP COMPUTE FAILED for cost=\(cost): \(bridge.lastError() ?? "unknown") — aborting send")
                return .failed
            }
            payload += stamp
            print("[RfedChannel] stamp computed (cost=\(cost), stamp_bytes=\(stamp.count), payload_bytes=\(payload.count))")
        }

        guard RfedLink.destHash(nodeHex: channel.rfedNodeHash) != nil else {
            print("[RfedChannel] Send failed: invalid rfed.link dest derived from \(channel.rfedNodeHash)")
            return .failed
        }
        // A request on rfed.link, answered [ok, reason] (RFed-spec Link.md):
        // until 2026-10-18 the post went as DATA on rfed.channel, whose proof
        // said only that the packet arrived, never whether rfed took it. The
        // request's data is a msgpack value, so the post goes as a bin: bare,
        // its bytes are read as msgpack and re-encoded (Reticulum-rust
        // link.rs keeps only a bin's bytes), and rfed gets a changed post.
        let answer = await RfedLink.shared.request(nodeHex: channel.rfedNodeHash, path: "/channel/publish",
                                                   payload: Self.msgpackBin(payload))
        if let refusal = Self.publishRefusal(answer) {
            print("[RfedChannel] Send failed: rfed answered \(refusal)")
            return answer == nil ? .unanswered : .failed
        }
        // Handed to RFed: record what this post carried (§4.2).
        recordPostName(postName, channelHashHex: channel.id, postingHex: postingHex)

        // SEND succeeded — upgrade the optimistic entity in place to the
        // canonical id (sender_hex+lxmf_ts) and mark it `sent` (= published
        // to RFed). Using the same id format as `dispatchVerifiedLxmf` so
        // the inevitable echo from RFed is suppressed by dedup.
        let canonicalId = (Data(hexString: postingHex) ?? Data()).hexString
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
                temp.senderHash = postingHex
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
                    let upgraded = list[idx]
                    list.remove(at: idx)
                    list.append(ChannelMessage(
                        id: canonicalId, channelHash: upgraded.channelHash,
                        senderHash: postingHex.isEmpty ? upgraded.senderHash : postingHex,
                        content: upgraded.content, timestamp: Double(tsMs),
                        isOutgoing: true,
                        deliveryState: DeliveryState.sent
                    ))
                    list.sort { $0.timestamp < $1.timestamp }
                }
                messages[channel.id] = list
            }
        }
        updateChannelLastMessage(channelHashHex: channel.id, postMs: tsMs)
        return .sent
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
        let channelKey = Self.normalizedHex(channel.id)
        let nodeKey = channel.rfedNodeHash
        await MainActor.run { self.pullInFlight[channelKey] = true }

        guard canIssueRfedOperations else {
            enqueuePendingPull(channel: channel)
            return canPullMore[channelKey] ?? true
        }

        guard let channelHashData = Data(hexString: channelKey) else {
            await MainActor.run { self.pullInFlight[channelKey] = false }
            return false
        }

        guard RfedLink.destHash(nodeHex: nodeKey) != nil else {
            await MainActor.run { self.pullInFlight[channelKey] = false }
            return false
        }

        defer {
            Task { @MainActor in self.pullInFlight[channelKey] = false }
        }

        // On rfed.link, which identified as this device before ACTIVE (the
        // pull authenticates by link identity, Link.md "Identify").
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        let response = await RfedLink.shared.request(nodeHex: nodeKey, path: "/channel/pull",
                                                     payload: Self.msgpackBin(channelHashData))

        guard let data = response else {
            print("[RfedChannel] PULL: rfed.link /channel/pull failed or no response within 5 s")
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
                _ = self.dispatchBlob(channelHashHex: channelHashData.hexString, blob: blob)
            }
        }

        await MainActor.run { self.canPullMore[channelKey] = morePending }
        return morePending
    }

    // MARK: - Live channel stream receive

    /// A `/delivery` push on rfed.link, on its link worker thread, which waits
    /// for the answer: true when this device now holds the post (stored, or
    /// held already), false when it was dropped (RFed-spec Link.md "The
    /// response is the delivery proof").
    nonisolated func onRfedBlob(_ blob: Data) -> Bool {
        // Blob format from server: channel_hash(16) | inner_blob(*)
        print("[RfedChannel] onRfedBlob total_bytes=\(blob.count)")
        guard blob.count > 16 else {
            print("[RfedChannel] onRfedBlob DROPPED: too short (\(blob.count) bytes)")
            return false
        }
        let channelHashData = blob.prefix(16)
        let innerBlob = blob.dropFirst(16)

        // Distro fan-out shares /delivery with channels, told apart only by
        // the 16-byte prefix: the distro's lxmf.delivery hash instead of a
        // channel hash (RFed distro_fanout tier 3). Mirrors Android
        // RfedChannelClient.dispatchInboundBlob and web _handleChannelPacket →
        // _handleDistroBlob.
        if let distroHash = DistroManager.shared.deliveryHash, channelHashData == distroHash {
            print("[RfedChannel] onRfedBlob distro prefix → RfedDistroClient inner_bytes=\(innerBlob.count)")
            return RfedDistroClient.ingestBlobAnswering(Data(innerBlob))
        }
        let channelHashHex = channelHashData.hexString
        print("[RfedChannel] onRfedBlob channel_hash=\(channelHashHex) inner_bytes=\(innerBlob.count)")

        // The link worker waits here for the main actor: it holds no lock
        // (Reticulum-rust link.rs runs each request handler on its own thread).
        let inner = Data(innerBlob)
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.dispatchBlob(channelHashHex: channelHashHex, blob: inner) }
        }
    }

    // MARK: - Private

    /// True when this device now holds the post (stored, or held already),
    /// false when it was dropped: rfed.link's delivery proof.
    @discardableResult
    private func dispatchBlob(channelHashHex: String, blob: Data, notify: Bool = true) -> Bool {
        // Skip if this channel is not known
        guard let channel = channels.first(where: { $0.id == channelHashHex }) else {
            let known = channels.map { $0.id.prefix(8) }.joined(separator: ", ")
            print("[RfedChannel] dispatchBlob NO MATCH channel=\(channelHashHex.prefix(16)) known=[\(known)]")
            return false
        }

        // Pre-decryption dedup. Same encrypted blob from the propagation node
        // (mirrored to multiple subscribers) hits us multiple times with
        // byte-identical ciphertext. Drop here, before the expensive crypto.
        let blobKey = channelHashHex.hashValue &+ blob.hashValue
        if seenBlobKeys.contains(blobKey) {
            print("[RfedChannel] dispatchBlob PRE-DEDUP channel=\(channelHashHex.prefix(16)) blob_bytes=\(blob.count)")
            return true
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
        guard let channelHashData = Data(hexString: channelHashHex) else { return false }
        let lxmfData = channelHashData + blob

        guard let result = bridge.channelLxmUnpack(name: channel.channelName, lxmfData: lxmfData) else {
            let error = bridge.lastError()
            let blobKey = channelHashHex.hashValue &+ blob.hashValue
            // A post that repeats a key (RFed SPEC §17.14 "Repeated keys") is refused whole by
            // the unpack, which has logged it once already: nothing more is said here.
            if !failedBlobKeys.contains(blobKey) {
                failedBlobKeys.insert(blobKey)
                if !RepeatedKeys.isRefusal(error) {
                    print("[RfedChannel] dispatchBlob LXMF unpack FAILED (lxmf_bytes=\(lxmfData.count), err=\(error ?? "?"), suppressing repeats)")
                }
            }
            return false
        }

        guard result.signatureValidated else {
            let reasonStr: String
            switch result.unverifiedReason {
            case 1: reasonStr = "SOURCE_UNKNOWN (sender not yet announced)"
            case 2: reasonStr = "SIGNATURE_INVALID"
            default: reasonStr = "code=\(result.unverifiedReason)"
            }
            print("[RfedChannel] dispatchBlob REJECTED unsigned message: \(reasonStr) sender=\(result.sourceHash.hexString.prefix(8))")
            return false
        }

        print("[RfedChannel] dispatchBlob unpack OK source=\(result.sourceHash.hexString.prefix(8)) ts_ms=\(result.timestampMs) content_bytes=\(result.content.count) sig_ok=true")
        return dispatchVerifiedLxmf(channelHashHex: channelHashHex, result: result, notify: notify)
    }

    /// Dispatch a successfully signature-verified LXMF channel message.
    /// `notify` is false for blobs the NSE pulled: it already showed them.
    /// True when the post is stored, or was already.
    private func dispatchVerifiedLxmf(channelHashHex: String, result: RetichatBridge.ChannelLxmUnpackResult,
                                      notify: Bool = true) -> Bool {
        let senderHashHex = result.sourceHash.hexString
        let tsMs = result.timestampMs
        guard let content = String(data: result.content, encoding: .utf8) else {
            print("[RfedChannel] dispatchVerifiedLxmf DROPPED: content not valid UTF-8")
            return false
        }

        let msgId = senderHashHex + String(format: "%016llx", tsMs)
        let existingForChannel = messages[channelHashHex]?.contains(where: { $0.id == msgId }) ?? false
        guard !existingForChannel else {
            print("[RfedChannel] dispatchVerifiedLxmf DEDUP: msgId=\(msgId.prefix(16))")
            return true
        }
        print("[RfedChannel] dispatchVerifiedLxmf DELIVERING sender=\(senderHashHex.prefix(8)) content='\(content.prefix(40))'")

        // RFed-spec/Channel.md "Own posts": a post is the user's own when its source
        // is this device's lxmf.delivery hash or the hash of the distro this device
        // holds now, whichever of the user's devices sent it. It is stored and shown
        // as outgoing, SENT (it came from RFed, so RFed has it; a channel post has no
        // per-reader confirmation, so never DELIVERED), never notified, never counted
        // as a sender seen in the channel. A device that gave up its distro no longer
        // holds it: that distro's later posts are another poster's to it.
        let distroHex = DistroManager.shared.deliveryHashHex
        let isOutgoing = DistroCodec.isOwnChannelPost(sourceHex: senderHashHex, deviceHex: ownHashHex, distroHex: distroHex)
        // DISPLAY_NAMES.md §4.2 "Learning from the channel": a post from the current
        // posting identity (the echo of this device's own post, or one a sibling
        // signed with the same distro), after the key binding and signature passed,
        // tells this device what readers last got from it, but only a value equal to
        // the one it would send itself.
        let postingHex = DistroCodec.postingHex(deviceHex: ownHashHex, distroHex: distroHex)
        if isOutgoing && senderHashHex.lowercased() == postingHex.lowercased() {
            learnPostName(channelHashHex: channelHashHex, postingHex: postingHex, field: result.displayName, postMs: tsMs)
        }
        // The sender in this channel: seen (§4.2) and named (§5.2; the
        // unpack reports a name only for a validated signature, and only
        // validated posts reach here).
        if !isOutgoing {
            noteSender(channelHashHex: channelHashHex, senderHashHex: senderHashHex,
                       postMs: Double(tsMs), name: result.displayName)
        }
        let deliveryState = Self.verifiedChannelMessageDeliveryState(isOutgoing: isOutgoing)
        let entity = ChannelMessageEntity(id: msgId, channelHash: channelHashHex,
                                          senderHash: senderHashHex,
                                          content: content,
                          timestamp: Double(tsMs), isOutgoing: isOutgoing,
                          deliveryState: deliveryState)
        modelContext?.insert(entity)
        try? modelContext?.save()

        let msg = ChannelMessage(id: msgId, channelHash: channelHashHex,
                                  senderHash: senderHashHex, content: content,
                      timestamp: Double(tsMs), isOutgoing: isOutgoing,
                      deliveryState: deliveryState)
        appendMessage(msg, toChannelHash: channelHashHex)
        updateChannelLastMessage(channelHashHex: channelHashHex, postMs: tsMs)

        if notify, !isOutgoing, let channel = channels.first(where: { $0.id == channelHashHex }),
           UserPreferences.shared.isChannelNotificationsEnabled(channelHashHex) {
            // Named as the bubble names the sender (audit L6), and as the NSE
            // names it (DisplayNames.channelNotificationTitle).
            let label = senderLabel(channelHashHex: channelHashHex, senderHashHex: senderHashHex,
                                    contact: contactEntry?(senderHashHex))
            NotificationManager.shared.postMessageNotification(
                chatId: channelHashHex,
                senderName: DisplayNames.channelNotificationTitle(channelName: channel.channelName, label: label),
                content: content
            )
        }
        return true
    }

    /// rfed's answer to `/channel/publish` (RFed-spec Link.md): `[true, nil]`
    /// is accepted, stored and fanned out (nil here); `[false, reason]` gives
    /// the reason; no answer, or one that isn't either, says so. Android
    /// RfedChannelClient.publishRefusal.
    nonisolated static func publishRefusal(_ answer: Data?) -> String? {
        guard let answer else { return "nothing within 5 s" }
        let a = [UInt8](answer)
        if a.count >= 2, a[0] == 0x92, a[1] == 0xc3 { return nil }
        if a.count >= 2, a[0] == 0x92, a[1] == 0xc2 {
            let tag = a.count > 2 ? Int(a[2]) : -1
            let len: Int
            if (0xa0...0xbf).contains(tag) {
                len = tag - 0xa0
            } else if tag == 0xd9, a.count > 3 {
                len = Int(a[3])
            } else {
                return "a refusal"
            }
            let start = tag == 0xd9 ? 4 : 3
            guard a.count >= start + len else { return "a refusal" }
            return String(decoding: a[start..<(start + len)], as: UTF8.self)
        }
        return "an unreadable answer \(answer.hexString)"
    }

    private func appendMessage(_ msg: ChannelMessage, toChannelHash hash: String) {
        var list = messages[hash] ?? []
        list.append(msg)
        list.sort { $0.timestamp < $1.timestamp }
        messages[hash] = list
    }

    /// Takes the post's wire timestamp (ms) and stores seconds, so no caller
    /// can hand it the wrong unit: the send path once passed the ms straight
    /// through and the chat list showed a post made today as "Jun 30".
    private func updateChannelLastMessage(channelHashHex: String, postMs: UInt64) {
        let time = ChannelTime.lastMessageSeconds(postMs: postMs)
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
                                   rfedNodeIdentityHashHex: String) async throws -> Int? {
        // Payload: fixarray-3 [bin(16) channel_hash, bin(64) pubkey, bin(64) sig]
        // sig = Ed25519(channel_hash). Server derives subscriber_hash from pubkey and
        // verifies the signature — no timing dependency on IDENTIFY.
        guard let pubkey = bridge.identityPublicKey(handle: identityHandle),
              let sig    = bridge.identitySign(handle: identityHandle, data: channelHashData) else {
            throw ChannelError.subscribeFailed("failed to sign subscribe payload")
        }
        let payload = Self.msgpackSigned(value: channelHashData, pubkey: pubkey, sig: sig)

        guard RfedLink.destHash(nodeHex: rfedNodeIdentityHashHex) != nil else {
            throw ChannelError.invalidRfedNode
        }

        // On rfed.link (RFed-spec Link.md). AppLinks owns the path race and
        // link establishment. NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        let response = await RfedLink.shared.request(nodeHex: rfedNodeIdentityHashHex,
                                                     path: "/channel/subscribe", payload: payload)

        guard let resp = response else {
            throw ChannelError.subscribeFailed(
                "rfed.link /channel/subscribe failed or no response within 5 s")
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
        // One-shot migration: pre-step-4 builds stored the rfed.channel dest hash
        // in ChannelEntity.rfedNodeHash. Step 4 stores the rfed identity hash hex
        // instead and derives per-op destinations on demand. If we detect a stored
        // value that matches the legacy derivation for the user's current rfed node,
        // rewrite it to the identity hex. NEVER REMOVE EVER — see REFACTOR.md.
        let identityHex = prefs.effectiveRfedNodeIdentityHash
        let legacyChannelDestHex = identityHex.isEmpty ? "" :
            Self.rfedDestHash(identityHashHex: identityHex,
                              app: "rfed", aspects: ["channel"])
        var migrated = false
        for entity in entities {
            if !legacyChannelDestHex.isEmpty,
               entity.rfedNodeHash == legacyChannelDestHex {
                entity.rfedNodeHash = identityHex
                migrated = true
            }
        }
        channels = entities.map {
            // Rows written in ms (before the unit switch, and by the send
            // path until 2026-09-27) are corrected once, here; a seconds
            // value passes unchanged.
            let raw = $0.lastMessageTime
            let seconds = ChannelTime.normalizedStoredSeconds(raw)
            if seconds != raw { $0.lastMessageTime = seconds }
            return Channel(id: $0.channelHash, channelName: $0.channelName,
                    rfedNodeHash: $0.rfedNodeHash, lastMessageTime: seconds,
                    isSubscribed: $0.isSubscribed, stampCost: $0.stampCost)
        }
        if migrated {
            print("[RfedChannel] Migrated ChannelEntity.rfedNodeHash from legacy rfed.channel dest hash to rfed identity hex")
        }
        try? ctx.save()
        publishPushDirectory()
    }

    /// Re-subscribe to every persisted-subscribed channel once the rfed.channel
    /// route is reachable. Idempotent so reconnect storms don't spam the node.
    /// NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
    ///
    /// With a distro, its queue first (DistroFirst, DESIGN_PRINCIPLES §5): what
    /// the NSE pulled and RFed's queue are applied, a sibling's leave included,
    /// before any channel is subscribed again or has its push registered again
    /// (the loop below does both). Until 2026-10-10 this ran beside
    /// RfedDistroClient's pull after its registration, unsynchronised, so a
    /// channel left on another device could be subscribed here and only then
    /// left. The pull's outcome, whatever it is, is the event: said, and the
    /// re-subscription may run.
    ///
    /// A stop under it (Settings → Apply: stopService, then startService) ends
    /// this start instead (review of 67b8a38): its stack is gone, and on the
    /// restarted one it would race that stack's own pull. startEnded hands the
    /// re-subscription to the restarted stack's start, with its own pull first.
    private func scheduleResubscribeOnRfedChannelActive() {
        let stopsAtStart = RfedDistroClient.shared.stackStops
        Task { [weak self] in
            guard let self else { return }
            let stopped = { RfedDistroClient.shared.stackStops != stopsAtStart }
            let went = await DistroFirst.thenResubscribe(
                hasDistro: DistroManager.shared.has,
                pull: { await RfedDistroClient.shared.pullForStart() },
                stopped: stopped,
                say: { line, _ in print("[RfedChannel] \(line)") }
            ) {
                // Every return is said (the truth rule): the gate only lets this run.
                guard await ConnectionStateManager.shared.waitForRfedReachable(timeoutSecs: 5.0) else {
                    // Said, never silent: until 2026-10-10 this returned without a word.
                    let n = self.channels.filter { $0.isSubscribed }.count
                    print("[RfedChannel] RFed not reachable within 5 s: \(n) persisted channel(s) not re-subscribed at this start")
                    return
                }
                guard !stopped() else {
                    let n = self.channels.filter { $0.isSubscribed }.count
                    print("[RfedChannel] The stack stopped while this start waited for RFed: \(n) persisted channel(s) not re-subscribed by it")
                    self.startEnded()
                    return
                }
                guard !self.didResubscribeOnActive else {
                    print("[RfedChannel] The persisted channels' re-subscription ran already in this process: it does not run again at this start")
                    return
                }
                self.didResubscribeOnActive = true
                print("[RfedChannel] rfed.link reachable → re-subscribing persisted channels")
                self.resubscribePersistedChannels()
            }
            if !went { self.startEnded() }
        }
    }

    /// This start's stack was stopped under it, and it re-subscribed nothing.
    /// The restarted stack's start runs the gate, its own pull first: now, when
    /// that start has come already (it found the network flows started and ran
    /// nothing), else at that start(). Each is an event, never a timer.
    private func startEnded() {
        if stopsAtLastStart == RfedDistroClient.shared.stackStops {
            print("[RfedChannel] The restarted stack's start came during this one: its distro pull runs now, then its re-subscription")
            scheduleResubscribeOnRfedChannelActive()
        } else {
            didStartNetworkFlows = false
        }
    }

    /// Re-subscribe to all channels that were subscribed before the app was killed.
    /// Called on start() so the rfed node delivers real-time blobs after a restart.
    private func resubscribePersistedChannels() {
        let toResub = channels.filter { $0.isSubscribed }
        guard !toResub.isEmpty else {
            // Said, never silent (2026-10-10): the gate's line only let this run.
            print("[RfedChannel] No persisted channels to re-subscribe at this start")
            return
        }
        print("[RfedChannel] Re-subscribing to \(toResub.count) persisted channel(s) after restart")
        Task {
            for channel in toResub {
                guard let channelHashData = Data(hexString: channel.id) else {
                    print("[RfedChannel] Re-subscribe failed for \(channel.channelName): its stored channel hash is not hex")
                    continue
                }
                do {
                    let stampCost = try await subscribeOnServer(channelHashData: channelHashData,
                                                               rfedNodeIdentityHashHex: channel.rfedNodeHash)
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
                        RfedNotifyRegistrar.shared.registerForChannel(
                            channelHash: channelHashData,
                            nodeHex: prefs.effectiveRfedNodeIdentityHash,
                            identityHandle: identityHandle)
                    }
                } catch {
                    print("[RfedChannel] Re-subscribe failed for \(channel.channelName): \(error)")
                }
            }
            await MainActor.run {
                self.reconfigureChannelStreams()
            }
        }
    }

    private func reconfigureChannelStreams() {
        guard identityHandle != 0 else { return }

        let subscribedChannels = channels.filter { $0.isSubscribed }
        let nodes = Set(subscribedChannels.map { $0.rfedNodeHash.lowercased() })
            .union(trackedChannelStreamNodes)

        for nodeIdentityHashHex in nodes {
            // The stream is bound on rfed.link: RfedLink runs this client's
            // binder (sendChannelStreamConfigForNode) on every ACTIVE edge.
            trackedChannelStreamNodes.insert(nodeIdentityHashHex)
            guard RfedLink.shared.ensure(nodeHex: nodeIdentityHashHex) != nil else { continue }
            // Not up yet: the binder sends the filters on its ACTIVE edge.
            if RfedLink.shared.status(nodeHex: nodeIdentityHashHex) == 3 {
                sendChannelStreamConfigForNode(nodeIdentityHashHex: nodeIdentityHashHex)
            }
        }
    }

    /// Take channel pushes on rfed.link (`/delivery`) and bind each fresh
    /// link for them. Once per process: the client outlives the stack.
    private func installRfedLinkHandlers() {
        guard !didInstallRfedLinkHandlers else { return }
        didInstallRfedLinkHandlers = true
        RfedLink.setPushHandler(path: RfedLink.pushDelivery) { [weak self] blob in
            self?.onRfedBlob(blob) ?? false
        }
        RfedLink.shared.setBinder(owner: "channel") { [weak self] node in
            guard let self, self.trackedChannelStreamNodes.contains(node) else { return }
            self.sendChannelStreamConfigForNode(nodeIdentityHashHex: node)
        }
        // The posts that waited for a link go on each fresh one.
        RfedLink.shared.setBinder(owner: "channel-queue") { [weak self] _ in
            self?.releaseQueuedPosts()
        }
    }

    private func sendChannelStreamConfigForNode(nodeIdentityHashHex: String) {
        let filters = liveStreamFilterHashes(nodeIdentityHashHex: nodeIdentityHashHex)
        sendChannelStreamConfig(nodeIdentityHashHex: nodeIdentityHashHex, filters: filters)
    }

    private func liveStreamFilterHashes(nodeIdentityHashHex: String) -> [Data] {
        let normalizedNode = Self.normalizedHex(nodeIdentityHashHex)
        return channels
            .filter {
                $0.isSubscribed &&
                Self.normalizedHex($0.rfedNodeHash) == normalizedNode &&
                openedChannelStreamHashes.contains(Self.normalizedHex($0.id))
            }
            .compactMap { Data(hexString: $0.id) }
    }

    private func sendChannelStreamConfig(nodeIdentityHashHex: String,
                                         filters: [Data]) {
        guard let payload = buildChannelStreamPayload(filters: filters) else {
            print("[RfedChannel] channel.stream config build failed for node=\(nodeIdentityHashHex)")
            return
        }

        Task {
            let response = await RfedLink.shared.request(nodeHex: nodeIdentityHashHex,
                                                         path: "/channel/stream/open", payload: payload)
            if !Self.channelStreamResponseOk(response) {
                print("[RfedChannel] channel.stream config rejected for node=\(nodeIdentityHashHex) filters=\(filters.count) resp=\(response?.hexString ?? "nil")")
            }
        }
    }

    private func loadPersistedMessages() {
        guard let ctx = modelContext else { return }
        let entities = (try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>())) ?? []
        // A post still being sent when an earlier process ended is failed
        // (the red mark), as Android's failStaleOutboundSendingMessages: it
        // stayed on the clock for good.
        // Queued posts stay queued: they go when the stack starts.
        var staleSends = 0
        for e in entities where e.isOutgoing && e.deliveryState == DeliveryState.pending {
            e.deliveryState = DeliveryState.failed
            staleSends += 1
        }
        if staleSends > 0 {
            try? ctx.save()
            print("[RfedChannel] \(staleSends) post(s) left sending by an earlier process — failed")
        }
        var grouped: [String: [ChannelMessage]] = [:]
        for e in entities {
            let msg = ChannelMessage(id: e.id, channelHash: e.channelHash,
                                     senderHash: e.senderHash,
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

    /// Helper: trim/lowercase a hex string and reject obvious non-hex input.
    private static func normalizedHex(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func verifiedChannelMessageDeliveryState(isOutgoing: Bool) -> Int {
        isOutgoing ? DeliveryState.sent : DeliveryState.delivered
    }

    // MARK: - Channel Display Names (DISPLAY_NAMES.md §4.2, §5)

    /// A poster's label in a channel (§5.3, DisplayNames.channelLabel): the
    /// user's localName with the channel name as secondary text; else the
    /// channel name with the short hash; else the contact's own resolution
    /// (`contact`, no hash fallback) ?? shortHash, alone.
    func senderLabel(channelHashHex: String, senderHashHex: String,
                     contact: DisplayNames.SharedName?) -> DisplayNames.ChannelLabel {
        DisplayNames.channelLabel(hash: senderHashHex,
                                  channelName: senderNames[channelHashHex]?[senderHashHex],
                                  contact: contact)
    }

    private func loadSenderNames() {
        guard let ctx = modelContext,
              let rows = try? ctx.fetch(FetchDescriptor<ChannelSenderEntity>()) else { return }
        var names: [String: [String: String]] = [:]
        var shared: [String: [String: DisplayNames.SharedChannelName]] = [:]
        for row in rows {
            if let name = row.channelName { names[row.channelHash, default: [:]][row.senderHash] = name }
            if row.channelName != nil || row.channelNameAtMs != nil {
                shared[row.channelHash, default: [:]][row.senderHash] =
                    DisplayNames.SharedChannelName(name: row.channelName, atMs: row.channelNameAtMs)
            }
        }
        senderNames = names
        sharedSenderNames = shared
        shareSenderNames()
    }

    /// The NSE names channel notifications the same way.
    private func shareSenderNames() {
        let snapshot = sharedSenderNames
        Task.detached(priority: .utility) {
            PendingNotification.writeChannelSenderNames(snapshot)
        }
    }

    /// A post from `senderHashHex` passed the key binding and signature
    /// checks: remember when this device first saw them here (§4.2 rule
    /// 2), and take the post's 0xD1 as their channelName (§5.2). A post
    /// older than the one that last set the name (pulled later with "Load
    /// earlier messages") leaves it alone.
    private func noteSender(channelHashHex: String, senderHashHex: String, postMs: Double,
                            name: DisplayNames.NameField) {
        guard let ctx = modelContext else { return }
        let channel = channelHashHex, sender = senderHashHex
        let row: ChannelSenderEntity
        if let existing = try? ctx.fetch(FetchDescriptor<ChannelSenderEntity>(
            predicate: #Predicate { $0.channelHash == channel && $0.senderHash == sender })).first {
            row = existing
        } else {
            row = ChannelSenderEntity(channelHash: channel, senderHash: sender,
                                      firstSeenAt: Date().timeIntervalSince1970)
            ctx.insert(row)
        }
        let newName: String?
        switch name {
        case .absent: try? ctx.save(); return
        case .clear: newName = nil
        case .name(let n): newName = n
        }
        // §5.2's ordering, per (channel, sender): only a post newer than
        // the one that last set or cleared the name counts; an older post
        // pulled later ("Load earlier messages") does not undo it. A newer
        // post repeating the name still records its time.
        guard DisplayNames.isNewer(postMs, than: row.channelNameAtMs) else {
            try? ctx.save()
            return
        }
        row.channelName = newName
        row.channelNameAtMs = postMs
        try? ctx.save()
        if senderNames[channel]?[sender] != newName {
            senderNames[channel, default: [:]][sender] = newName
        }
        // The NSE's copy follows every accepted post, the time included.
        sharedSenderNames[channel, default: [:]][sender] =
            DisplayNames.SharedChannelName(name: newName, atMs: postMs)
        shareSenderNames()
    }

    /// This device's Channel Display Name, cleaned, or nil while it is unset (§4.2).
    private func ownChannelName() -> String? {
        LxmfClient.cleanDisplayName(prefs.channelDisplayName)
    }

    /// The name state ChannelEntity kept before there was one per posting
    /// identity was made when the device posted as itself, the only posting
    /// identity then: the device takes it as its own, once per process, before it
    /// first reads its state (ChannelNameStateStore.adoptLegacy).
    private func adoptLegacyNameState() {
        guard !legacyNameStateAdopted, !ownHashHex.isEmpty, let ctx = modelContext else { return }
        let adopted = ChannelNameStateStore.adoptLegacy(deviceHash: ownHashHex.lowercased(), in: ctx)
        legacyNameStateAdopted = true
        if adopted > 0 { print("[RfedChannel] adopted the name state of \(adopted) channel(s) as this device's (§4.2)") }
    }

    /// §4.2: whether this post carries the Channel Display Name, from the persisted
    /// state of the channel and the posting identity (`postingHex`: the distro's
    /// hash when the device holds one, else its own). Readers have never had a name
    /// from a new posting identity, so one with no state starts from none and its
    /// first post carries the name (rule 1). The user's own posting identities,
    /// this device's hash and the held distro's, are never a sender "not seen
    /// before" (rule 2).
    private func channelPostName(for channel: Channel, postingHex: String) -> DisplayNames.NameField {
        adoptLegacyNameState()
        let current = ownChannelName()
        let hash = channel.id
        let state = modelContext.flatMap { ChannelNameStateStore.state(channelHash: hash, postingHash: postingHex, in: $0) }
        let lastIncludedAt = state?.at
        let lastDigest = state.flatMap { Data(hexString: $0.digestHex) }
        var own = Set([ownHashHex.lowercased()])
        if let distro = DistroManager.shared.deliveryHashHex { own.insert(distro.lowercased()) }
        let senders = (try? modelContext?.fetch(FetchDescriptor<ChannelSenderEntity>(
            predicate: #Predicate { $0.channelHash == hash }))) ?? []
        let newSender = senders.contains { !own.contains($0.senderHash.lowercased()) && $0.firstSeenAt > (lastIncludedAt ?? -Double.infinity) }
        return DisplayNames.channelPostName(current: current, lastDigest: lastDigest,
                                            lastIncludedAt: lastIncludedAt,
                                            newSenderSinceIncluded: newSender,
                                            now: Date().timeIntervalSince1970)
    }

    /// After a post is handed to RFed: what it carried and when, for the posting identity (§4.2).
    private func recordPostName(_ name: DisplayNames.NameField, channelHashHex: String, postingHex: String) {
        let digest: Data
        switch name {
        case .absent: return
        case .clear: digest = DisplayNames.digest(nil)
        case .name(let n): digest = DisplayNames.digest(n)
        }
        guard let ctx = modelContext else { return }
        ChannelNameStateStore.upsert(channelHash: channelHashHex, postingHash: postingHex,
                                     digestHex: digest.hexString, at: Date().timeIntervalSince1970, in: ctx)
    }

    /// §4.2 "Learning from the channel": a post this device received in
    /// `channelHashHex` from its current posting identity `postingHex`, key binding
    /// and signature passed, with 0xD1 `field` and the post's time `postMs`. What
    /// it carries is recorded only when it is the value this device would send now
    /// (DisplayNames.learnedPostName); a name it does not hold is never recorded,
    /// so its own clear never follows a sibling's name.
    private func learnPostName(channelHashHex: String, postingHex: String, field: DisplayNames.NameField, postMs: UInt64) {
        adoptLegacyNameState()
        guard let ctx = modelContext else { return }
        let state = ChannelNameStateStore.state(channelHash: channelHashHex, postingHash: postingHex, in: ctx)
        guard let learned = DisplayNames.learnedPostName(ownName: ownChannelName(), field: field,
                                                         postAt: Double(postMs) / 1000, lastIncludedAt: state?.at) else { return }
        ChannelNameStateStore.upsert(channelHash: channelHashHex, postingHash: postingHex,
                                     digestHex: learned.digest.hexString, at: learned.at, in: ctx)
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
    nonisolated static func rfedDestHash(identityHashHex: String, app: String, aspects: String) -> String {
        rfedDestHash(
            identityHashHex: identityHashHex,
            app: app,
            aspects: normalizedAspectSegments(app: app, aspects: [aspects])
        )
    }

    /// Compute an RNS SINGLE-destination hash (mirrors Reticulum Destination::hash()).
    nonisolated static func rfedDestHash(identityHashHex: String, app: String, aspects: [String]) -> String {
        let hex = identityHashHex.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.count == 32, let identityBytes = Data(hexString: hex) else { return "" }
        let name = ([app] + normalizedAspectSegments(app: app, aspects: aspects)).joined(separator: ".")
        let nameHashFull = SHA256.hash(data: Data(name.utf8))
        let nameHashTrunc = Data(nameHashFull.prefix(10))
        let material = nameHashTrunc + identityBytes
        return Data(SHA256.hash(data: material).prefix(16)).hexString
    }

    private nonisolated static func normalizedAspectSegments(app: String, aspects: [String]) -> [String] {
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

    /// Encode a value as msgpack bin: bin8, bin16 or bin32 by its length
    /// (a channel post is often over 255 bytes).
    nonisolated static func msgpackBin(_ data: Data) -> Data {
        let n = data.count
        var out: Data
        if n <= 0xff {
            out = Data([0xc4, UInt8(n)])
        } else if n <= 0xffff {
            out = Data([0xc5, UInt8(n >> 8), UInt8(n & 0xff)])
        } else {
            out = Data([0xc6, UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        }
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

    nonisolated static func msgpackArrayOfBins(_ elements: [Data]) -> Data {
        var out = Data()
        if elements.count <= 0x0f {
            out.append(UInt8(0x90 | elements.count))
        } else if elements.count <= 0xffff {
            out.append(0xdc)
            out.append(UInt8((elements.count >> 8) & 0xff))
            out.append(UInt8(elements.count & 0xff))
        } else {
            fatalError("too many channel stream filters")
        }
        for element in elements {
            out.append(msgpackBin(element))
        }
        return out
    }

    private func buildChannelStreamPayload(filters: [Data]) -> Data? {
        guard let pubkey = bridge.identityPublicKey(handle: identityHandle) else { return nil }
        let value = Self.msgpackArrayOfBins(filters)
        guard let sig = bridge.identitySign(handle: identityHandle, data: value) else { return nil }
        return Self.msgpackSigned(value: value, pubkey: pubkey, sig: sig)
    }

    nonisolated private static func channelStreamResponseOk(_ response: Data?) -> Bool {
        guard let response, response.count >= 2 else { return false }
        return response[response.startIndex] == 0x92 &&
            response[response.index(after: response.startIndex)] == 0xc3
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
