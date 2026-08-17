import Foundation

/// Speaks RFed's distro protocol on behalf of this device.
///
/// Mirrors `RfedChannelClient`: link management and requests go through
/// `ConnectionStateManager.appLinkSend`, while every payload and the blob
/// decrypt come from `lxmf_rust::distro` via the FFI — those are wire formats
/// and are shared with the Android bridge rather than rewritten here.
///
/// Delivery arrives on the SAME `rfed.delivery` destination as channel blobs,
/// distinguished only by the 16-byte routing prefix: the distro's delivery hash
/// instead of a channel hash. `RfedChannelClient.onRfedBlob` routes them here.
@MainActor
final class RfedDistroClient: ObservableObject {

    static let shared = RfedDistroClient()

    /// A decrypted distro message, ready to be stored as an inbound DM from
    /// whoever sent it.
    struct Message {
        let sourceHash: Data
        let timestamp: Double
        let title: String
        let content: String
        let ticket: String?
        /// A distro private key being handed to this device (FIELD_DISTRO_ID).
        let transferKey: String?
    }

    /// Fired for messages that should be shown. Delivery notifications and
    /// duplicates never reach it.
    var onMessage: ((Message) -> Void)?
    /// Fired when another device offers us a distro identity.
    var onIdentityOffered: ((_ senderHash: Data, _ privateKeyHex: String) -> Void)?

    @Published private(set) var isRegistered = false
    @Published private(set) var lastError: String?

    private var seen = DistroSeenStore()
    private var registerInFlight = false

    private init() {}

    // MARK: - Destinations

    /// `rfed.distro.register` on the configured node. The same destination also
    /// serves `/rfed/pull`, which is deliberate on the RFed side: reusing the
    /// register link avoids a second LINKREQUEST that a busy relay may drop
    /// (SPEC §17.8).
    private var registerDestHex: String {
        RfedChannelClient.rfedDestHash(
            identityHashHex: UserPreferences.shared.effectiveRfedNodeIdentityHash,
            app: "rfed", aspects: ["distro", "register"])
    }

    private var unregisterDestHex: String {
        RfedChannelClient.rfedDestHash(
            identityHashHex: UserPreferences.shared.effectiveRfedNodeIdentityHash,
            app: "rfed", aspects: ["distro", "unregister"])
    }

    // MARK: - Registration

    /// Enrol this device under the loaded distro identity, then hand RFed a
    /// pre-signed announce for the distro address.
    ///
    /// Both steps matter and the order is load-bearing. Registration tells RFed
    /// where to fan out; the announce is what makes the address resolvable at
    /// all. RFed only ever learns the distro PUBLIC key, so it cannot mint that
    /// announce itself — without it, senders cannot find a path and the distro
    /// silently receives nothing.
    @discardableResult
    func register(deviceIdentityHandle: UInt64) async -> Bool {
        // Two independent callers can reach this (app start and the moment a
        // key is generated or imported). Two concurrent registrations of the
        // same device under the same distro is meaningless, and issuing them
        // over one link has wedged RFed before — see the web client's
        // _registerDistro guard.
        guard !registerInFlight else { return isRegistered }
        registerInFlight = true
        defer { registerInFlight = false }

        let distro = DistroManager.shared
        guard distro.has else {
            lastError = "no distro identity loaded"
            return false
        }
        guard let payload = Self.registerPayload(device: deviceIdentityHandle,
                                                 distro: distro.handle) else {
            lastError = "could not build the register payload"
            return false
        }
        guard let dest = Data(distroHexString: registerDestHex), dest.count == 16 else {
            lastError = "rfed.distro.register destination unavailable"
            return false
        }

        let response = await ConnectionStateManager.shared.appLinkSend(
            destHash: dest, app: "rfed", aspects: ["distro", "register"],
            path: "/rfed/distro/register", payload: payload)

        guard let response, Self.isAffirmative(response) else {
            lastError = "RFed refused the registration"
            isRegistered = false
            return false
        }
        isRegistered = true
        lastError = nil

        await publishAnnounce(destination: dest)
        return true
    }

    /// Hand RFed a pre-signed announce so it can advertise the distro address.
    private func publishAnnounce(destination: Data) async {
        guard let payload = Self.announcePayload(distro: DistroManager.shared.handle) else {
            lastError = "could not build the distro announce"
            return
        }
        let response = await ConnectionStateManager.shared.appLinkSend(
            destHash: destination, app: "rfed", aspects: ["distro", "register"],
            path: "/rfed/distro/announce", payload: payload)

        if response == nil || !Self.isAffirmative(response!) {
            // Not fatal: registration stands and fan-out still works for anyone
            // who already holds a path. New senders will not resolve the
            // address until an announce lands, so surface it.
            lastError = "RFed did not accept the distro announce"
        }
    }

    @discardableResult
    func unregister(deviceIdentityHandle: UInt64) async -> Bool {
        let distro = DistroManager.shared
        guard distro.has,
              let payload = Self.registerPayload(device: deviceIdentityHandle,
                                                 distro: distro.handle),
              let dest = Data(distroHexString: unregisterDestHex), dest.count == 16
        else { return false }

        let response = await ConnectionStateManager.shared.appLinkSend(
            destHash: dest, app: "rfed", aspects: ["distro", "unregister"],
            path: "/rfed/distro/unregister", payload: payload)

        let ok = response.map(Self.isAffirmative) ?? false
        if ok { isRegistered = false }
        return ok
    }

    // MARK: - Deferred delivery

    /// Collect blobs RFed held while this device was unreachable.
    ///
    /// Runs on the register destination, not `rfed.delivery`, to reuse that
    /// link (SPEC §17.8). Response: `[[distro_hash, blob], …], more_pending`.
    @discardableResult
    func pull() async -> Int {
        guard DistroManager.shared.has,
              let dest = Data(distroHexString: registerDestHex), dest.count == 16
        else { return 0 }

        let response = await ConnectionStateManager.shared.appLinkSend(
            destHash: dest, app: "rfed", aspects: ["distro", "register"],
            path: "/rfed/pull", payload: Data())

        guard let response else { return 0 }
        let blobs = Self.parsePullResponse(response)
        for blob in blobs { handleBlob(blob) }
        return blobs.count
    }

    // MARK: - Inbound

    /// Handle one distro blob, from live fan-out or from a PULL.
    ///
    /// `blob` is the LXMF propagation message WITHOUT the routing prefix that
    /// `rfed.delivery` prepends — the caller strips it.
    func handleBlob(_ blob: Data) {
        let distro = DistroManager.shared
        guard distro.has else { return }

        var outLen: UInt32 = 0
        let ptr = blob.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
            retichat_distro_unwrap(
                distro.handle,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt32(blob.count),
                &outLen)
        }
        guard let ptr else { return }
        let json = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)

        // Zero length is not an error: the blob was addressed to a different
        // distro, which a node may legitimately hand over.
        guard !json.isEmpty, let parsed = try? JSONDecoder().decode(UnwrappedBlob.self, from: json)
        else { return }

        // Idempotency. The same message arrives more than once — live fan-out,
        // deferred PULL, and a fresh fan-out whenever a node re-ingests it from
        // a peer. Key on the message, not the bytes: the live and PULL framings
        // differ, so the bytes are not a stable key.
        let key = "\(parsed.source_hash):\(parsed.timestamp)"
        guard !seen.checkAndRecord(key) else { return }

        guard let sourceHash = Data(distroHexString: parsed.source_hash) else { return }

        // A key transfer takes precedence: it is an offer to act on, not a
        // message to display.
        if let transfer = parsed.distro_transfer_key, !transfer.isEmpty {
            onIdentityOffered?(sourceHash, transfer)
            return
        }

        // Because this device signs outgoing mail as the distro, recipients
        // reply to the distro — including their delivery notifications, which
        // carry a ticket and no content. Storing those posts empty bubbles.
        if parsed.is_delivery_notification { return }

        onMessage?(Message(
            sourceHash: sourceHash,
            timestamp: parsed.timestamp,
            title: parsed.title,
            content: parsed.content,
            ticket: parsed.ticket,
            transferKey: nil))
    }

    private struct UnwrappedBlob: Decodable {
        let source_hash: String
        let timestamp: Double
        let title: String
        let content: String
        let is_delivery_notification: Bool
        let ticket: String?
        let distro_transfer_key: String?
    }

    // MARK: - FFI payload helpers

    private static func registerPayload(device: UInt64, distro: UInt64) -> Data? {
        var outLen: UInt32 = 0
        guard let ptr = retichat_distro_register_payload(device, distro, &outLen), outLen > 0
        else { return nil }
        let data = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)
        return data
    }

    private static func announcePayload(distro: UInt64) -> Data? {
        var outLen: UInt32 = 0
        guard let ptr = retichat_distro_announce_payload(distro, nil, 0, &outLen), outLen > 0
        else { return nil }
        let data = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)
        return data
    }

    // MARK: - Response parsing

    /// RFed answers these with msgpack `true` (0xc3), or an array whose first
    /// element is `true`. Mirrors RfedChannelClient.parseSubscribeResponse.
    private static func isAffirmative(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        if first == 0xc3 { return true }                 // bare true
        if first == 0x91 || first == 0x92 {              // fixarray-1 / fixarray-2
            return data.count > 1 && data[1] == 0xc3
        }
        return false
    }

    /// Extract the blobs from `[[distro_hash, blob], …], more_pending`.
    ///
    /// Deliberately a scan for the msgpack bin headers rather than a full
    /// decoder: the payload is two nested arrays of binaries, and the only
    /// parts we need are the blobs, which are the long ones. A malformed
    /// response yields nothing rather than throwing.
    private static func parsePullResponse(_ data: Data) -> [Data] {
        var blobs: [Data] = []
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            // bin8 / bin16 / bin32
            let headerLen: Int
            let payloadLen: Int
            switch byte {
            case 0xc4 where i + 1 < data.endIndex:
                headerLen = 2
                payloadLen = Int(data[i + 1])
            case 0xc5 where i + 2 < data.endIndex:
                headerLen = 3
                payloadLen = Int(data[i + 1]) << 8 | Int(data[i + 2])
            case 0xc6 where i + 4 < data.endIndex:
                headerLen = 5
                payloadLen = Int(data[i + 1]) << 24 | Int(data[i + 2]) << 16
                           | Int(data[i + 3]) << 8 | Int(data[i + 4])
            default:
                i = data.index(after: i)
                continue
            }
            let start = data.index(i, offsetBy: headerLen)
            guard let end = data.index(start, offsetBy: payloadLen, limitedBy: data.endIndex)
            else { break }
            // 16-byte entries are the routing hash; anything larger is a blob.
            if payloadLen > 16 { blobs.append(data[start..<end]) }
            i = end
        }
        return blobs
    }
}

/// Remembers which distro messages have already been handled.
///
/// Persisted, because the deferred queue outlives an app launch: a blob still
/// held by RFed would otherwise be re-admitted on next start and appear twice.
private struct DistroSeenStore {
    private let key = "distro_seen_keys"
    private let limit = 500

    /// True when `key` was already recorded. Records it either way.
    mutating func checkAndRecord(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        var keys = defaults.stringArray(forKey: self.key) ?? []
        if keys.contains(key) { return true }
        keys.append(key)
        if keys.count > limit { keys.removeFirst(keys.count - limit) }
        defaults.set(keys, forKey: self.key)
        return false
    }
}
