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

protocol MessageCallback: AnyObject {
    @MainActor func onMessage(hash: Data, srcHash: Data, destHash: Data,
                              title: String, content: String, timestamp: Double,
                              signatureValid: Bool, fieldsRaw: Data)
}

protocol AnnounceCallback: AnyObject {
    @MainActor func onAnnounce(destHash: Data, displayName: String?)
}

/// Receives outbound message state transitions from Rust.
/// Fired at: SENT (0x04), DELIVERED (0x08), REJECTED (0xFD), CANCELLED (0xFE), FAILED (0xFF).
protocol MessageStateCallback: AnyObject {
    @MainActor func onMessageState(hash: Data, state: UInt8)
}

/// Receives raw inner blobs arriving at the local rfed.delivery destination.
/// Called on a background thread — implementations must dispatch to main thread if needed.
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
    private weak var rfedBlobCallback: (any RfedBlobCallback)?

    private init() {}

    // MARK: - Callback wiring

    /// Wire LxmfClient callbacks through this bridge's dispatch mechanism.
    func wireCallbacks(to client: LxmfClient, messageCallback: MessageCallback, announceCallback: AnnounceCallback?, messageStateCallback: (any MessageStateCallback)? = nil) {
        self.messageCallback = messageCallback
        self.announceCallback = announceCallback
        self.messageStateCallback = messageStateCallback
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        client.setDeliveryCallback(deliveryTrampoline, context: ctx)
        if announceCallback != nil {
            client.setAnnounceCallback(announceTrampoline, context: ctx)
        }
        client.setMessageStateCallback(messageStateTrampoline, context: ctx)
    }

    // MARK: - Last error

    func lastError() -> String? {
        guard let ptr = lxmf_last_error() else { return nil }
        let str = String(cString: ptr)
        lxmf_free_string(ptr)
        return str
    }

    // MARK: - Transport

    nonisolated func transportHasPath(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_has_path(ptr, UInt32(destHash.count)) == 1
        }
    }

    nonisolated func transportRequestPath(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_request_path(ptr, UInt32(destHash.count)) == 0
        }
    }

    nonisolated func transportHopsTo(destHash: Data) -> Int32 {
        return destHash.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return retichat_transport_hops_to(ptr, UInt32(destHash.count))
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

    func packetSendToHash(destHash: Data, appName: String, aspects: String,
                          payload: Data) -> Bool {
        return destHash.withUnsafeBytes { hashBuf in
            payload.withUnsafeBytes { payBuf in
                appName.withCString { cApp in
                    aspects.withCString { cAsp in
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

    /// Encrypt `plaintext` for the named channel. Channel keypair is derived deterministically
    /// from the channel name — any subscriber holding the name can encrypt and decrypt.
    nonisolated func channelEncrypt(name: String, plaintext: Data) -> Data? {
        var outLen: UInt32 = 0
        guard let ptr = name.withCString({ cName in
            plaintext.withUnsafeBytes { buf in
                retichat_channel_encrypt(
                    cName,
                    buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt32(plaintext.count),
                    &outLen
                )
            }
        }) else { return nil }
        let data = Data(bytes: ptr, count: Int(outLen))
        lxmf_free_bytes(ptr, outLen)
        return data
    }

    /// Decrypt a channel ciphertext. Returns nil if decryption fails (wrong channel name or corrupt data).
    nonisolated func channelDecrypt(name: String, ciphertext: Data) -> Data? {
        var outLen: UInt32 = 0
        guard let ptr = name.withCString({ cName in
            ciphertext.withUnsafeBytes { buf in
                retichat_channel_decrypt(
                    cName,
                    buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt32(ciphertext.count),
                    &outLen
                )
            }
        }) else { return nil }
        let data = Data(bytes: ptr, count: Int(outLen))
        lxmf_free_bytes(ptr, outLen)
        return data
    }

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

    // MARK: - Link request

    nonisolated func linkRequest(destHash: Data, appName: String, aspects: String,
                     identityHandle: UInt64, path: String,
                     payload: Data, timeoutSecs: Double = 15.0) -> Data? {
        return destHash.withUnsafeBytes { hashBuf in
            payload.withUnsafeBytes { payBuf in
                appName.withCString { cApp in
                    aspects.withCString { cAsp in
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

    // MARK: - RFed Delivery

    /// Start the local rfed.delivery inbound endpoint.
    /// `callback` fires on a background thread whenever a blob arrives.
    @discardableResult
    func startRfedDelivery(identityHandle: UInt64, callback: any RfedBlobCallback) -> Bool {
        self.rfedBlobCallback = callback
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        return retichat_rfed_delivery_start(identityHandle, rfedBlobTrampoline, ctx) == 0
    }

    /// Announce the local rfed.delivery destination to trigger flush of deferred blobs.
    @discardableResult
    func rfedDeliveryAnnounce() -> Bool {
        return retichat_rfed_delivery_announce() == 0
    }

    /// Stop the rfed.delivery endpoint.
    func stopRfedDelivery() {
        _ = retichat_rfed_delivery_stop()
        rfedBlobCallback = nil
    }

    // MARK: - Internal callback dispatch

    func handleDelivery(hash: Data, srcHash: Data, destHash: Data,
                        title: String, content: String, timestamp: Double,
                        signatureValid: Bool, fieldsRaw: Data) {
        // Single hop: schedule directly on the main actor (no intermediate GCD dispatch).
        let bridge = self
        Task { @MainActor in
            guard let cb = bridge.messageCallback else {
                print("[RetichatBridge] handleDelivery: DROPPED - messageCallback is nil (ChatRepository deallocated?)")
                return
            }
            cb.onMessage(
                hash: hash, srcHash: srcHash, destHash: destHash,
                title: title, content: content, timestamp: timestamp,
                signatureValid: signatureValid, fieldsRaw: fieldsRaw
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
    fieldsRaw: UnsafePointer<UInt8>?, fieldsLen: UInt32
) {
    guard let context = context else { return }
    let bridge = Unmanaged<RetichatBridge>.fromOpaque(context).takeUnretainedValue()

    let hashData = hash.map { Data(bytes: $0, count: Int(hashLen)) } ?? Data()
    let srcData = srcHash.map { Data(bytes: $0, count: Int(srcLen)) } ?? Data()
    let destData = destHash.map { Data(bytes: $0, count: Int(destLen)) } ?? Data()
    let titleStr = title.map { String(cString: $0) } ?? ""
    let contentStr = content.map { String(cString: $0) } ?? ""
    let fieldsData = fieldsRaw.map { Data(bytes: $0, count: Int(fieldsLen)) } ?? Data()

    bridge.handleDelivery(
        hash: hashData, srcHash: srcData, destHash: destData,
        title: titleStr, content: contentStr, timestamp: timestamp,
        signatureValid: signatureValid != 0, fieldsRaw: fieldsData
    )
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

/// Called from Rust on a background thread when a blob arrives at rfed.delivery.
private func rfedBlobTrampoline(
    data: UnsafePointer<UInt8>?,
    len: UInt32,
    context: UnsafeMutableRawPointer?
) {
    guard let context = context, let data = data else { return }
    let bridge = Unmanaged<RetichatBridge>.fromOpaque(context).takeUnretainedValue()
    let blob = Data(bytes: data, count: Int(len))
    bridge.handleRfedBlob(blob)
}
