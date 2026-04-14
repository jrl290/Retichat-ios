//
//  LxmfClient.swift
//  Retichat
//
//  High-level LXMF client.  Wraps the universal `lxmf_*` C FFI so every
//  consumer (main app, NSE, future targets) gets the full protocol stack
//  in one call — no knowledge of ratchets, signing, hashes, or proofs.
//
//  Usage:
//
//      let client = try LxmfClient.start(config: ...)
//      client.setDeliveryCallback(myTrampoline)
//      client.sync(nodeHash: someData)
//      ...
//      client.shutdown()
//

import Foundation

// MARK: - Configuration

struct LxmfClientConfig: Sendable {
    /// Path to the Reticulum config directory (contains `config` file).
    let configDir: String

    /// Path to the LXMF storage directory.
    let storagePath: String

    /// Path to the identity file.
    let identityPath: String

    /// Create a new identity if the file doesn't exist.
    let createIdentity: Bool

    /// Display name announced on the network (empty = anonymous).
    let displayName: String

    /// Log level (0–7, or -1 for default).
    let logLevel: Int32

    /// Stamp cost for the delivery endpoint (-1 = none).
    let stampCost: Int32
}

// MARK: - LxmfClient

/// Manages a complete Reticulum + LXMF stack lifecycle through one opaque
/// handle.  All protocol internals are hidden behind the Rust `lxmf_*` FFI.
final class LxmfClient: @unchecked Sendable {

    /// Opaque handle returned by `lxmf_client_start`.
    let handle: UInt64

    /// Cached 16-byte identity hash.
    let identityHash: Data

    /// Cached 16-byte LXMF delivery destination hash.
    let destHash: Data

    /// The underlying identity handle for use with transport-level functions.
    var identityHandle: UInt64 {
        lxmf_client_identity_handle(handle)
    }

    private init(handle: UInt64, identityHash: Data, destHash: Data) {
        self.handle = handle
        self.identityHash = identityHash
        self.destHash = destHash
    }

    /// Start the full LXMF stack: transport, identity, router, ratchets.
    ///
    /// After this returns the network interfaces are connecting and the
    /// router is ready to receive messages once callbacks are wired.
    static func start(config: LxmfClientConfig) throws -> LxmfClient {
        let h = config.configDir.withCString { dir in
            config.storagePath.withCString { store in
                config.identityPath.withCString { id in
                    config.displayName.withCString { name in
                        lxmf_client_start(
                            dir, store, id,
                            config.createIdentity ? 1 : 0,
                            name,
                            config.logLevel,
                            config.stampCost
                        )
                    }
                }
            }
        }
        guard h != 0 else {
            throw LxmfClientError.startFailed(fetchLastError())
        }

        // Cache hashes so callers never need to think about them.
        var idBuf = [UInt8](repeating: 0, count: 32)
        let idLen = lxmf_client_identity_hash(h, &idBuf, 32)
        guard idLen > 0 else {
            lxmf_client_shutdown(h)
            throw LxmfClientError.startFailed("failed to get identity hash")
        }

        var destBuf = [UInt8](repeating: 0, count: 32)
        let destLen = lxmf_client_dest_hash(h, &destBuf, 32)
        guard destLen > 0 else {
            lxmf_client_shutdown(h)
            throw LxmfClientError.startFailed("failed to get dest hash")
        }

        return LxmfClient(
            handle: h,
            identityHash: Data(idBuf[0..<Int(idLen)]),
            destHash: Data(destBuf[0..<Int(destLen)])
        )
    }

    // MARK: - Callbacks

    /// Set the delivery callback (fires on a background thread).
    @discardableResult
    func setDeliveryCallback(
        _ callback: lxmf_delivery_callback_t,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        lxmf_client_set_delivery_callback(handle, callback, context) == 0
    }

    /// Set the announce callback.
    @discardableResult
    func setAnnounceCallback(
        _ callback: lxmf_announce_callback_t,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        lxmf_client_set_announce_callback(handle, callback, context) == 0
    }

    /// Set the sync-complete callback.
    @discardableResult
    func setSyncCompleteCallback(
        _ callback: lxmf_sync_complete_callback_t,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        lxmf_client_set_sync_complete_callback(handle, callback, context) == 0
    }

    /// Set the message-state callback.  Fires when an outbound message changes
    /// delivery state: SENT (0x04), DELIVERED (0x08), REJECTED (0xFD),
    /// CANCELLED (0xFE), FAILED (0xFF).
    @discardableResult
    func setMessageStateCallback(
        _ callback: lxmf_message_state_callback_t,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        lxmf_client_set_message_state_callback(handle, callback, context) == 0
    }

    // MARK: - Propagation

    /// Set a propagation node and request messages.
    @discardableResult
    func sync(nodeHash: Data) -> Bool {
        nodeHash.withUnsafeBytes { buf -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_client_sync(handle, p, UInt32(nodeHash.count)) == 0
        }
    }

    /// Current propagation transfer state byte.
    var propagationState: Int32 {
        lxmf_client_propagation_state(handle)
    }

    /// Current propagation transfer progress (0.0–1.0).
    var propagationProgress: Float {
        lxmf_client_propagation_progress(handle)
    }

    // MARK: - Peer link management

    /// Returns the current direct-link status: 0=none, 1=pending, 2=active.
    func peerLinkStatus(_ destHash: Data) -> Int32 {
        destHash.withUnsafeBytes { buf -> Int32 in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_peer_link_status(handle, p, UInt32(destHash.count))
        }
    }

    // MARK: - Announce

    /// Announce this client's delivery destination.
    @discardableResult
    func announce() -> Bool {
        lxmf_client_announce(handle) == 0
    }

    /// Watch for announces from a destination hash.
    @discardableResult
    func watch(destHash: Data) -> Bool {
        return destHash.withUnsafeBytes { buf -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_client_watch(handle, p, UInt32(destHash.count)) == 0
        }
    }

    // MARK: - Send messages

    /// Create + send a simple text message.
    ///
    /// Returns the message handle for state tracking, or 0 on failure.
    func send(
        to destHash: Data,
        content: String,
        title: String = "",
        method: UInt8 = 0x02  // direct
    ) -> UInt64 {
        let msgH = destHash.withUnsafeBytes { buf -> UInt64 in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return content.withCString { cContent in
                title.withCString { cTitle in
                    lxmf_message_new(handle, p, UInt32(destHash.count),
                                     cContent, cTitle, method)
                }
            }
        }
        guard msgH != 0 else { return 0 }

        if lxmf_message_send(handle, msgH) != 0 {
            lxmf_message_destroy(msgH)
            return 0
        }
        return msgH
    }

    /// Create a message for further decoration (fields, attachments)
    /// before sending with `sendMessage(_:)`.
    func createMessage(
        to destHash: Data,
        content: String,
        title: String = "",
        method: UInt8 = 0x02
    ) -> UInt64 {
        destHash.withUnsafeBytes { buf -> UInt64 in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return content.withCString { cContent in
                title.withCString { cTitle in
                    lxmf_message_new(handle, p, UInt32(destHash.count),
                                     cContent, cTitle, method)
                }
            }
        }
    }

    /// Submit a previously created message for delivery.
    @discardableResult
    func sendMessage(_ msgHandle: UInt64) -> Bool {
        lxmf_message_send(handle, msgHandle) == 0
    }

    // MARK: - Message tracking

    /// Get message delivery state.
    static func messageState(_ msgHandle: UInt64) -> Int32 {
        lxmf_message_state(msgHandle)
    }

    /// Get message transfer progress (0.0–1.0).
    static func messageProgress(_ msgHandle: UInt64) -> Float {
        lxmf_message_progress(msgHandle)
    }

    /// Get message hash.
    static func messageHash(_ msgHandle: UInt64) -> Data? {
        var buf = [UInt8](repeating: 0, count: 32)
        let len = lxmf_message_hash(msgHandle, &buf, 32)
        guard len > 0 else { return nil }
        return Data(buf[0..<Int(len)])
    }

    /// Destroy a message handle.
    static func messageDestroy(_ msgHandle: UInt64) {
        lxmf_message_destroy(msgHandle)
    }

    // MARK: - Utility

    /// Process outbound message queue (retries, link management).
    @discardableResult
    func processOutbound() -> Bool {
        lxmf_client_process_outbound(handle) == 0
    }

    /// Persist path table and cached data to disk.
    func persist() {
        lxmf_client_persist(handle)
    }

    /// Shut down: destroy router, identity, and transport.
    func shutdown() {
        lxmf_client_shutdown(handle)
    }

    // MARK: - Helpers

    /// Hex string of the identity hash (first 8 chars).
    var identityHashShort: String {
        identityHash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Hex string of the full identity hash.
    var identityHashHex: String {
        identityHash.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex string of the full destination hash.
    var destHashHex: String {
        destHash.map { String(format: "%02x", $0) }.joined()
    }

    /// Look up the cached display name for a destination hash (from its last announce).
    /// Returns nil if no name is known.
    func recallDisplayName(for destHash: Data) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let written = destHash.withUnsafeBytes { hashBuf -> Int32 in
            let p = hashBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_client_recall_display_name(handle, p, UInt32(destHash.count), &buf, 256)
        }
        guard written > 1 else { return nil }  // >1 because 1 would be just a NUL
        return String(cString: buf)
    }

    private static func fetchLastError() -> String {
        guard let ptr = lxmf_last_error() else { return "unknown" }
        let str = String(cString: ptr)
        lxmf_free_string(ptr)
        return str
    }

    /// Public access to the last error string (nil if empty).
    static var lastError: String? {
        let msg = fetchLastError()
        return msg == "unknown" || msg.isEmpty ? nil : msg
    }
}

// MARK: - Message field helpers (static, no client needed)

extension LxmfClient {

    /// Add a string field to an outbound message.
    @discardableResult
    static func messageAddField(_ msgHandle: UInt64, key: UInt8, value: String) -> Bool {
        value.withCString { lxmf_message_add_field(msgHandle, key, $0) == 0 }
    }

    /// Add a boolean field to an outbound message.
    @discardableResult
    static func messageAddFieldBool(_ msgHandle: UInt64, key: UInt8, value: Bool) -> Bool {
        lxmf_message_add_field_bool(msgHandle, key, value ? 1 : 0) == 0
    }

    /// Add a file attachment to an outbound message.
    @discardableResult
    static func messageAddAttachment(_ msgHandle: UInt64, filename: String, data: Data) -> Bool {
        filename.withCString { cName in
            data.withUnsafeBytes { buf -> Bool in
                let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return lxmf_message_add_attachment(msgHandle, cName, p, UInt32(data.count)) == 0
            }
        }
    }
}

// MARK: - Errors

enum LxmfClientError: Error, LocalizedError {
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .startFailed(let msg): return "LXMF client start failed: \(msg)"
        }
    }
}
