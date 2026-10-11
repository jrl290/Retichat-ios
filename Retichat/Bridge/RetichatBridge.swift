//
//  RetichatBridge.swift
//  Retichat
//
//  Swift wrapper around the C FFI to Reticulum/LXMF Rust libraries.
//  Transport, settings, raw packet, link request, and callback dispatch.
//  LXMF protocol operations are handled by LxmfClient.swift.
//

import Foundation

// MARK: - Callback protocols

/// `unverifiedReason`: 0 validated, 1 source unknown (no key for the source
/// yet), 2 signature invalid. DISPLAY_NAMES.md §5.2 accepts a 0xD1 name
/// differently for 1 and 2, so names are decided on it, not on signatureValid.
///
/// An accept or a leave of a group carries its sender's own key (RFed-spec
/// Group.md, "The sender's key"): `senderKey` is that key (64 bytes) when it binds
/// to the message's source, and the glue crate has then checked the signature
/// under it for a source the router held no key for, so `unverifiedReason` is 0 or
/// 2 for it, never 1 for want of a key. `packed` is the whole message as received
/// (an accept or leave of at most 2144 bytes), what a creator keeps. Both are nil
/// for every other message. Nothing is remembered: the group code remembers the
/// key once the group rule has passed (GroupStatusEngine.onKept).
protocol MessageCallback: AnyObject {
    @MainActor func onMessage(hash: Data, srcHash: Data, destHash: Data,
                              title: String, content: String, timestamp: Double,
                              signatureValid: Bool, unverifiedReason: Int, fieldsRaw: Data,
                              senderKey: Data?, packed: Data?)
}

/// `displayName` is the announce's name cleaned by the Rust side with the
/// announce rules (DISPLAY_NAMES.md §5.1 announceName), or nil when the
/// announce carries none.
protocol AnnounceCallback: AnyObject {
    @MainActor func onAnnounce(destHash: Data, displayName: String?)
}

/// Receives outbound message state transitions from Rust.
/// Fired at: SENT (0x04), DELIVERED (0x08), REJECTED (0xFD), CANCELLED (0xFE), FAILED (0xFF).
protocol MessageStateCallback: AnyObject {
    @MainActor func onMessageState(hash: Data, state: UInt8)
}

/// Receives inbound RFed channel blobs from the local `rfed.delivery`
/// compatibility destination.
///
/// Fired from a Rust background thread. Implementations that touch actor-bound
/// or UI state must hop themselves.
protocol RfedBlobCallback: AnyObject {
    func onRfedBlob(_ blob: Data)
}

// MARK: - Message delivery method constants

enum LxmfMethod {
    static let opportunistic: UInt8 = 0x01
    static let direct: UInt8 = 0x02
    static let propagated: UInt8 = 0x03
}

// MARK: - Message state constants

enum LxmfState {
    static let new_: Int32 = 0
    static let generating: Int32 = 1
    static let sent: Int32 = 2
    static let delivered: Int32 = 4
    static let failed: Int32 = 255
}

// MARK: - RetichatBridge

final class RetichatBridge: @unchecked Sendable {
    static let shared = RetichatBridge()

    private weak var messageCallback: MessageCallback?
    private weak var announceCallback: AnnounceCallback?
    private weak var messageStateCallback: (any MessageStateCallback)?
    private weak var rfedBlobCallback: RfedBlobCallback?

    private init() {}

    private static func ffiAspectsCsv(appName: String, aspects: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = aspects
            .split(whereSeparator: { $0 == "." || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.first == app {
            parts.removeFirst()
        }

        return parts.joined(separator: ",")
    }

    // MARK: - Callback wiring

    /// Wire LxmfClient callbacks through this bridge's dispatch mechanism.
    func wireCallbacks(to client: LxmfClient, messageCallback: MessageCallback, announceCallback: AnnounceCallback?, messageStateCallback: (any MessageStateCallback)? = nil) {
        self.messageCallback = messageCallback
        self.announceCallback = announceCallback
        self.messageStateCallback = messageStateCallback
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if !client.setDeliveryCallbackReceipt(deliveryTrampoline, context: ctx) {
            print("[RetichatBridge] wireCallbacks: setDeliveryCallbackReceipt FAILED — inbound messages will be silently dropped")
        }
        if announceCallback != nil {
            if !client.setAnnounceCallback(announceTrampoline, context: ctx) {
                print("[RetichatBridge] wireCallbacks: setAnnounceCallback FAILED")
            }
        }
        if !client.setMessageStateCallback(messageStateTrampoline, context: ctx) {
            print("[RetichatBridge] wireCallbacks: setMessageStateCallback FAILED")
        }
    }

    func rfedDeliveryStart(identityHandle: UInt64, callback: RfedBlobCallback) -> Bool {
        rfedBlobCallback = callback
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let ok = retichat_rfed_delivery_start(identityHandle, rfedBlobTrampoline, ctx) == 0
        if !ok {
            rfedBlobCallback = nil
        }
        return ok
    }

    func rfedDeliveryAnnounce() -> Bool {
        retichat_rfed_delivery_announce() == 0
    }

    func rfedDeliveryStop() -> Bool {
        let ok = retichat_rfed_delivery_stop() == 0
        rfedBlobCallback = nil
        return ok
    }

    // MARK: - Last error

    func lastError() -> String? {
        guard let ptr = lxmf_last_error() else { return nil }
        let str = String(cString: ptr)
        lxmf_free_string(ptr)
        return str
    }

    /// nonisolated because the Rust side keeps the last error THREAD-LOCAL
    /// (reticulum_rust::ffi::set_error): it must be read on the thread whose
    /// FFI call failed, which for the nonisolated wrappers below is not main.
    nonisolated func rnsLastError() -> String? {
        guard let ptr = rns_last_error() else { return nil }
        let str = String(cString: ptr)
        rns_free_string(ptr)
        return str
    }

    // MARK: - Transport

    nonisolated func transportHasPath(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_has_path(ptr, UInt32(destHash.count)) == 1
        }
    }

    nonisolated func transportPathVerifiedThisSession(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_path_verified_this_session(ptr, UInt32(destHash.count)) == 1
        }
    }

    /// True iff the destination's identity (public key) is in the
    /// known-destinations table. Sending an encrypted packet requires
    /// identity, not just a path.
    nonisolated func transportIdentityKnown(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_identity_known(ptr, UInt32(destHash.count)) == 1
        }
    }

    nonisolated func recalledPublicKey(destHash: Data) -> Data? {
        var output = Data(count: 64)
        let capacity = output.count
        let count = output.withUnsafeMutableBytes { outBuf in
            destHash.withUnsafeBytes { hashBuf in
                retichat_identity_recall_public_key(
                    hashBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(destHash.count),
                    outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(capacity)
                )
            }
        }
        return count == 64 ? output : nil
    }

    nonisolated func rememberLxmfDelivery(destHash: Data, publicKey: Data) -> Bool {
        destHash.withUnsafeBytes { hashBuf in
            publicKey.withUnsafeBytes { keyBuf in
                retichat_identity_remember_lxmf_delivery(
                    hashBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(destHash.count),
                    keyBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(publicKey.count)
                ) == 0
            }
        }
    }

    nonisolated func transportRequestPath(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_request_path(ptr, UInt32(destHash.count)) == 0
        }
    }

    @discardableResult
    nonisolated func rememberDestination(destHash: Data, publicKey: Data) -> Bool {
        return destHash.withUnsafeBytes { hashBuf in
            publicKey.withUnsafeBytes { keyBuf in
                let hashPtr = hashBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                let keyPtr = keyBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return retichat_identity_remember_destination(
                    hashPtr, UInt32(destHash.count),
                    keyPtr, UInt32(publicKey.count)
                ) == 0
            }
        }
    }

    /// Clone a live path entry from one destination hash to another and
    /// seed the destination hash with the source destination's public key
    /// when available.
    /// Write a consistent copy of the known destinations database to `path`
    /// (the NSE's storage; PendingNotification.nseKnownDestinationsPath).
    @discardableResult
    nonisolated func snapshotKnownDestinations(to path: String) -> Bool {
        let ok = path.withCString { retichat_known_destinations_snapshot($0) } == 1
        if !ok {
            print("[Retichat] known destinations snapshot for the NSE failed: \(rnsLastError() ?? "unknown error")")
        }
        return ok
    }

    nonisolated func transportClonePathAndIdentity(from sourceHash: Data, to destHash: Data) -> Bool {
        return sourceHash.withUnsafeBytes { sourceBuf in
            destHash.withUnsafeBytes { destBuf in
                let sourcePtr = sourceBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                let destPtr = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return retichat_transport_clone_path_and_identity(
                    sourcePtr, UInt32(sourceHash.count),
                    destPtr, UInt32(destHash.count)
                ) == 1
            }
        }
    }

    nonisolated func transportHopsTo(destHash: Data) -> Int32 {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_hops_to(ptr, UInt32(destHash.count))
        }
    }

    /// Query whether the cached path's attached interface is online.
    /// Returns: .some(true) if online, .some(false) if offline, nil if there
    /// is no cached path or the interface cannot be resolved.
    nonisolated func transportPathInterfaceOnline(destHash: Data) -> Bool? {
        let result = destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_path_interface_online(ptr, UInt32(destHash.count))
        }
        switch result {
        case 1:  return true
        case 0:  return false
        default: return nil
        }
    }

    /// Soft-expire a cached path so future sends request a fresh route.
    @discardableResult
    nonisolated func transportDropPath(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_drop_path(ptr, UInt32(destHash.count)) == 1
        }
    }

    /// If the cached path is pinned to an offline interface, expire it and
    /// immediately request a fresh path.
    @discardableResult
    nonisolated func transportRefreshOfflinePath(destHash: Data) -> Bool {
        guard transportHasPath(destHash: destHash) else { return false }
        guard transportPathInterfaceOnline(destHash: destHash) == false else { return false }
        _ = transportDropPath(destHash: destHash)
        _ = transportRequestPath(destHash: destHash)
        return true
    }

    /// Force-flush the in-memory destination/path table to disk so newly
    /// resolved essential paths survive a force-quit before the next
    /// 5-minute periodic persist tick.
    nonisolated func transportSavePaths() {
        _ = retichat_transport_save_paths()
    }

    /// Query whether a configured Reticulum interface is currently online.
    /// Returns: .some(true) if online, .some(false) if offline, nil if unknown
    /// (interface not registered, e.g. not yet configured or wrong name).
    nonisolated func interfaceOnline(name: String) -> Bool? {
        let result = name.withCString { cName in
            rns_interface_online(cName)
        }
        switch result {
        case 1:  return true
        case 0:  return false
        default: return nil
        }
    }

    // MARK: - Settings

    func setDropAnnounces(enabled: Bool) {
        retichat_set_drop_announces(enabled ? 1 : 0)
    }

    /// Add a destination to the announce watchlist so its announces pass
    /// through even when drop_announces is enabled.
    func watchAnnounce(destHash: Data) {
        destHash.withUnsafeBytes { buf in
            retichat_watch_announce(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    UInt32(destHash.count))
        }
    }

    /// Remove a destination from the announce watchlist.
    func unwatchAnnounce(destHash: Data) {
        destHash.withUnsafeBytes { buf in
            retichat_unwatch_announce(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                      UInt32(destHash.count))
        }
    }

    func setKeepaliveInterval(secs: Double) -> Bool {
        return retichat_set_keepalive_interval(secs) == 0
    }

    // MARK: - Network Connectivity

    /// Signal that network connectivity has been restored.
    /// Wakes TCP reconnect loops for an immediate retry.
    func nudgeReconnect() {
        rns_nudge_reconnect()
    }

    // MARK: - Raw packet send

    @available(*, deprecated, message: "Use AppLinks DATA delivery helpers instead of raw packet sends from app code.")
    func packetSendToHash(destHash: Data, appName: String, aspects: String,
                          payload: Data) -> Bool {
        let aspectsCsv = Self.ffiAspectsCsv(appName: appName, aspects: aspects)
        return destHash.withUnsafeBytes { hashBuf in
            payload.withUnsafeBytes { payBuf in
                appName.withCString { cApp in
                    aspectsCsv.withCString { cAsp in
                        let hPtr = hashBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        let pPtr = payBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        return retichat_packet_send_to_hash(
                            hPtr, UInt32(destHash.count),
                            cApp, cAsp,
                            pPtr, UInt32(payload.count)
                        ) == 0
                    }
                }
            }
        }
    }

    // MARK: - Identity signing

    /// Return the 64-byte public key (32 X25519 enc + 32 Ed25519 sign) for the identity.
    nonisolated func identityPublicKey(handle: UInt64) -> Data? {
        var buf = Data(count: 64)
        let rc = buf.withUnsafeMutableBytes { p in
            retichat_identity_public_key(handle, p.baseAddress?.assumingMemoryBound(to: UInt8.self), 64)
        }
        return rc == 64 ? buf : nil
    }

    /// Sign `data` with the identity's Ed25519 key. Returns 64-byte signature, or nil on error.
    nonisolated func identitySign(handle: UInt64, data: Data) -> Data? {
        var sig = Data(count: 64)
        let rc = data.withUnsafeBytes { dataBuf in
            sig.withUnsafeMutableBytes { sigBuf in
                retichat_identity_sign(
                    handle,
                    dataBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt32(data.count),
                    sigBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    64
                )
            }
        }
        return rc == 64 ? sig : nil
    }

    // MARK: - Channel crypto
    //
    // CHANNEL MESSAGES ARE LXMF PACKAGES. Use `channelLxmPack` /
    // `channelLxmUnpack` (below) — they wrap the LXMF propagation format
    // (signature-validated against the cached source identity).
    // Raw `channelEncrypt`/`channelDecrypt` of an arbitrary plaintext
    // bypasses signature verification and is intentionally NOT exposed.

    /// Compute a PoW stamp for `payload` (channel_hash || ciphertext) using the given cost.
    /// Returns nil when cost == 0 (no stamp needed). Blocks until the nonce is found.
    nonisolated func channelComputeStamp(payload: Data, cost: Int32) -> Data? {
        guard cost > 0 else { return nil }
        var outLen: UInt32 = 0
        guard let ptr = payload.withUnsafeBytes({ buf in
            retichat_compute_channel_stamp(
                buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt32(payload.count),
                UInt32(cost),
                &outLen
            )
        }) else { return nil }
        let data = Data(bytes: ptr, count: Int(outLen))
        lxmf_free_bytes(ptr, outLen)
        return data
    }

    // MARK: - Channel LXMF pack / unpack
    //
    // CHANNEL MESSAGES ARE LXMF PACKAGES. The `lxmfData` blob produced here
    // is the EXACT SAME byte format an LXMF propagation node stores and
    // delivers: [channel_hash(16) | EC_encrypted(source_hash || signature ||
    // msgpack_payload)]. RFed routes it opaquely. Receivers feed it back to
    // `channelLxmUnpack` which uses LXMessage::unpack_from_bytes(PROPAGATED)
    // and validates the Ed25519 signature against the cached source identity.

    /// Result of unpacking a channel LXMF message.
    struct ChannelLxmUnpackResult {
        /// 16-byte source (sender) destination hash.
        let sourceHash: Data
        /// Sender timestamp in milliseconds (LXMF carries it as f64 seconds).
        let timestampMs: UInt64
        /// True iff the Ed25519 signature was verified against the cached
        /// source identity. False means the sender hasn't been seen via an
        /// announce yet, OR the signature didn't match — see `unverifiedReason`.
        let signatureValidated: Bool
        /// 0 = ok, 1 = SOURCE_UNKNOWN, 2 = SIGNATURE_INVALID.
        let unverifiedReason: UInt8
        /// Title bytes (may be empty).
        let title: Data
        /// Content bytes (UTF-8 message body).
        let content: Data
        /// The post's Channel Display Name (field 0xD1, DISPLAY_NAMES.md
        /// §2.3). The Rust side reports it only when the signature
        /// validated; otherwise it is .absent.
        let displayName: DisplayNames.NameField
    }

    /// Result of packing a channel LXMF message.
    struct ChannelLxmPackResult {
        /// LXMF timestamp baked into the signed payload, in milliseconds.
        /// Use this for local persistence so the echo back from RFed
        /// dedupes against the optimistic local message.
        let timestampMs: UInt64
        /// On-wire payload to send to RFed.channel:
        ///     [ channel_id_hash(16) | EC_encrypted(source_hash || sig || payload) ]
        /// Optionally append a PoW stamp.
        let wirePayload: Data
    }

    /// Build an LXMF channel message and return the on-wire payload plus
    /// the LXMF timestamp the sender baked into the signed body.
    /// `displayName` is the Channel Display Name decision for this post
    /// (DISPLAY_NAMES.md §4.2, DisplayNames.channelPostName): .absent writes
    /// no 0xD1, .clear an empty one, .name the (cleaned) name.
    nonisolated func channelLxmPack(name: String,
                                    senderIdentityHandle: UInt64,
                                    content: Data,
                                    title: Data,
                                    displayName: DisplayNames.NameField) -> ChannelLxmPackResult? {
        var outLen: UInt32 = 0
        let nameBytes: Data
        if case .name(let n) = displayName { nameBytes = Data(n.utf8) } else { nameBytes = Data() }
        guard let ptr = name.withCString({ cName in
            content.withUnsafeBytes { cBuf in
                title.withUnsafeBytes { tBuf in
                    nameBytes.withUnsafeBytes { nBuf in
                        retichat_channel_lxm_pack(
                            cName,
                            senderIdentityHandle,
                            cBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            UInt32(content.count),
                            tBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            UInt32(title.count),
                            displayName.stateByte,
                            nBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            UInt32(nameBytes.count),
                            &outLen
                        )
                    }
                }
            }
        }) else { return nil }
        let raw = Data(bytes: ptr, count: Int(outLen))
        lxmf_free_bytes(ptr, outLen)
        // Layout: 8-byte ts_ms_be | wire_payload
        guard raw.count >= 8 + 16 else { return nil }
        let ts = raw.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let wire = raw.subdata(in: 8..<raw.count)
        return ChannelLxmPackResult(timestampMs: ts, wirePayload: wire)
    }

    /// Unpack an LXMF channel message received from RFed. `lxmfData` MUST
    /// start with the 16-byte channel_hash. Returns parsed fields including
    /// signature-validation status. Returns nil on hard failure (corrupt or
    /// undecryptable bytes, or a key that does not bind to the claimed
    /// sender: DISPLAY_NAMES.md §2.3).
    nonisolated func channelLxmUnpack(name: String, lxmfData: Data) -> ChannelLxmUnpackResult? {
        var outLen: UInt32 = 0
        guard let ptr = name.withCString({ cName in
            lxmfData.withUnsafeBytes { buf in
                retichat_channel_lxm_unpack(
                    cName,
                    buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt32(lxmfData.count),
                    &outLen
                )
            }
        }) else { return nil }
        let raw = Data(bytes: ptr, count: Int(outLen))
        lxmf_free_bytes(ptr, outLen)

        // The NSE reads the same layout (NSEChannelUnpackDecoder); one parser.
        guard let m = ChannelUnpackLayout.decode(raw) else { return nil }
        return ChannelLxmUnpackResult(
            sourceHash: m.sourceHash,
            timestampMs: m.timestampMs,
            signatureValidated: m.signatureValidated,
            unverifiedReason: m.unverifiedReason,
            title: m.title,
            content: m.content,
            displayName: m.displayName
        )
    }

    // MARK: - Distro

    // Mirrors Android RetichatBridge.peerIsDistro and
    // messageCreate(destHash, srcHash, …, identityHandle)
    // (Retichat-android rust/retichat-jni nativePeerIsDistro / nativeMessageCreate).
    // The retichat_distro_* payload functions are deliberately not wrapped
    // here: RfedDistroClient/DistroManager call them directly.

    /// True when `destHash`'s last lxmf.delivery announce carried the distro
    /// flag (RFed SPEC §17.10). The announce is the ONLY source of this fact —
    /// an lxma:// link carries a key, never distro-ness — so an unknown
    /// destination reads false. A send to a distro should go PROPAGATED at
    /// once: no device answers a direct link to the distro address.
    nonisolated func peerIsDistro(destHash: Data) -> Bool {
        guard destHash.count == 16 else { return false }
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_peer_is_distro(ptr, UInt32(destHash.count)) == 1
        }
    }

    /// Create an outbound message whose source address and signing identity
    /// the caller chooses. `lxmf_message_new` always signs as the device; a
    /// device holding a distro sends AS the distro (source = distro delivery
    /// hash, identity = distro handle) so replies fan out to every device.
    ///
    /// `method` is the raw LXMF constant (0x01 opportunistic, 0x02 direct,
    /// 0x03 propagated). The returned handle is an ordinary message handle:
    /// every lxmf_message_* function accepts it. Returns 0 on failure.
    nonisolated func messageCreate(destHash: Data, sourceHash: Data, content: String, title: String,
                                   method: UInt8, identityHandle: UInt64) -> UInt64 {
        let handle = destHash.withUnsafeBytes { destBuf in
            sourceHash.withUnsafeBytes { srcBuf in
                content.withCString { cContent in
                    title.withCString { cTitle in
                        retichat_message_create(
                            destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(destHash.count),
                            srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(sourceHash.count),
                            cContent, cTitle,
                            method, identityHandle
                        )
                    }
                }
            }
        }
        if handle == 0 {
            // Read on this thread: the Rust error slot is thread-local.
            print("[RetichatBridge] messageCreate failed: \(rnsLastError() ?? "?")")
        }
        return handle
    }

    // MARK: - Link request

    @available(*, deprecated, message: "Use AppLinks request helpers instead of raw one-shot link requests from app code.")
    nonisolated func linkRequest(destHash: Data, appName: String, aspects: String,
                     identityHandle: UInt64, path: String,
                     payload: Data, timeoutSecs: Double = 15.0) -> Data? {
        let aspectsCsv = Self.ffiAspectsCsv(appName: appName, aspects: aspects)
        return destHash.withUnsafeBytes { hashBuf in
            payload.withUnsafeBytes { payBuf in
                appName.withCString { cApp in
                    aspectsCsv.withCString { cAsp in
                        path.withCString { cPath in
                            var outLen: UInt32 = 0
                            let hPtr = hashBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            let pPtr = payBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            guard let ptr = retichat_link_request(
                                hPtr, UInt32(destHash.count),
                                cApp, cAsp,
                                identityHandle,
                                cPath,
                                pPtr, UInt32(payload.count),
                                timeoutSecs,
                                &outLen
                            ) else {
                                return nil
                            }
                            let data = Data(bytes: ptr, count: Int(outLen))
                            lxmf_free_bytes(ptr, outLen)
                            return data
                        }
                    }
                }
            }
        }
    }

    // MARK: - Internal callback dispatch

    func handleDelivery(hash: Data, srcHash: Data, destHash: Data,
                        title: String, content: String, timestamp: Double,
                        signatureValid: Bool, unverifiedReason: Int, fieldsRaw: Data,
                        senderKey: Data?, packed: Data?) {
        // Capture the callback before hopping to MainActor so a transient
        // lifecycle change cannot nil out the weak reference after Rust has
        // already accepted the delivery.
        guard let callback = messageCallback else {
            print("[RetichatBridge] handleDelivery: DROPPED - messageCallback is nil (ChatRepository deallocated?)")
            return
        }

        Task { @MainActor in
            callback.onMessage(
                hash: hash, srcHash: srcHash, destHash: destHash,
                title: title, content: content, timestamp: timestamp,
                signatureValid: signatureValid, unverifiedReason: unverifiedReason,
                fieldsRaw: fieldsRaw, senderKey: senderKey, packed: packed
            )
        }
    }

    func handleAnnounce(destHash: Data, displayName: String?) {
        let bridge = self
        Task { @MainActor in
            bridge.announceCallback?.onAnnounce(destHash: destHash, displayName: displayName)
        }
    }

    func handleMessageState(hash: Data, state: UInt8) {
        let bridge = self
        Task { @MainActor in
            bridge.messageStateCallback?.onMessageState(hash: hash, state: state)
        }
    }

    func handleRfedBlob(_ blob: Data) {
        rfedBlobCallback?.onRfedBlob(blob)
    }
}

// MARK: - C callback trampolines

/// Called from Rust on a background thread when a message is delivered.
private func deliveryTrampoline(
    context: UnsafeMutableRawPointer?,
    hash: UnsafePointer<UInt8>?, hashLen: UInt32,
    srcHash: UnsafePointer<UInt8>?, srcLen: UInt32,
    destHash: UnsafePointer<UInt8>?, destLen: UInt32,
    title: UnsafePointer<CChar>?,
    content: UnsafePointer<CChar>?,
    timestamp: Double,
    signatureValid: Int32,
    unverifiedReason: Int32,
    fieldsRaw: UnsafePointer<UInt8>?, fieldsLen: UInt32,
    senderKey: UnsafePointer<UInt8>?, senderKeyLen: UInt32,
    packed: UnsafePointer<UInt8>?, packedLen: UInt32
) {
    guard let context = context else { return }
    let bridge = Unmanaged<RetichatBridge>.fromOpaque(context).takeUnretainedValue()

    let hashData = hash.map { Data(bytes: $0, count: Int(hashLen)) } ?? Data()
    let srcData = srcHash.map { Data(bytes: $0, count: Int(srcLen)) } ?? Data()
    let destData = destHash.map { Data(bytes: $0, count: Int(destLen)) } ?? Data()
    let titleStr = title.map { String(cString: $0) } ?? ""
    let contentStr = content.map { String(cString: $0) } ?? ""
    let fieldsData = fieldsRaw.map { Data(bytes: $0, count: Int(fieldsLen)) } ?? Data()
    let keyData = senderKey.flatMap { senderKeyLen > 0 ? Data(bytes: $0, count: Int(senderKeyLen)) : nil }
    let packedData = packed.flatMap { packedLen > 0 ? Data(bytes: $0, count: Int(packedLen)) : nil }

    bridge.handleDelivery(
        hash: hashData, srcHash: srcData, destHash: destData,
        title: titleStr, content: contentStr, timestamp: timestamp,
        signatureValid: signatureValid != 0, unverifiedReason: Int(unverifiedReason),
        fieldsRaw: fieldsData, senderKey: keyData, packed: packedData
    )
}

// MARK: - What a device owes its distro (RFed SPEC §17.12, §17.11)

// Mirrors Retichat-android RetichatBridge.kt: messageSetDistroChannelSync,
// messagePack, distroSeal, propagationBuildUpload, propagationBuildSealedUpload,
// propagationLink, propagationUpload and propagationLinkEventsRegister. The
// outbox itself is Services/DistroOutbox.swift;
// these are what it cannot make from Swift (rust/retichat-ffi distro_outbox.rs
// has the parts that need no stack). Nothing here sends on a timer or sends again.

/// What the library calls back with for an upload: held by the library from the
/// call on (a retain it releases through `propagationUploadRelease`), so the
/// sink lives as long as a proof or a loss can still be reported. The three
/// trampolines below are internal, not private, so that
/// tests/DistroChannelsFFITests.swift can call them as the library does.
nonisolated final class PropagationUploadSinkBox {
    let sink: UploadSink
    init(_ sink: UploadSink) { self.sink = sink }
}

/// retichat_upload_event_t: 1 the node proved the upload, 2 it was lost, 3 it never left the
/// device (a Resource whose first advertisement no interface could carry: DISTRO-SYNC-PROOF-DESIGN.md
/// §5.3(a)). Runs on a stack thread.
nonisolated func propagationUploadEvent(context: UnsafeMutableRawPointer?, event: Int32) {
    guard let context else { return }
    let box = Unmanaged<PropagationUploadSinkBox>.fromOpaque(context).takeUnretainedValue()
    switch event {
    case 1: box.sink.proved()
    case 2: box.sink.lost()
    case 3: box.sink.neverLeft()
    default: break
    }
}

/// retichat_upload_release_t: the library is done with the context.
nonisolated func propagationUploadRelease(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PropagationUploadSinkBox>.fromOpaque(context).release()
}

/// The one handler of `RetichatBridge.propagationLinkEventsRegister`, read on stack threads.
nonisolated private enum PropagationLinkEvents {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Data, UInt8, Data?) -> Void)?

    static func set(_ handler: ((Data, UInt8, Data?) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static func deliver(dest: Data, status: UInt8, linkId: Data?) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(dest, status, linkId)
    }
}

/// retichat_link_event_t. Runs on a stack thread and must not block.
nonisolated func propagationLinkEvent(
    context: UnsafeMutableRawPointer?,
    dest: UnsafePointer<UInt8>?, destLen: UInt32,
    status: UInt8,
    linkId: UnsafePointer<UInt8>?, linkIdLen: UInt32
) {
    guard let dest, destLen > 0 else { return }
    let id: Data? = (linkId != nil && linkIdLen > 0) ? Data(bytes: linkId!, count: Int(linkIdLen)) : nil
    PropagationLinkEvents.deliver(dest: Data(bytes: dest, count: Int(destLen)), status: status, linkId: id)
}

/// The one handler of `RetichatBridge.interfaceUpRegister`, read on stack threads.
nonisolated private enum InterfaceUpEvents {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((String) -> Void)?

    static func set(_ handler: ((String) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static func deliver(name: String) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(name)
    }
}

/// retichat_interface_up_t: a Reticulum interface came online. Runs on a thread of the
/// stack's own and must not block.
nonisolated func interfaceUpEvent(context: UnsafeMutableRawPointer?, name: UnsafePointer<UInt8>?, nameLen: UInt32) {
    guard let name, nameLen > 0 else { return }
    InterfaceUpEvents.deliver(name: String(decoding: UnsafeBufferPointer(start: name, count: Int(nameLen)), as: UTF8.self))
}

extension RetichatBridge {

    /// `LinkHandle::status()`, as `propagationLink` reports it.
    nonisolated enum LinkState {
        static let pending: UInt8 = 0
        static let handshake: UInt8 = 1
        static let active: UInt8 = 2
        static let stale: UInt8 = 3
        static let closed: UInt8 = 4
    }

    /// The link AppLinks holds for the propagation node: its id (hex) and `LinkState`.
    nonisolated struct PropagationLink: Equatable, Sendable {
        let id: String
        let state: UInt8
        var active: Bool { state == RetichatBridge.LinkState.active }
    }

    /// An upload that left: how (a packet or a Resource) and the link (hex) it went on.
    nonisolated struct PropagationUploadStart: Equatable, Sendable {
        let resource: Bool
        let linkId: String
    }

    /// An AppLinks status of an app-link: ACTIVE, with the link's id for a new link.
    nonisolated static let appLinkActive: UInt8 = 3

    /// An AppLinks EVENT, never a state (`APP_LINK_RECOVERED`): the persistent link
    /// held for the destination had gone STALE and heard from its peer again, so it
    /// is ACTIVE once more. Told once per recovery, with the link's id, and only for
    /// the link AppLinks still holds. A handler that acts on ACTIVE alone ignores it.
    nonisolated static let appLinkRecovered: UInt8 = 5

    /// Write the membership message C's fields on an outbound message
    /// (`messageCreate`): 0x0C an empty bin, 0xFB `rfed.distro.channel`, 0xFC the
    /// native array `[op, name, at_ms]`, 0xFD `deviceHex`. False with the error
    /// slot set when `op` is not join or leave, `name` is empty, `atMs` is not
    /// 0..2^53-1 or `deviceHex` is not 32 hex.
    nonisolated func messageSetDistroChannelSync(handle: UInt64, op: String, name: String, atMs: Int64,
                                                 deviceHex: String) -> Bool {
        op.withCString { cOp in
            name.withCString { cName in
                deviceHex.withCString { cDevice in
                    retichat_message_set_distro_channel_sync(handle, cOp, cName, atMs, cDevice) == 0
                }
            }
        }
    }

    /// Write the group sync G's fields on an outbound message from D to D
    /// (`messageCreate`; RFed SPEC §17.14): 0x0C an empty bin, 0xFB
    /// `rfed.distro.group`, 0xFC the op's native array, 0xFD `deviceHex`.
    /// `syncJson` is the unwrap's `group_sync` object without `by` and
    /// `problem` (`op`, `group_id`, `at_ms`, `left`; `name`, `members`, `keys`
    /// for create and accept; `creator` for accept; `text` for post). `dHex` is
    /// D's `lxmf.delivery` address. False with the error slot set, and the
    /// message unchanged, when the JSON does not parse or a receiver's form
    /// check would drop it (LXMF-rust `distro::set_group_sync_fields`).
    nonisolated func messageSetDistroGroupSync(handle: UInt64, syncJson: String, dHex: String,
                                               deviceHex: String) -> Bool {
        syncJson.withCString { cJson in
            dHex.withCString { cD in
                deviceHex.withCString { cDevice in
                    retichat_message_set_distro_group_sync(handle, cJson, cD, cDevice) == 0
                }
            }
        }
    }

    /// Pack and sign an outbound message once and return its LXMF bytes
    /// (`dest | src | signature | payload`); `DistroMessageFFI.hash` is then its
    /// hash. What the outbox keeps: never packed again, so every upload is one message.
    nonisolated func messagePack(handle: UInt64) -> Data? {
        var outLen: UInt32 = 0
        guard let ptr = retichat_message_pack(handle, &outLen) else { return nil }
        defer { rns_free_bytes(ptr, outLen) }
        return Data(bytes: ptr, count: Int(outLen))
    }

    /// A message sealed for the distro sync proof (RFed SPEC §17.13): `sealed`
    /// (`D_hash | D.encrypt(packed[16..])`) and `syncSig`, D's signature over it.
    nonisolated struct DistroSealed: Equatable, Sendable {
        let sealed: Data
        let syncSig: Data
    }

    /// Seal the packed message `packed` (`messagePack`, from the distro to the distro)
    /// once, when the outbox owes it (DISTRO-SYNC-PROOF-DESIGN.md §5.1): encrypted to the
    /// distro whose identity `distroHandle` holds, and signed with its key. The outbox
    /// stores both with the entry, and every upload of it carries the same sealed bytes.
    /// Nil with the error slot set when it cannot be sealed (no private key, a message
    /// not addressed to the distro): the entry is then owed without them and built the
    /// legacy way. Local CPU work: never on the main thread.
    nonisolated func distroSeal(distroHandle: UInt64, packed: Data) -> DistroSealed? {
        var outLen: UInt32 = 0
        let ptr = packed.withUnsafeBytes { buf in
            retichat_distro_seal(distroHandle, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(packed.count), &outLen)
        }
        guard let ptr else { return nil }
        defer { rns_free_bytes(ptr, outLen) }
        let raw = Data(bytes: ptr, count: Int(outLen))
        guard raw.count > 64 + 16 else { return nil }
        return DistroSealed(sealed: Data(raw.dropFirst(64)), syncSig: Data(raw.prefix(64)))
    }

    /// The propagation upload of a sealed entry for the node `node`: `sealed` exactly as
    /// stored, never encrypted again, stamped for the node's cost, with the distro sync
    /// proof `[id, distroPublicKey, syncSig]` only when `withClaim` (the gate: `node` is
    /// the configured RFed's own lxmf.propagation, `UploadBuild.of`). BLOCKS while the
    /// stamp is mined: never on the main thread. Nil with the error slot set when it
    /// cannot be built (the node's cost is not known: its path is requested); nothing
    /// has left.
    nonisolated func propagationBuildSealedUpload(distroPublicKey: Data, sealed: Data, syncSig: Data,
                                                  withClaim: Bool, node: Data) -> Data? {
        var outLen: UInt32 = 0
        let ptr = distroPublicKey.withUnsafeBytes { key in
            sealed.withUnsafeBytes { sealedBuf in
                syncSig.withUnsafeBytes { sigBuf in
                    node.withUnsafeBytes { nodeBuf in
                        retichat_propagation_build_sealed_upload(
                            key.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(distroPublicKey.count),
                            sealedBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(sealed.count),
                            sigBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(syncSig.count),
                            withClaim ? 1 : 0,
                            nodeBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(node.count),
                            &outLen)
                    }
                }
            }
        }
        guard let ptr else { return nil }
        defer { rns_free_bytes(ptr, outLen) }
        return Data(bytes: ptr, count: Int(outLen))
    }

    /// The propagation upload of the packed message `packed` for the node `node`:
    /// encrypted to `distroPublicKey` and to no other key, stamped for the node's
    /// cost. BLOCKS while the stamp is mined: never on the main thread. Nil with
    /// the error slot set when it cannot be built; nothing has left. The legacy
    /// build, for an entry owed before entries were sealed.
    nonisolated func propagationBuildUpload(distroPublicKey: Data, packed: Data, node: Data) -> Data? {
        var outLen: UInt32 = 0
        let ptr = distroPublicKey.withUnsafeBytes { key in
            packed.withUnsafeBytes { packedBuf in
                node.withUnsafeBytes { nodeBuf in
                    retichat_propagation_build_upload(
                        key.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(distroPublicKey.count),
                        packedBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(packed.count),
                        nodeBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(node.count),
                        &outLen)
                }
            }
        }
        guard let ptr else { return nil }
        defer { rns_free_bytes(ptr, outLen) }
        return Data(bytes: ptr, count: Int(outLen))
    }

    /// The link held for `node` as it is now, or nil when none is held. A read, never a wait.
    nonisolated func propagationLink(node: Data) -> PropagationLink? {
        var outLen: UInt32 = 0
        let ptr = node.withUnsafeBytes { buf in
            retichat_propagation_link(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(node.count), &outLen)
        }
        guard let ptr else { return nil }
        defer { rns_free_bytes(ptr, outLen) }
        let raw = Data(bytes: ptr, count: Int(outLen))
        guard raw.count >= 2 else { return nil }
        return PropagationLink(id: raw.dropFirst().hexString, state: raw[raw.startIndex])
    }

    /// Hand `upload` (`propagationBuildUpload` or `propagationBuildSealedUpload`) to the
    /// ACTIVE link held for `node`. Nil with the error slot set when it did not leave
    /// (no active link held, or it could not be queued): `sink` is then never called.
    /// Once handed over, `sink` hears the node's proof or the loss, each at most once
    /// and from a stack thread, and on a loss the link the upload went on has already
    /// been torn down (the receipt's timeout, as LXMF does). A Resource whose first
    /// advertisement no interface could carry is heard as `neverLeft` instead, with no
    /// teardown (DISTRO-SYNC-PROOF-DESIGN.md §5.3(a)). Take `interfaceUpMark()` just
    /// before this call. Nothing here resends or times anything; a Resource's progress
    /// feeds the stack's §1 silence watch, which only logs.
    nonisolated func propagationUpload(node: Data, upload: Data, sink: UploadSink) -> PropagationUploadStart? {
        // The library owns this retain from the call on and releases it once.
        let context = Unmanaged.passRetained(PropagationUploadSinkBox(sink)).toOpaque()
        var outLen: UInt32 = 0
        let ptr = node.withUnsafeBytes { nodeBuf in
            upload.withUnsafeBytes { uploadBuf in
                retichat_propagation_upload(
                    nodeBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(node.count),
                    uploadBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(upload.count),
                    propagationUploadEvent, propagationUploadRelease, context, &outLen)
            }
        }
        guard let ptr else { return nil }
        defer { rns_free_bytes(ptr, outLen) }
        let raw = Data(bytes: ptr, count: Int(outLen))
        guard raw.count >= 2 else { return nil }
        return PropagationUploadStart(resource: raw[raw.startIndex] == 2, linkId: raw.dropFirst().hexString)
    }

    /// Register `handler` for every app-link status change, with the link each is
    /// about (a new link's establishment is its ACTIVE event, and a STALE link's
    /// recovery its RECOVERED event, each carrying the link's id). Runs on a stack
    /// thread and must not block. The stack's shutdown drops it: register again
    /// after each start.
    nonisolated func propagationLinkEventsRegister(handler: @escaping (Data, UInt8, Data?) -> Void) -> Bool {
        PropagationLinkEvents.set(handler)
        let ok = retichat_propagation_link_events_register(propagationLinkEvent, nil) == 0
        if !ok { PropagationLinkEvents.set(nil) }
        return ok
    }

    /// Forget the handler (the stack is stopping): a status change after this reaches nobody.
    nonisolated func propagationLinkEventsClear() {
        PropagationLinkEvents.set(nil)
    }

    /// Register `handler` for each Reticulum interface that comes online, with its name: the
    /// stack's own up-edge (`Transport::set_interface_online`), never the system saying the
    /// network is available (James, 2026-10-06: an owed distro upload that never left the
    /// device goes then, DESIGN_PRINCIPLES §3, what a device owes its distro). Runs on a
    /// thread of the stack's own and must not block. The stack's listener lives for the
    /// process, so this is cleared when the stack stops (`interfaceUpClear`) and registered
    /// again at each start.
    nonisolated func interfaceUpRegister(handler: @escaping (String) -> Void) -> Bool {
        InterfaceUpEvents.set(handler)
        let ok = retichat_interface_up_register(interfaceUpEvent, nil) == 0
        if !ok { InterfaceUpEvents.set(nil) }
        return ok
    }

    /// Forget the handler (the stack is stopping): an interface that comes online after this reaches nobody.
    nonisolated func interfaceUpClear() {
        InterfaceUpEvents.set(nil)
        retichat_interface_up_clear()
    }

    /// AppLinks' `UpEdgeMark::now()`: how many Reticulum interface up-edges there have been.
    /// The outbox takes it just before each upload (`PropagationPort.upEdgeMark`).
    nonisolated func interfaceUpMark() -> UInt64 {
        retichat_interface_up_mark()
    }

    /// AppLinks' `UpEdgeMark::came_up_since`: whether an interface has come up since
    /// `mark`. Asked only once an upload that never left is recorded as owed: true means
    /// the up-edge it waits for came meanwhile, and it goes at once.
    nonisolated func interfaceCameUpSince(_ mark: UInt64) -> Bool {
        retichat_interface_came_up_since(mark) == 1
    }

    // MARK: Member statuses and keys (RFed-spec Group.md, 2026-10-06)

    /// An element of a `status`, or an entry held for its sender's key (a member's own packed
    /// accept or leave, 97..=2144 bytes), unpacked and checked as if it had arrived directly: what
    /// its signature is worth under the key held for its source, else under the key it carries
    /// for its own sender when that binds. Nothing is remembered. `refused` when the library
    /// refused it whole because its payload repeats a key, has a key Python cannot hash or is
    /// nested past depth 493 (RFed SPEC §17.14 "Repeated keys", "Unhashable keys", "Nesting";
    /// LXMF-rust has logged that line, and `RepeatedKeys.isRefusal` knows its error), `notLxmf`
    /// when it is not an LXMF message of that size; as Retichat-android's `groupUnpackPacked`.
    nonisolated func groupUnpack(_ packed: Data) -> GroupUnpack {
        guard let buffer = groupUnpackBuffer(packed) else {
            // Read on this thread, at once: the Rust error slot is thread-local, and this call set it.
            return RepeatedKeys.isRefusal(rnsLastError()) ? .refused : .notLxmf
        }
        return UnpackedGroupMessage.parse(buffer).map(GroupUnpack.unpacked) ?? .notLxmf
    }

    /// The buffer `retichat_group_unpack_packed` returns for `packed`, or nil with the error slot set.
    private nonisolated func groupUnpackBuffer(_ packed: Data) -> Data? {
        var outLen: UInt32 = 0
        let ptr = packed.withUnsafeBytes { buf in
            retichat_group_unpack_packed(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(packed.count), &outLen)
        }
        guard let ptr else { return nil }
        defer { rns_free_bytes(ptr, outLen) }
        return Data(bytes: ptr, count: Int(outLen))
    }

    /// Write key 10 (GROUP_STATUSES) on an outbound message: a native array of bin in the
    /// Retichat field, in both forms (it has no old field), `elements` being the members' own
    /// packed accepts and leaves exactly as the creator received them. An empty list is a valid
    /// answer. False, with the error slot set and the message unchanged, for an element no
    /// receiver would read.
    nonisolated func messageSetRetichatStatuses(handle: UInt64, elements: [Data]) -> Bool {
        var flat = Data()
        func put(_ n: Int) { withUnsafeBytes(of: UInt32(n).bigEndian) { flat.append(contentsOf: $0) } }
        put(elements.count)
        for element in elements {
            put(element.count)
            flat.append(element)
        }
        return flat.withUnsafeBytes { buf in
            retichat_message_set_retichat_statuses(handle, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(flat.count)) == 0
        }
    }
}

/// The group follow-up's native layer (GroupNative) over the glue crate: an element of a
/// `status`, or an entry held for its key, checked as if it had arrived directly, and a
/// member's key remembered the way an invite chunk's is.
@MainActor
final class FFIGroupNative: GroupNative {
    private let bridge: RetichatBridge

    init(bridge: RetichatBridge) { self.bridge = bridge }

    func unpack(_ packed: Data) -> GroupUnpack { bridge.groupUnpack(packed) }

    /// Remembered only when the key produces `memberHex` as an `lxmf.delivery` destination
    /// (`retichat_identity_remember_lxmf_delivery` checks it).
    func rememberKey(memberHex: String, publicKey: Data) -> Bool {
        guard let hash = Data(hexString: memberHex), hash.count == 16, publicKey.count == 64 else { return false }
        return bridge.rememberLxmfDelivery(destHash: hash, publicKey: publicKey)
    }
}

/// Called from Rust on a background thread when an announce is received.
private func announceTrampoline(
    context: UnsafeMutableRawPointer?,
    destHash: UnsafePointer<UInt8>?, destLen: UInt32,
    displayName: UnsafePointer<CChar>?
) {
    guard let context = context else { return }
    let bridge = Unmanaged<RetichatBridge>.fromOpaque(context).takeUnretainedValue()

    let hashData = destHash.map { Data(bytes: $0, count: Int(destLen)) } ?? Data()
    let nameStr = displayName.map { String(cString: $0) }

    bridge.handleAnnounce(destHash: hashData, displayName: nameStr)
}

/// Called from Rust on a background thread when an outbound message changes state.
private func messageStateTrampoline(
    context: UnsafeMutableRawPointer?,
    msgHash: UnsafePointer<UInt8>?, hashLen: UInt32,
    state: UInt8
) {
    guard let context = context else { return }
    let bridge = Unmanaged<RetichatBridge>.fromOpaque(context).takeUnretainedValue()

    let hashData = msgHash.map { Data(bytes: $0, count: Int(hashLen)) } ?? Data()
    bridge.handleMessageState(hash: hashData, state: state)
}

/// Called from Rust on a background thread when a blob arrives on the local
/// legacy `rfed.delivery` endpoint.
private func rfedBlobTrampoline(
    context: UnsafeMutableRawPointer?,
    blob: UnsafePointer<UInt8>?, blobLen: UInt32
) {
    guard let context = context else { return }
    let bridge = Unmanaged<RetichatBridge>.fromOpaque(context).takeUnretainedValue()

    let blobData = blob.map { Data(bytes: $0, count: Int(blobLen)) } ?? Data()
    bridge.handleRfedBlob(blobData)
}

