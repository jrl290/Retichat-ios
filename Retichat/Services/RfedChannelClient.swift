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
    @Published var rfedNodeStatus: NodeStatus = .unknown

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

    /// Start polling the app-link status every 3 s (while SettingsView is visible).
    /// The actual link is managed by ConnectionStateManager (opened/closed with app foreground).
    func startRfedLinkMonitor() {
        refreshRfedNodeStatus()
        linkStatusTimer?.cancel()
        linkStatusTimer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshRfedNodeStatus() }
    }

    /// Stop polling (SettingsView disappeared).
    func stopRfedLinkMonitor() {
        linkStatusTimer?.cancel()
        linkStatusTimer = nil
    }

    private func refreshRfedNodeStatus() {
        // appLinkStatus: 0=NONE, 1=PATH_REQUESTED, 2=ESTABLISHING, 3=ACTIVE, 4=DISCONNECTED
        switch ConnectionStateManager.shared.rfedNodeLinkStatus() {
        case 3:    rfedNodeStatus = .connected
        case 1, 2: rfedNodeStatus = .establishing
        case 4:    rfedNodeStatus = .unreachable
        default:   rfedNodeStatus = .unknown
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
            let nowMs = Date().timeIntervalSince1970 * 1000
            let entity = ChannelEntity(channelHash: channelHashHex, channelName: name,
                                       rfedNodeHash: rfedChannelDestHex, lastMessageTime: nowMs,
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
                              lastMessageTime: Date().timeIntervalSince1970 * 1000,
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

    func sendMessage(content: String, toChannel channel: Channel) {
        // Build the wire payload as an LXMF-authenticated channel message.
        // The FFI returns both the on-wire bytes AND the LXMF timestamp it
        // baked into the signed body — we use the same timestamp for the
        // local optimistic insert so the echo back from RFed dedupes
        // cleanly against it.
        let contentData = Data(content.utf8)
        guard let packed = bridge.channelLxmPack(name: channel.channelName,
                                                  senderIdentityHandle: identityHandle,
                                                  content: contentData,
                                                  title: Data()) else {
            print("[RfedChannel] LXMF pack failed: \(bridge.lastError() ?? "unknown")")
            return
        }
        let lxmfData = packed.wirePayload
        let tsMs = packed.timestampMs

        guard lxmfData.count >= 16,
              lxmfData.prefix(16).hexString.lowercased() == channel.id.lowercased() else {
            print("[RfedChannel] LXMF pack produced wrong channel_id_hash prefix")
            return
        }

        var payload = lxmfData
        if let cost = channel.stampCost, cost > 0 {
            if let stamp = bridge.channelComputeStamp(payload: payload, cost: Int32(cost)) {
                payload += stamp
                print("[RfedChannel] stamp computed (cost=\(cost), stamp_bytes=\(stamp.count))")
            } else {
                print("[RfedChannel] WARNING: stamp computation failed — sending without stamp")
            }
        }

        let ok = bridge.packetSendToHash(destHash: Data(hexString: channel.rfedNodeHash)!,
                                          appName: "rfed", aspects: "channel",
                                          payload: payload)
        if !ok {
            print("[RfedChannel] Send failed: \(bridge.lastError() ?? "unknown")")
            return
        }

        // Persist outgoing message locally — we know the plaintext directly.
        // Use the LXMF timestamp so the echo from RFed dedupes against this.
        let msgId = (Data(hexString: ownHashHex) ?? Data()).hexString + String(format: "%016llx", tsMs)
        let entity = ChannelMessageEntity(id: msgId, channelHash: channel.id,
                                          senderHash: ownHashHex, senderDisplayName: "",
                                          content: content, timestamp: Double(tsMs), isOutgoing: true)
        modelContext?.insert(entity)
        try? modelContext?.save()

        let msg = ChannelMessage(id: msgId, channelHash: channel.id,
                                  senderHash: ownHashHex, senderDisplayName: "", content: content,
                                  timestamp: Double(tsMs), isOutgoing: true)
        appendMessage(msg, toChannelHash: channel.id)
        updateChannelLastMessage(channelHashHex: channel.id, time: Double(tsMs))
    }

    // MARK: - Pull deferred blobs

    func pullDeferred(channel: Channel) async {
        guard let rfedDeliveryDest = Data(hexString: Self.rfedDestHash(
            identityHashHex: rfedIdentityHashFromChannelDest(channel.rfedNodeHash),
            app: "rfed", aspects: ["delivery"]
        )) else { return }

        let handle = identityHandle
        let bridge = self.bridge

        let response = await Task.detached(priority: .background) {
            bridge.linkRequest(destHash: rfedDeliveryDest, appName: "rfed", aspects: "delivery",
                               identityHandle: handle, path: "/rfed/pull",
                               payload: Data(), timeoutSecs: 15.0)
        }.value

        guard let data = response else {
            print("[RfedChannel] PULL: no response or error")
            return
        }

        let pairs = Self.decodePullResponse(data)
        for (channelHashData, blob) in pairs {
            await MainActor.run {
                self.dispatchBlob(channelHashHex: channelHashData.hexString, blob: blob)
            }
        }
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
        updateChannelLastMessage(channelHashHex: channelHashHex, time: Double(tsMs))

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
            Channel(id: $0.channelHash, channelName: $0.channelName,
                    rfedNodeHash: $0.rfedNodeHash, lastMessageTime: $0.lastMessageTime,
                    isSubscribed: $0.isSubscribed, stampCost: $0.stampCost)
        }
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
                                     timestamp: e.timestamp, isOutgoing: e.isOutgoing)
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

    /// Decode a msgpack PULL response: array of [bin(16), bin(*)] pairs.
    /// Simple hand-rolled decoder supporting only the format rfed emits.
    nonisolated static func decodePullResponse(_ data: Data) -> [(Data, Data)] {
        var result: [(Data, Data)] = []
        var i = data.startIndex

        func readBin(_ d: Data, _ idx: inout Data.Index) -> Data? {
            guard idx < d.endIndex else { return nil }
            let tag = d[idx]
            idx = d.index(after: idx)
            let len: Int
            if tag == 0xc4 {                          // bin8
                guard idx < d.endIndex else { return nil }
                len = Int(d[idx]); idx = d.index(after: idx)
            } else if tag == 0xc5 {                   // bin16
                guard d.index(idx, offsetBy: 2, limitedBy: d.endIndex) != d.endIndex else { return nil }
                len = Int(d[idx]) << 8 | Int(d[d.index(after: idx)])
                idx = d.index(idx, offsetBy: 2)
            } else { return nil }
            guard let end = d.index(idx, offsetBy: len, limitedBy: d.endIndex) else { return nil }
            let bytes = d[idx..<end]
            idx = end
            return Data(bytes)
        }

        // Skip outer array header (fixarray 0x9x or array16 0xdc / array32 0xdd)
        guard i < data.endIndex else { return result }
        let arrayTag = data[i]
        i = data.index(after: i)
        let count: Int
        if arrayTag & 0xf0 == 0x90 {                 // fixarray
            count = Int(arrayTag & 0x0f)
        } else if arrayTag == 0xdc {                  // array16
            guard data.index(i, offsetBy: 2, limitedBy: data.endIndex) != data.endIndex else { return result }
            count = Int(data[i]) << 8 | Int(data[data.index(after: i)])
            i = data.index(i, offsetBy: 2)
        } else { return result }

        for _ in 0..<count {
            // Each element is a 2-element fixarray
            guard i < data.endIndex, (data[i] & 0xf0) == 0x90 else { break }
            i = data.index(after: i)
            guard let channelHash = readBin(data, &i),
                  let blob = readBin(data, &i) else { break }
            result.append((channelHash, blob))
        }
        return result
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
