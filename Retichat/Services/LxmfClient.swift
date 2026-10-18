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

/// `withCString` for an optional string: `body` gets NULL for nil.
nonisolated private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

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

    /// The initial Message Display Name (DISPLAY_NAMES.md §4.1): sent inside
    /// messages (field 0xD1) by the router's name ledger, never announced.
    /// Empty = none. Changed at runtime with setMessageDisplayName; the
    /// Announce Display Name starts empty and is set with
    /// setAnnounceDisplayName before the first announce.
    let messageDisplayName: String

    /// Log level (0–7, or -1 for default).
    let logLevel: Int32

    /// Stamp cost for the delivery endpoint (-1 = none).
    let stampCost: Int32

    /// App only: the directory the NSE loads its ratchets from. Every write
    /// of the delivery ratchet file is mirrored there, identical, from
    /// before the destination can announce (lxmf_client_start_with_ratchets;
    /// Reticulum-rust PARITY-AUDIT-1.5.2.md A29). The directory must exist.
    /// nil = no mirror.
    var ratchetsMirrorDir: String? = nil

    /// NSE only: read-only ratchets from before they load. The NSE never
    /// rotates a ratchet and never writes the App Group ratchet file; it
    /// reloads the app's mirror when a message needs a newer ratchet.
    var ratchetsFrozen: Bool = false
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

/// Heap box retained across the C FFI boundary for persistent APP_LINK
/// packet callbacks.
fileprivate final class AppLinkPacketCallbackBox {
    let callback: @Sendable (Data) -> Void
    init(callback: @escaping @Sendable (Data) -> Void) { self.callback = callback }
}

nonisolated fileprivate final class AppLinkInboundRequestBox {
    let callback: @Sendable (String, Data) -> Bool
    init(callback: @escaping @Sendable (String, Data) -> Bool) { self.callback = callback }
}

/// Top-level trampoline for `lxmf_app_link_set_outbound_setup`.
nonisolated fileprivate let _appLinkInboundRequestTrampoline: lxmf_app_link_inbound_request_callback_t = {
    (ctx, pathPtr, dataPtr, dataLen) -> Bool in
    guard let ctx = ctx, let pathPtr = pathPtr else { return false }
    let box = Unmanaged<AppLinkInboundRequestBox>.fromOpaque(ctx).takeUnretainedValue()
    let data = (dataPtr != nil && dataLen > 0) ? Data(bytes: dataPtr!, count: Int(dataLen)) : Data()
    return box.callback(String(cString: pathPtr), data)
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

/// Top-level trampoline for `lxmf_app_link_register_packet_callback`.
fileprivate let _appLinkPacketTrampoline: lxmf_app_link_packet_callback_t = {
    (ctx, bytesPtr, bytesLen) -> Void in
    guard let ctx = ctx else { return }
    let box = Unmanaged<AppLinkPacketCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    let data: Data
    if let bytesPtr = bytesPtr, bytesLen > 0 {
        data = Data(bytes: bytesPtr, count: Int(bytesLen))
    } else {
        data = Data()
    }
    box.callback(data)
}

/// Manages a complete Reticulum + LXMF stack lifecycle through one opaque
/// handle.  All protocol internals are hidden behind the Rust `lxmf_*` FFI.
final class LxmfClient: @unchecked Sendable {

    private static func normalizedAspectSegments(app: String, aspects: [String]) -> [String] {
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

    private static func normalizedAspectSpec(app: String, aspects: [String]) -> String {
        normalizedAspectSegments(app: app, aspects: aspects).joined(separator: ".")
    }

    private static func normalizedAspectSpec(app: String, aspects: String) -> String {
        normalizedAspectSpec(app: app, aspects: [aspects])
    }

    /// Opaque handle returned by `lxmf_client_start`.
    let handle: UInt64

    /// Cached 16-byte identity hash.
    let identityHash: Data

    /// Cached 16-byte LXMF delivery destination hash.
    let destHash: Data

    private let appLinkPacketCallbackLock = NSLock()
    private var appLinkPacketCallbackBoxes: [String: Unmanaged<AppLinkPacketCallbackBox>] = [:]

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
                    config.messageDisplayName.withCString { name in
                        withOptionalCString(config.ratchetsMirrorDir) { mirror in
                            lxmf_client_start_with_ratchets(
                                dir, store, id,
                                config.createIdentity ? 1 : 0,
                                name,
                                config.logLevel,
                                config.stampCost,
                                mirror,
                                config.ratchetsFrozen ? 1 : 0
                            )
                        }
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

    /// Set the delivery callback with the group follow-up's receipt (RFed-spec Group.md, "Member
    /// statuses and keys"): `lxmf_client_set_delivery_callback`'s arguments, and for an accept or
    /// leave the key it carries for its own sender and the message as received. Replaces any
    /// delivery callback (fires on a background thread).
    @discardableResult
    func setDeliveryCallbackReceipt(
        _ callback: retichat_group_delivery_callback_t,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        retichat_client_set_delivery_callback_receipt(handle, callback, context) == 0
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

    /// Set the outbound propagation node without starting a sync.
    @discardableResult
    func setPropagationNode(nodeHash: Data) -> Bool {
        nodeHash.withUnsafeBytes { buf -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_client_set_propagation_node(handle, p, UInt32(nodeHash.count)) == 0
        }
    }

    /// Set a propagation node and request messages.
    @discardableResult
    func sync(nodeHash: Data) -> Bool {
        nodeHash.withUnsafeBytes { buf -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_client_sync(handle, p, UInt32(nodeHash.count)) == 0
        }
    }

    /// Feed raw propagated `lxmf_data` into the normal client delivery path.
    /// Thread-free: the rfed.link push handler calls it on a link worker.
    @discardableResult
    nonisolated func ingestPropagated(_ lxmfData: Data) -> Bool {
        lxmfData.withUnsafeBytes { buf -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_client_ingest_propagated(handle, p, UInt32(lxmfData.count)) == 1
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
                                 aspects: String) -> Bool {
        appLinkOpen(destHash, app: app,
                    aspectSpec: Self.normalizedAspectSpec(app: app, aspects: aspects))
    }

    @discardableResult
    nonisolated func appLinkOpen(_ destHash: Data,
                                 app: String = "lxmf",
                                 aspects: [String] = ["delivery"]) -> Bool {
        appLinkOpen(destHash, app: app,
                    aspectSpec: Self.normalizedAspectSpec(app: app, aspects: aspects))
    }

    @discardableResult
    private nonisolated func appLinkOpen(_ destHash: Data,
                                         app: String,
                                         aspectSpec: String) -> Bool {
        return destHash.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return app.withCString { (appC: UnsafePointer<CChar>) -> Bool in
                aspectSpec.withCString { (aspC: UnsafePointer<CChar>) -> Bool in
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
                                           aspects: String) -> Bool {
        appLinkOpenPersistent(destHash, app: app,
                              aspectSpec: Self.normalizedAspectSpec(app: app, aspects: aspects))
    }

    @discardableResult
    nonisolated func appLinkOpenPersistent(_ destHash: Data,
                                           app: String = "lxmf",
                                           aspects: [String] = ["delivery"]) -> Bool {
        appLinkOpenPersistent(destHash, app: app,
                              aspectSpec: Self.normalizedAspectSpec(app: app, aspects: aspects))
    }

    @discardableResult
    private nonisolated func appLinkOpenPersistent(_ destHash: Data,
                                                   app: String,
                                                   aspectSpec: String) -> Bool {
        return destHash.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return app.withCString { (appC: UnsafePointer<CChar>) -> Bool in
                aspectSpec.withCString { (aspC: UnsafePointer<CChar>) -> Bool in
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
    nonisolated func appLinkRegisterReconnect(app: String, aspects: String) -> Bool {
        appLinkRegisterReconnect(app: app, aspects: [aspects])
    }

    @discardableResult
    nonisolated func appLinkRegisterReconnect(app: String, aspects: [String]) -> Bool {
        let normalized = Self.normalizedAspectSegments(app: app, aspects: aspects)
        let aspect = ([app] + normalized).joined(separator: ".")
        return appLinkRegisterReconnect(aspect: aspect)
    }

    @discardableResult
    nonisolated func appLinkRegisterReconnect(aspect: String) -> Bool {
        aspect.withCString { cAspect in
            lxmf_app_link_register_reconnect(handle, cAspect) == 0
        }
    }

    /// Register an APP_LINK status callback.  Fires whenever an APP_LINK
    /// transitions state.  `status` byte: 0=NONE, 1=PATH_REQUESTED,
    /// 2=ESTABLISHING, 3=ACTIVE, 4=DISCONNECTED, and the event 5=RECOVERED
    /// (a held STALE link heard from its peer again; a handler that acts on
    /// ACTIVE alone ignores it).
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

    /// Set up every held outbound link to `destHash` from now on (rfed.link,
    /// RFed-spec Link.md): identify as this client once established, and answer
    /// the node's requests on `paths` with `callback` (true only when the app
    /// now holds the blob: the delivery proof). Call before opening the link.
    /// The callback runs on a link worker thread, which waits for its answer.
    ///
    /// Its box is never released: the link library keeps the setup for the
    /// life of the process, across stacks, and a push may still arrive on a
    /// link this client opened after the client is gone.
    @discardableResult
    nonisolated func setAppLinkOutboundSetup(
        destHash: Data,
        identify: Bool,
        paths: [String],
        callback: @escaping @Sendable (String, Data) -> Bool
    ) -> Bool {
        let box = Unmanaged.passRetained(AppLinkInboundRequestBox(callback: callback))
        let csv = paths.joined(separator: ",")
        let ok = destHash.withUnsafeBytes { buf -> Bool in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return csv.withCString { cPaths in
                lxmf_app_link_set_outbound_setup(
                    handle,
                    ptr,
                    UInt32(destHash.count),
                    identify ? 1 : 0,
                    cPaths,
                    _appLinkInboundRequestTrampoline,
                    box.toOpaque()
                ) == 0
            }
        }
        if !ok { box.release() }
        return ok
    }

    /// Register a callback for DATA packets received on a persistent APP_LINK.
    @discardableResult
    nonisolated func setAppLinkPacketCallback(
        destHash: Data,
        callback: @escaping @Sendable (Data) -> Void
    ) -> Bool {
        let key = destHash.map { String(format: "%02x", $0) }.joined()
        let box = Unmanaged.passRetained(AppLinkPacketCallbackBox(callback: callback))
        let ok = destHash.withUnsafeBytes { buf -> Bool in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_app_link_register_packet_callback(
                handle,
                ptr,
                UInt32(destHash.count),
                _appLinkPacketTrampoline,
                box.toOpaque()
            ) == 0
        }
        guard ok else {
            box.release()
            return false
        }

        appLinkPacketCallbackLock.lock()
        let old = appLinkPacketCallbackBoxes.updateValue(box, forKey: key)
        appLinkPacketCallbackLock.unlock()
        old?.release()
        return true
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
                                      aspects: String,
                                      payload: Data) async -> Bool
    {
        await appLinkSendAsync(
            destHash: destHash,
            app: app,
            aspectSpec: Self.normalizedAspectSpec(app: app, aspects: aspects),
            payload: payload
        )
    }

    nonisolated func appLinkSendAsync(destHash: Data,
                                      app: String,
                                      aspects: [String],
                                      payload: Data) async -> Bool
    {
        await appLinkSendAsync(
            destHash: destHash,
            app: app,
            aspectSpec: Self.normalizedAspectSpec(app: app, aspects: aspects),
            payload: payload
        )
    }

    private nonisolated func appLinkSendAsync(destHash: Data,
                                              app: String,
                                              aspectSpec: String,
                                              payload: Data) async -> Bool
    {
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let box = BoolContinuationBox(cont: cont)
            let ctxPtr = Unmanaged.passRetained(box).toOpaque()

            let rc: Int32 = destHash.withUnsafeBytes { destBuf -> Int32 in
                let destPtr = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return app.withCString { cApp -> Int32 in
                    return aspectSpec.withCString { cAspects -> Int32 in
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
    /// up-edge-only), both held per interface to one announce per period
    /// (`refreshSecs`, or 30 min when 0) since the last announce there,
    /// including the app's own `announce()`, which always goes out.
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

    /// Clone an existing message as a fresh propagated-method message while
    /// preserving fields and attachments. It keeps the packed timestamp too,
    /// so the copy has the original's message hash and a recipient that gets
    /// both keeps one. Clone only after the original was submitted (it is
    /// packed then), and never on the thread of a state callback: the clone
    /// takes the original's lock, which the router holds while reporting.
    static func messageClonePropagated(_ msgHandle: UInt64) -> UInt64 {
        lxmf_message_clone_propagated(msgHandle)
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
        releaseAppLinkPacketCallbackBoxes()
        lxmf_client_shutdown(handle)
    }

    deinit {
        releaseAppLinkPacketCallbackBoxes()
    }

    private func releaseAppLinkPacketCallbackBoxes() {
        appLinkPacketCallbackLock.lock()
        let boxes = Array(appLinkPacketCallbackBoxes.values)
        appLinkPacketCallbackBoxes.removeAll()
        appLinkPacketCallbackLock.unlock()
        for box in boxes {
            box.release()
        }
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

    // MARK: - Display names (DISPLAY_NAMES.md)

    /// The Message Display Name (§4.1): the router adds it (field 0xD1) to
    /// outbound messages by the name-ledger rule. Empty clears it. Takes
    /// effect at once; no restart. Blocking FFI: call off the main thread.
    @discardableResult
    nonisolated func setMessageDisplayName(_ name: String) -> Bool {
        name.withCString { lxmf_client_set_message_display_name(handle, $0) } == 0
    }

    /// The Announce Display Name (§2.2): the PUBLIC name in this client's
    /// lxmf.delivery announce. Empty announces nil. The next announce carries
    /// it. Blocking FFI: call off the main thread.
    @discardableResult
    nonisolated func setAnnounceDisplayName(_ name: String) -> Bool {
        name.withCString { lxmf_client_set_announce_display_name(handle, $0) } == 0
    }

    /// Clean a name exactly as the router does (§3), for what Settings saves
    /// and what the user types as a contact's local name. `announce` also
    /// maps "Anonymous Peer" to none. nil = no name. Pure; any thread.
    nonisolated static func cleanDisplayName(_ raw: String, announce: Bool = false) -> String? {
        let bytes = Data(raw.utf8)
        let ptr = bytes.withUnsafeBytes { buf in
            lxmf_display_name_clean(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    UInt32(bytes.count), announce ? 1 : 0)
        }
        guard let ptr else { return nil }
        let name = String(cString: ptr)
        lxmf_free_string(ptr)
        return name.isEmpty ? nil : name
    }

    /// Field 0xD1 of a delivered message's raw fields (§3): absent, clear or
    /// a cleaned name. Whether to accept it depends on the signature
    /// (DisplayNames.acceptMessageName). Pure; any thread.
    nonisolated static func decodeDisplayName(fieldsRaw: Data) -> DisplayNames.NameField {
        guard !fieldsRaw.isEmpty else { return .absent }
        var outLen: UInt32 = 0
        let ptr = fieldsRaw.withUnsafeBytes { buf in
            lxmf_display_name_decode(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                     UInt32(fieldsRaw.count), &outLen)
        }
        guard let ptr else { return .absent }
        let raw = Data(bytes: ptr, count: Int(outLen))
        lxmf_free_bytes(ptr, outLen)
        return DisplayNames.parseNameState(raw) ?? .absent
    }

    /// The Announce Display Name last heard from a destination hash (§5.1
    /// announceName: cleaned, "Anonymous Peer" is none), or nil.
    nonisolated func recallDisplayName(for destHash: Data) -> String? {
        // LXMF_DISPLAY_NAME_BUF_LEN holds the longest name (256 bytes + NUL).
        var buf = [CChar](repeating: 0, count: Int(LXMF_DISPLAY_NAME_BUF_LEN))
        let written = destHash.withUnsafeBytes { hashBuf -> Int32 in
            let p = hashBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return lxmf_client_recall_display_name(handle, p, UInt32(destHash.count), &buf, UInt32(LXMF_DISPLAY_NAME_BUF_LEN))
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
    nonisolated static var lastError: String? {
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

    /// Set a str entry of the Retichat field 0xD1 (DISPLAY_NAMES.md §10):
    /// key 1-127, merged into the map. Key 0 (the name), keys out of range
    /// and the wrong type for keys 1-9 are refused, changing nothing.
    @discardableResult
    static func messageSetRetichatString(_ msgHandle: UInt64, key: UInt8, value: String) -> Bool {
        value.withCString { lxmf_message_set_retichat_string(msgHandle, Int32(key), $0) == 0 }
    }

    /// As messageSetRetichatString, for a bool entry (key 8, relay done).
    @discardableResult
    static func messageSetRetichatBool(_ msgHandle: UInt64, key: UInt8, value: Bool) -> Bool {
        lxmf_message_set_retichat_bool(msgHandle, Int32(key), value ? 1 : 0) == 0
    }

    /// GROUP_POST_ID, key 11 of the Retichat field (REACTIONS-DESIGN.md §4): a Group post's id,
    /// 32 lowercase hex, on every member's copy of the post. Always in the Retichat field (it has
    /// no old top-level form). nonisolated: the fan-out makes its envelopes on ffiQueue.
    @discardableResult
    nonisolated static func messageSetGroupPostId(_ msgHandle: UInt64, _ postId: String) -> Bool {
        postId.withCString { lxmf_message_set_retichat_string(msgHandle, Int32(RetichatField.groupPostIdKey), $0) == 0 }
    }

    /// SENT_HASH, key 12 of the Retichat field (REACTIONS-DESIGN.md §5.2): on the Distro Sync of
    /// a send, the LXMF hash (64 lowercase hex) of the message it copies, so a reaction to that
    /// message names it on the user's other devices. nonisolated: the outbox packs on a task.
    @discardableResult
    nonisolated static func messageSetSentHash(_ msgHandle: UInt64, _ hashHex: String) -> Bool {
        hashHex.withCString { lxmf_message_set_retichat_string(msgHandle, Int32(RetichatField.sentHashKey), $0) == 0 }
    }

    /// Make an outbound message a reaction (upstream FIELD_REACTION 0x40, REACTIONS-DESIGN.md
    /// §2, §4): `to` is the target's LXMF hash (32 bytes) or, in a Group, its post id (16
    /// bytes); `content` the reaction, at most 64 bytes, "" to remove the sender's. False, with
    /// nothing changed, when the library refuses it (lxmf_last_error). nonisolated: the sends
    /// make their messages on ffiQueue and the outbox on a detached task.
    @discardableResult
    nonisolated static func messageSetReaction(_ msgHandle: UInt64, to: Data, content: String) -> Bool {
        content.withCString { cContent in
            to.withUnsafeBytes { buf -> Bool in
                guard let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                return lxmf_message_set_reaction(msgHandle, p, UInt32(to.count), cContent) == 0
            }
        }
    }

    /// Set a group entry on an outbound message: the one way group entries
    /// are written (DISPLAY_NAMES.md §10). The form is
    /// RetichatField.groupEntriesInRetichatField's: the old top-level field
    /// 0xA0-0xA8 until the switch, then key 1-9 of the Retichat field.
    @discardableResult
    static func messageSetGroupEntry(_ msgHandle: UInt64, _ entry: GroupEntry, _ value: GroupValue) -> Bool {
        guard let write = GroupFieldWrite.of(entry, value) else {
            print("[LxmfClient] group entry \(entry) refused: wrong type (\(value.isBool ? "bool" : "str"))")
            return false
        }
        let ok: Bool
        switch write {
        case .topLevel(let field, .str(let s)):  ok = messageAddField(msgHandle, key: field, value: s)
        case .topLevel(let field, .bool(let b)): ok = messageAddFieldBool(msgHandle, key: field, value: b)
        case .retichat(let key, .str(let s)):    ok = messageSetRetichatString(msgHandle, key: key, value: s)
        case .retichat(let key, .bool(let b)):   ok = messageSetRetichatBool(msgHandle, key: key, value: b)
        }
        if !ok { print("[LxmfClient] group entry \(entry) not set: \(lastError ?? "unknown")") }
        return ok
    }

    /// A message's outgoing attachments, the one way every send writes them: the picture
    /// `OutgoingImage.pick` chooses as FIELD_IMAGE, the rest as FIELD_FILE_ATTACHMENTS, in
    /// order (James, 2026-10-17: photos go as 0x06, which MeshChat and Sideband show inline; as
    /// 0x05 they were a download there). If the image field cannot be written the picture goes
    /// as a file, as before. nonisolated: the sends make their messages on ffiQueue.
    nonisolated static func messageAddAttachments(_ msgHandle: UInt64, _ attachments: [(String, Data)]) {
        let image = OutgoingImage.pick(attachments.map { $0.0 })
        for (i, (filename, data)) in attachments.enumerated() {
            if let image, i == image.index, messageSetImage(msgHandle, type: image.type, data: data) { continue }
            messageAddAttachment(msgHandle, filename: filename, data: data)
        }
    }

    /// FIELD_IMAGE (0x06): `[type, data]`, one per message. The type is 1 to 16 ASCII letters
    /// or digits ("jpg"); anything else, or no data, is false with nothing changed.
    @discardableResult
    nonisolated static func messageSetImage(_ msgHandle: UInt64, type: String, data: Data) -> Bool {
        type.withCString { cType in
            data.withUnsafeBytes { buf -> Bool in
                guard let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                return lxmf_message_set_image(msgHandle, cType, p, UInt32(data.count)) == 0
            }
        }
    }

    /// Add a file attachment to an outbound message.
    @discardableResult
    nonisolated static func messageAddAttachment(_ msgHandle: UInt64, filename: String, data: Data) -> Bool {
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
