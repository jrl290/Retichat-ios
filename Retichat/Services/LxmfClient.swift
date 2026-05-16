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

/// Heap box for a `CheckedContinuation` so we can pass an opaque pointer
/// across the Rust FFI boundary and resume from a callback thread.
/// Used by `appLinkRequestAsync` (and any future async-callback FFI).
fileprivate final class ContinuationBox {
    let cont: CheckedContinuation<Data?, Never>
    init(cont: CheckedContinuation<Data?, Never>) { self.cont = cont }
}

/// Heap box for a Bool continuation used by fire-and-forget APP_LINK DATA
/// sends that still await Reticulum delivery proof.
fileprivate final class BoolContinuationBox {
    let cont: CheckedContinuation<Bool, Never>
    init(cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
}

/// Top-level C-compatible trampoline for `lxmf_app_link_request_async`.
/// Cannot be a `@_cdecl` func — Swift forbids forming a C function pointer
/// from such a func in property contexts. Closure form works.
fileprivate let _appLinkRequestTrampoline: lxmf_app_link_request_callback_t = {
    (ctx, bytesPtr, bytesLen, status) -> Void in
    guard let ctx = ctx else { return }
    let unbox = Unmanaged<ContinuationBox>.fromOpaque(ctx).takeRetainedValue()
    if status == 0, let p = bytesPtr, bytesLen > 0 {
        let data = Data(bytes: p, count: Int(bytesLen))
        unbox.cont.resume(returning: data)
    } else {
        unbox.cont.resume(returning: nil)
    }
}

/// Top-level trampoline for `lxmf_app_link_send_async`.
fileprivate let _appLinkSendTrampoline: lxmf_app_link_send_callback_t = {
    (ctx, status) -> Void in
    guard let ctx = ctx else { return }
    let unbox = Unmanaged<BoolContinuationBox>.fromOpaque(ctx).takeRetainedValue()
    unbox.cont.resume(returning: status == 0)
}

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

    nonisolated private init(handle: UInt64, identityHash: Data, destHash: Data) {
        self.handle = handle
        self.identityHash = identityHash
        self.destHash = destHash
    }

    /// Start the full LXMF stack: transport, identity, router, ratchets.
    ///
    /// After this returns the network interfaces are connecting and the
    /// router is ready to receive messages once callbacks are wired.
    nonisolated static func start(config: LxmfClientConfig) throws -> LxmfClient {
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

    // MARK: - App Links

    /// Open an app link for the given destination.  Internally watches the announce,
    /// requests a path, and establishes a direct link when the path arrives.
    /// The link is kept alive and exempt from inactivity cleanup.
    ///
    /// `app` and `aspects` describe the destination identity. Defaults match
    /// LXMF peer destinations; pass `app: "rfed", aspects: ["channel"]` for the
    /// rfed channel link, etc. Without the right tuple the router cannot
    /// resolve the destination on reconnect and the link will silently fail.
    @discardableResult
    nonisolated func appLinkOpen(_ destHash: Data,
                                 app: String = "lxmf",
                                 aspects: [String] = ["delivery"]) -> Bool {
        let aspectsCsv = aspects.joined(separator: ".")
        return destHash.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return app.withCString { (appC: UnsafePointer<CChar>) -> Bool in
                aspectsCsv.withCString { (aspC: UnsafePointer<CChar>) -> Bool in
                    lxmf_app_link_open(handle, p, UInt32(destHash.count), appC, aspC) == 0
                }
            }
        }
    }

    /// Open a persistent app link for the given destination.
    ///
    /// Same registration semantics as `appLinkOpen`, but once the path-race
    /// succeeds AppLinks holds the outbound link open so request-style
    /// traffic can reuse it directly.
    @discardableResult
    nonisolated func appLinkOpenPersistent(_ destHash: Data,
                                           app: String = "lxmf",
                                           aspects: [String] = ["delivery"]) -> Bool {
        let aspectsCsv = aspects.joined(separator: ".")
        return destHash.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return app.withCString { (appC: UnsafePointer<CChar>) -> Bool in
                aspectsCsv.withCString { (aspC: UnsafePointer<CChar>) -> Bool in
                    lxmf_app_link_open_persistent(handle, p, UInt32(destHash.count), appC, aspC) == 0
                }
            }
        }
    }

    /// Close an app link for the given destination and tear down the direct link.
    @discardableResult
    nonisolated func appLinkClose(_ destHash: Data) -> Bool {
        destHash.withUnsafeBytes { buf -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_app_link_close(handle, p, UInt32(destHash.count)) == 0
        }
    }

    /// Query the app link status for a destination.
    /// Returns: 0=NONE, 1=PATH_REQUESTED, 2=ESTABLISHING, 3=ACTIVE, 4=DISCONNECTED, -1=error.
    func appLinkStatus(_ destHash: Data) -> Int32 {
        destHash.withUnsafeBytes { buf -> Int32 in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_app_link_status(handle, p, UInt32(destHash.count))
        }
    }

    /// Trigger one explicit re-open cycle for an existing app link.
    @discardableResult
    nonisolated func appLinkReopen(_ destHash: Data) -> Bool {
        destHash.withUnsafeBytes { buf -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_app_link_reopen(handle, p, UInt32(destHash.count)) == 0
        }
    }

    /// Register an app-link reconnect handler for a non-LXMF destination aspect.
    ///
    /// Call once per extra aspect (e.g. `"rfed.channel"`, `"rfed.notify"`) during
    /// startup so the router reconnects app-links to those destinations on announce.
    @discardableResult
    nonisolated func appLinkRegisterReconnect(aspect: String) -> Bool {
        aspect.withCString { cAspect in
            lxmf_app_link_register_reconnect(handle, cAspect) == 0
        }
    }

    /// Register an APP_LINK status callback.  Fires whenever an APP_LINK
    /// transitions state.  `status` byte: 0=NONE, 1=PATH_REQUESTED,
    /// 2=ESTABLISHING, 3=ACTIVE, 4=DISCONNECTED.
    ///
    /// The callback runs on the link-actor thread and MUST NOT block —
    /// copy the destination hash and dispatch off-thread.
    @discardableResult
    nonisolated func setAppLinkStatusCallback(
        _ callback: lxmf_app_link_status_callback_t,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        lxmf_app_link_register_status_callback(handle, callback, context) == 0
    }

    /// Notify the router that the host's network reachability state has
    /// changed (interface up/down, Wi-Fi ↔ cellular, etc.).
    /// Triggers ONE fresh attempt for every registered app-link not currently
    /// active or establishing. The router does not retry on its own.
    @discardableResult
    nonisolated func appLinkNetworkChanged() -> Bool {
        lxmf_app_link_network_changed(handle) == 0
    }

    /// Send a blocking request on an existing app-link.
    ///
    /// Reuses an existing active app-link handle, typically one established
    /// by `appLinkOpenPersistent`, instead of opening a fresh outbound link
    /// per request.  The link must already be `ACTIVE` (status == 3); call
    /// `appLinkStatus` first.
    ///
    /// Blocking — must be called from a background thread.
    /// Returns response bytes, or `nil` on timeout / error / link not active.
    nonisolated func appLinkRequest(destHash: Data, path: String,
                                    payload: Data, timeoutSecs: Double) -> Data?
    {
        destHash.withUnsafeBytes { destBuf -> Data? in
            let destPtr = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return path.withCString { cPath -> Data? in
                payload.withUnsafeBytes { payBuf -> Data? in
                    let payPtr = payBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    var outLen: UInt32 = 0
                    let ptr = lxmf_app_link_request(
                        handle,
                        destPtr, UInt32(destHash.count),
                        cPath,
                        payPtr, UInt32(payload.count),
                        timeoutSecs,
                        &outLen
                    )
                    guard let raw = ptr, outLen > 0 else { return nil }
                    let result = Data(bytes: raw, count: Int(outLen))
                    lxmf_free_bytes(raw, outLen)
                    return result
                }
            }
        }
    }

    /// Async/awaitable variant of `appLinkRequest`.
    ///
    /// Bridges Rust's callback-based `lxmf_app_link_request_async` to
    /// Swift structured concurrency via `withCheckedContinuation`. The
    /// awaiting Task suspends without parking a cooperative-pool thread
    /// (the previous synchronous variant produced a User-initiated →
    /// Default-QoS priority inversion observed by the Thread Performance
    /// Checker — see DESIGN_PRINCIPLES.md §1).
    ///
    /// For outbound request flows, callers should `appLinkOpenPersistent`
    /// the destination and confirm `appLinkStatus(destHash) == 3` (ACTIVE)
    /// before calling.
    /// Returns response bytes, or `nil` on timeout / failure / error.
    nonisolated func appLinkRequestAsync(destHash: Data, path: String,
                                         payload: Data,
                                         timeoutSecs: Double) async -> Data?
    {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // The continuation must outlive this scope — the Rust side
            // delivers the callback from a background thread (response,
            // failed, or timeout) and we need to be able to resume from
            // there. Heap-box and pass the box pointer as the C context.
            let box = ContinuationBox(cont: cont)
            let ctxPtr = Unmanaged.passRetained(box).toOpaque()

            let rc: Int32 = destHash.withUnsafeBytes { destBuf -> Int32 in
                let destPtr = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return path.withCString { cPath -> Int32 in
                    return payload.withUnsafeBytes { payBuf -> Int32 in
                        let payPtr = payBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        return lxmf_app_link_request_async(
                            self.handle,
                            destPtr, UInt32(destHash.count),
                            cPath,
                            payPtr, UInt32(payload.count),
                            timeoutSecs,
                            _appLinkRequestTrampoline,
                            ctxPtr
                        )
                    }
                }
            }

            if rc != 0 {
                // Immediate error — the Rust side will NOT fire the callback,
                // so we must resume here and free the box ourselves.
                let unbox = Unmanaged<ContinuationBox>.fromOpaque(ctxPtr)
                    .takeRetainedValue()
                unbox.cont.resume(returning: nil)
            }
        }
    }

    /// Async/awaitable APP_LINK plain-DATA send.
    ///
    /// Registers the destination spec for `app`/`aspects`, fires one
    /// AppLinks send, and suspends until LRPROOF delivery or terminal
    /// failure.
    nonisolated func appLinkSendAsync(destHash: Data,
                                      app: String,
                                      aspects: [String],
                                      payload: Data) async -> Bool
    {
        let aspectsCsv = aspects.joined(separator: ".")
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let box = BoolContinuationBox(cont: cont)
            let ctxPtr = Unmanaged.passRetained(box).toOpaque()

            let rc: Int32 = destHash.withUnsafeBytes { destBuf -> Int32 in
                let destPtr = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return app.withCString { cApp -> Int32 in
                    return aspectsCsv.withCString { cAspects -> Int32 in
                        return payload.withUnsafeBytes { payBuf -> Int32 in
                            let payPtr = payBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            return lxmf_app_link_send_async(
                                self.handle,
                                destPtr, UInt32(destHash.count),
                                cApp,
                                cAspects,
                                payPtr, UInt32(payload.count),
                                _appLinkSendTrampoline,
                                ctxPtr
                            )
                        }
                    }
                }
            }

            if rc != 0 {
                let unbox = Unmanaged<BoolContinuationBox>.fromOpaque(ctxPtr)
                    .takeRetainedValue()
                unbox.cont.resume(returning: false)
            }
        }
    }

    // MARK: - Announce

    /// Announce this client's delivery destination.
    @discardableResult
    func announce() -> Bool {
        lxmf_client_announce(handle) == 0
    }

    /// Opt this client's delivery destination into Transport's auto-announce
    /// daemon. Transport will then re-announce automatically on every
    /// interface up-edge and every `refreshSecs` seconds (pass 0 for
    /// up-edge-only).
    @discardableResult
    func publish(refreshSecs: TimeInterval) -> Bool {
        lxmf_client_publish(handle, refreshSecs) == 0
    }

    /// Remove this client's delivery destination from the auto-announce daemon.
    @discardableResult
    func unpublish() -> Bool {
        lxmf_client_unpublish(handle) == 0
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

    /// Submit a previously created message via the top-level
    /// `AppLinks::send` pipeline.
    ///
    /// The Rust side runs an interface-race (parallel `request_path` on
    /// every online, non-LoRa iface, 2 s liveness cache) before
    /// dispatching, so the app no longer has to pre-warm a path or pick
    /// an iface. Returns `false` on failure (no usable iface, 5 s
    /// liveness budget exceeded, or LXMF dispatch error). See
    /// `RetichatFFI.lastError()` for the reason.
    @discardableResult
    func sendMessageViaAppLinks(_ msgHandle: UInt64) -> Bool {
        lxmf_message_send_via_app_links(msgHandle) == 0
    }

    /// Forget the cached liveness winner for `destHash`. Call from your
    /// `NWPathMonitor` handler when the active path flips (e.g. WiFi
    /// dropped, cellular came up) so the next AppLinks send re-races
    /// instead of reusing a now-dead iface.
    static func invalidateLiveness(_ destHash: Data) {
        destHash.withUnsafeBytes { buf in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            _ = lxmf_app_links_invalidate_liveness(p, UInt32(destHash.count))
        }
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

    nonisolated private static func fetchLastError() -> String {
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
