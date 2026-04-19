//
//  RfedChannelClient.swift
//  Retichat
//
//  Pub-sub channel messaging via the RFed federation server.
//
//  Architecture:
//    SEND   → fire-and-forget DATA packet to rfed.channel dest
//             payload: channel_hash(16) | inner_blob(*)
//    SUB    → link request /rfed/subscribe on rfed.channel, payload: msgpack bin(16)
//    UNSUB  → link request /rfed/unsubscribe on rfed.channel, payload: msgpack bin(16)
//    RECV   → inbound DATA at local rfed.delivery dest (set up via FFI)
//    PULL   → link request /rfed/pull on rfed.delivery, response: [[bin16, blob], ...]
//
//  Inner blob format:
//    0x01 | senderIdentityHash(16) | timestampMS_BE(8) | utf8content(*)
//

import Foundation
import SwiftData
import CryptoKit

@MainActor
final class RfedChannelClient: ObservableObject, RfedBlobCallback {

    // MARK: - Published state

    @Published var channels: [Channel] = []
    @Published var messages: [String: [ChannelMessage]] = [:]   // keyed by channelHash hex

    // MARK: - Dependencies

    private let bridge = RetichatBridge.shared
    private let prefs  = UserPreferences.shared

    private var modelContext: ModelContext?
    private var identityHandle: UInt64 = 0
    private var ownHashHex: String = ""

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
    }

    func stop() {
        bridge.stopRfedDelivery()
    }

    func announceDelivery() {
        _ = bridge.rfedDeliveryAnnounce()
    }

    // MARK: - Channel management

    /// Join (or create) a channel. Derives the channel hash from the name, subscribes
    /// on the rfed node, and persists the channel locally.
    func joinChannel(name: String, rfedNodeIdentityHashHex: String) async throws -> Channel {
        let channelHashData = try Self.channelHash(name: name)
        let channelHashHex = channelHashData.hexString

        // Already joined?
        if let existing = channels.first(where: { $0.id == channelHashHex }) {
            return existing
        }

        let rfedChannelDestHex = Self.rfedDestHash(identityHashHex: rfedNodeIdentityHashHex,
                                                    app: "rfed", aspects: ["channel"])
        guard let rfedChannelDest = Data(hexString: rfedChannelDestHex) else {
            throw ChannelError.invalidRfedNode
        }

        // Subscribe on the server (background thread, blocking)
        try await subscribeOnServer(channelHashData: channelHashData,
                                    rfedChannelDest: rfedChannelDest)

        // Persist
        let entity = ChannelEntity(channelHash: channelHashHex, channelName: name,
                                   rfedNodeHash: rfedChannelDestHex, isSubscribed: true)
        modelContext?.insert(entity)
        try modelContext?.save()

        let channel = Channel(id: channelHashHex, channelName: name,
                              rfedNodeHash: rfedChannelDestHex,
                              lastMessageTime: 0, isSubscribed: true)
        channels.append(channel)
        return channel
    }

    /// Leave a channel. Unsubscribes from the rfed node and removes local data.
    func leaveChannel(channelHashHex: String) async {
        guard let channel = channels.first(where: { $0.id == channelHashHex }) else { return }
        guard let channelHashData = Data(hexString: channelHashHex),
              let rfedDest = Data(hexString: channel.rfedNodeHash) else { return }

        Task.detached(priority: .background) { [bridge = self.bridge, handle = identityHandle] in
            let payload = Self.msgpackBin(channelHashData)
            _ = bridge.linkRequest(destHash: rfedDest, appName: "rfed", aspects: "channel",
                                   identityHandle: handle, path: "/rfed/unsubscribe",
                                   payload: payload, timeoutSecs: 10.0)
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

    // MARK: - Send

    func sendMessage(content: String, toChannel channel: Channel) {
        guard let channelHashData = Data(hexString: channel.id) else { return }

        // Build inner blob
        let senderHashData = Data(hexString: ownHashHex) ?? Data(repeating: 0, count: 16)
        let blob = Self.encodeBlob(senderHash: senderHashData, content: content)

        // Packet payload: channel_hash(16) | inner_blob
        let payload = channelHashData + blob

        let ok = bridge.packetSendToHash(destHash: Data(hexString: channel.rfedNodeHash)!,
                                          appName: "rfed", aspects: "channel",
                                          payload: payload)
        if !ok {
            print("[RfedChannel] Send failed: \(bridge.lastError() ?? "unknown")")
            return
        }

        // Persist outgoing message locally
        let tsMs = Date().timeIntervalSince1970 * 1000
        let msgId = ownHashHex + String(format: "%016llx", UInt64(tsMs))
        let entity = ChannelMessageEntity(id: msgId, channelHash: channel.id,
                                          senderHash: ownHashHex, content: content,
                                          timestamp: tsMs, isOutgoing: true)
        modelContext?.insert(entity)
        try? modelContext?.save()

        let msg = ChannelMessage(id: msgId, channelHash: channel.id,
                                  senderHash: ownHashHex, content: content,
                                  timestamp: tsMs, isOutgoing: true)
        appendMessage(msg, toChannelHash: channel.id)
        updateChannelLastMessage(channelHashHex: channel.id, time: tsMs)
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
        guard blob.count > 16 else { return }
        let channelHashData = blob.prefix(16)
        let innerBlob = blob.dropFirst(16)
        let channelHashHex = channelHashData.hexString

        Task { @MainActor in
            self.dispatchBlob(channelHashHex: channelHashHex, blob: Data(innerBlob))
        }
    }

    // MARK: - Private

    private func dispatchBlob(channelHashHex: String, blob: Data) {
        guard let (senderHash, tsMs, content) = Self.decodeBlob(blob) else { return }

        // Deduplicate
        let msgId = senderHash + String(format: "%016llx", UInt64(tsMs))
        let existing = messages[channelHashHex]?.contains(where: { $0.id == msgId }) ?? false
        guard !existing else { return }

        // Skip if this channel is not known
        guard channels.contains(where: { $0.id == channelHashHex }) else { return }

        let isOutgoing = senderHash == ownHashHex
        let entity = ChannelMessageEntity(id: msgId, channelHash: channelHashHex,
                                          senderHash: senderHash, content: content,
                                          timestamp: Double(tsMs), isOutgoing: isOutgoing)
        modelContext?.insert(entity)
        try? modelContext?.save()

        let msg = ChannelMessage(id: msgId, channelHash: channelHashHex,
                                  senderHash: senderHash, content: content,
                                  timestamp: Double(tsMs), isOutgoing: isOutgoing)
        appendMessage(msg, toChannelHash: channelHashHex)
        updateChannelLastMessage(channelHashHex: channelHashHex, time: Double(tsMs))
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

    private func subscribeOnServer(channelHashData: Data,
                                   rfedChannelDest: Data) async throws {
        let payload = Self.msgpackBin(channelHashData)
        let handle = identityHandle
        let bridge = self.bridge

        let response = await Task.detached(priority: .background) {
            bridge.linkRequest(destHash: rfedChannelDest, appName: "rfed", aspects: "channel",
                               identityHandle: handle, path: "/rfed/subscribe",
                               payload: payload, timeoutSecs: 15.0)
        }.value

        guard let resp = response else {
            throw ChannelError.subscribeFailed(bridge.lastError() ?? "no response")
        }
        // Server responds msgpack bool true (0xc3)
        guard resp.count >= 1, resp[0] == 0xc3 else {
            throw ChannelError.subscribeFailed("unexpected response: \(resp.hexString)")
        }
    }

    private func loadPersistedChannels() {
        guard let ctx = modelContext else { return }
        let entities = (try? ctx.fetch(FetchDescriptor<ChannelEntity>())) ?? []
        channels = entities.map {
            Channel(id: $0.channelHash, channelName: $0.channelName,
                    rfedNodeHash: $0.rfedNodeHash, lastMessageTime: $0.lastMessageTime,
                    isSubscribed: $0.isSubscribed)
        }
    }

    private func loadPersistedMessages() {
        guard let ctx = modelContext else { return }
        let entities = (try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>())) ?? []
        var grouped: [String: [ChannelMessage]] = [:]
        for e in entities {
            let msg = ChannelMessage(id: e.id, channelHash: e.channelHash,
                                     senderHash: e.senderHash, content: e.content,
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
    static func channelHash(name: String) throws -> Data {
        let seed = Data(SHA256.hash(data: Data(name.utf8)))
        let x25519Pub = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
                            .publicKey.rawRepresentation
        let ed25519Pub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                            .publicKey.rawRepresentation
        let bundle = x25519Pub + ed25519Pub
        return Data(SHA256.hash(data: bundle).prefix(16))
    }

    /// Compute an RNS SINGLE-destination hash (mirrors Reticulum Destination::hash()).
    static func rfedDestHash(identityHashHex: String, app: String, aspects: [String]) -> String {
        let hex = identityHashHex.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.count == 32, let identityBytes = Data(hexString: hex) else { return "" }
        let name = ([app] + aspects).joined(separator: ".")
        let nameHashFull = SHA256.hash(data: Data(name.utf8))
        let nameHashTrunc = Data(nameHashFull.prefix(10))
        let material = nameHashTrunc + identityBytes
        return Data(SHA256.hash(data: material).prefix(16)).hexString
    }

    /// Encode inner blob: 0x01 | senderHash(16) | timestampMS_BE(8) | utf8content
    static func encodeBlob(senderHash: Data, content: String) -> Data {
        var blob = Data([0x01])
        let hash16 = senderHash.count >= 16 ? senderHash.prefix(16) : (senderHash + Data(repeating: 0, count: 16 - senderHash.count))
        blob.append(contentsOf: hash16)
        let tsMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var tsBytes = tsMs.bigEndian
        blob.append(contentsOf: withUnsafeBytes(of: &tsBytes) { Data($0) })
        blob.append(Data(content.utf8))
        return blob
    }

    /// Decode inner blob. Returns (senderHashHex, timestampMS, content) or nil on error.
    static func decodeBlob(_ blob: Data) -> (String, UInt64, String)? {
        guard blob.count >= 25, blob[0] == 0x01 else { return nil }
        let senderHashHex = blob[1..<17].hexString
        let tsBE = blob[17..<25].withUnsafeBytes { $0.load(as: UInt64.self) }
        let tsMs = UInt64(bigEndian: tsBE)
        guard let content = String(data: blob[25...], encoding: .utf8) else { return nil }
        return (senderHashHex, tsMs, content)
    }

    /// Encode a 16-byte value as msgpack bin8: 0xc4 | len | bytes
    static func msgpackBin(_ data: Data) -> Data {
        var out = Data([0xc4, UInt8(data.count)])
        out.append(data)
        return out
    }

    /// Decode a msgpack PULL response: array of [bin(16), bin(*)] pairs.
    /// Simple hand-rolled decoder supporting only the format rfed emits.
    static func decodePullResponse(_ data: Data) -> [(Data, Data)] {
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
