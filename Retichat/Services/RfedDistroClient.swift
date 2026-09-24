import Combine
import Foundation
import UIKit

// MARK: - Public value types (bound by the Identity screen)

/// RFed-side state of this device's distro enrolment, for the Identity
/// screen's status line (Android IdentityScreen.kt:146-152).
nonisolated struct DistroRegistrationStatus: Equatable, Sendable {
    var registered = false
    var announced = false
    var lastError: String? = nil
    var lastPullCount = 0
}

/// Another of our devices offering this one its distro identity (SPEC §17.9).
nonisolated struct DistroTransferOffer: Equatable, Identifiable, Sendable {
    /// Unique per offer, so a newer offer from the same device is a new alert.
    let id: UUID
    /// 32 hex, lowercase: the sending device's lxmf.delivery address.
    let fromHashHex: String
    /// 128 hex, lowercase.
    let privateKeyHex: String
    /// A distro was held when the offer arrived. Offers for the key already
    /// held never become an offer at all.
    let replacesCurrent: Bool
}

/// A decrypted distro message, ready to be stored as an inbound DM from
/// whoever sent it (Android ChatRepository.onDistroMessageReceived).
nonisolated struct DistroMessage: Sendable {
    let sourceHash: Data
    let title: String
    let content: String
    let timestamp: Double
}

/// Speaks RFed's distro protocol on behalf of this device.
///
/// Mirrors Android service/RfedDistroClient.kt and the web client's
/// `_registerDistro`, `_publishDistroAnnounce`, `_unregisterDistro`,
/// `_pullDistroMessages` and `_handleDistroBlob` (Retichat-js app.js). Link
/// management and requests go through `ConnectionStateManager.appLinkSend`;
/// every payload and the blob decrypt come from `lxmf_rust::distro` via the
/// FFI — those are wire formats shared with Android, not rewritten here.
///
/// Split-aspect destinations (SPEC §17):
///   - `rfed.distro.register` carries `/rfed/distro/register`,
///     `/rfed/distro/announce` and `/rfed/pull` (reusing the register link
///     avoids a second LINKREQUEST a busy relay may drop, SPEC §17.8);
///   - `rfed.distro.unregister` carries `/rfed/distro/unregister`.
///
/// Where fan-out arrives on iOS: iOS never starts `rfed.delivery`, so live
/// fan-out arrives on the `rfed.propagation.stream` link (RFed `distro_fanout`
/// tier 2 — ChatRepository routes it here), and anything RFed deferred is
/// drained by `/rfed/pull`.
///
/// No retry loops and no timers (DESIGN_PRINCIPLES.md §3-§5): a registration
/// that cannot run is re-tried once when `rfed.distro.register`'s AppLink
/// next becomes ACTIVE — an existing event edge.
@MainActor
final class RfedDistroClient: ObservableObject {

    static let shared = RfedDistroClient()

    /// nil = no distro loaded.
    @Published private(set) var distro: DistroInfo?
    @Published private(set) var status = DistroRegistrationStatus()
    /// One slot; the newest offer wins (Android pendingTransfer).
    @Published private(set) var pendingTransfer: DistroTransferOffer?
    /// One-shot user-facing outcome; DistroNoticeCoordinator shows it above
    /// every sheet, then calls clearNotice().
    @Published private(set) var notice: String?
    /// A distro key is stored but will not load (DistroManager `.undecodable`).
    /// Generate/Import back it up before replacing it.
    @Published private(set) var storedKeyUnreadable = false

    var hasDistro: Bool { distro != nil }

    /// Sink for decrypted distro messages (ChatRepository.handleDistroMessage).
    /// A blob is recorded as seen only once this has taken it.
    var onMessage: ((DistroMessage) -> Void)?

    /// Up to this many `/rfed/pull` rounds per pull (Android PULL_ROUNDS_MAX).
    private static let pullRoundsMax = 8

    /// Serial queue for blob unwrap + dedup, off the main actor.
    nonisolated static let blobQueue = DispatchQueue(label: "distro.blob", qos: .utility)
    nonisolated private static let seen = DistroSeenStore()

    // MARK: - Private state

    private var client: LxmfClient?

    /// Bumped by stop, forget and adopt. Every await re-checks it, so a
    /// register or pull that finishes after the world changed drops its result.
    private var epoch: UInt64 = 0

    /// The (distro handle, epoch) an operation was started for.
    private struct RegKey: Equatable {
        let handle: UInt64
        let epoch: UInt64
    }

    private var registeredKey: RegKey?
    private var registerTask: Task<Void, Never>?
    private var registerTaskKey: RegKey?
    /// Set only when genuinely new work (a different key) arrived while a
    /// register was in flight.
    private var registerAgain = false
    /// Forget is draining an in-flight register and unregistering; nothing
    /// may start a new register meanwhile.
    private var forgetInProgress = false
    private var pullTask: Task<Int, Never>?
    private var pullTaskKey: RegKey?
    /// Destination whose ACTIVE edge re-runs registerIfNeeded, if armed.
    private var armedRetryDest: Data?
    private var protectedDataObserver: NSObjectProtocol?

    private init() {
        // Event edge for a background launch before first unlock: the
        // Keychain item (AfterFirstUnlock) is unreadable until then, and
        // DistroManager leaves the state `.unavailable` rather than "absent".
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let me = RfedDistroClient.shared
                await me.reloadFromKeychain()
                me.registerIfNeeded()
            }
        }
        // Load at launch so the Identity screen shows the distro before the
        // stack is up. Keychain work runs detached, never on the main actor.
        Task { @MainActor [weak self] in
            await self?.reloadFromKeychain()
        }
    }

    // MARK: - Destinations

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

    // MARK: - Helpers

    private func currentKey() -> RegKey? {
        let h = DistroManager.shared.handle
        return h == 0 ? nil : RegKey(handle: h, epoch: epoch)
    }

    private func isCurrent(_ k: RegKey) -> Bool {
        client != nil && k.epoch == epoch && DistroManager.shared.handle == k.handle
    }

    private func refresh() {
        distro = DistroManager.shared.info()
        storedKeyUnreadable = DistroManager.shared.storedKeyUnreadable
    }

    private func fail(_ k: RegKey, _ reason: String) {
        guard isCurrent(k) else { return }
        status.registered = false
        status.lastError = reason
        print("[Distro] \(reason)")
    }

    private func reloadFromKeychain() async {
        await Task.detached(priority: .utility) { DistroManager.shared.reloadIfNeeded() }.value
        refresh()
    }

    // MARK: - Stack lifecycle (ChatRepository)

    /// Load the key before anything can send or receive (Android StackRuntime
    /// 245-249: DistroManager.init precedes rfed.delivery and the router).
    func prepareForStackStart() async {
        await reloadFromKeychain()
    }

    /// After the stack and ConnectionStateManager are up (Android StackRuntime
    /// 310-313: RfedDistroClient.registerIfNeeded after the notify registrar).
    func onStackStarted(client: LxmfClient) {
        self.client = client
        registerIfNeeded()
    }

    /// Before ConnectionStateManager.deregister (Android shutdownNow:324).
    /// In-flight register/pull tasks are NOT cancelled: they finish, see
    /// isCurrent == false and drop their results.
    func onStackStopped() {
        epoch &+= 1
        client = nil
        registeredKey = nil
        status = .init()
        disarm()
        registerAgain = false
        DistroTransferTracker.shared.clear()
    }

    // MARK: - Registration

    /// Enrol this device under the loaded distro, once per (key, stack run).
    ///
    /// One register in flight at a time — the web client's "NEVER REMOVE"
    /// `_registerDistro` guard: concurrent registrations over one link have
    /// wedged RFed before.
    func registerIfNeeded() {
        guard !forgetInProgress, client != nil, let k = currentKey() else { return }
        if registeredKey == k { return }
        if registerTask != nil {
            if registerTaskKey != k { registerAgain = true }
            return
        }
        registerTaskKey = k
        registerTask = Task { [weak self] in
            guard let self else { return }
            await self.register(k)
            self.registerTask = nil
            self.registerTaskKey = nil
            if self.registerAgain {
                self.registerAgain = false
                self.registerIfNeeded()
            }
        }
    }

    /// Register, then hand RFed the pre-signed announce, then pull.
    ///
    /// Android RfedDistroClient.kt:73-102 / web `_registerDistro`. The order is
    /// load-bearing: registration tells RFed where to fan out; the announce
    /// (app_data [nil, nil, [0xD0]], SPEC §17.10, written by the Rust side) is
    /// what makes the address resolvable and marks it a distro. RFed only ever
    /// learns the distro PUBLIC key, so it cannot mint that announce itself.
    private func register(_ k: RegKey) async {
        guard let dest = Data(hexString: registerDestHex), dest.count == 16 else {
            fail(k, "no RFed node configured")
            return
        }
        guard let client else { return }
        guard let payload = Self.registerPayload(device: client.identityHandle, distro: k.handle) else {
            fail(k, "register payload: \(RetichatBridge.shared.rnsLastError() ?? "unknown error")")
            return
        }

        // Arm before the attempt (RfedNotifyRegistrar.swift:77-98 pattern) so
        // an ACTIVE edge that lands while we check cannot be missed.
        armRetryOnActive(dest)
        ConnectionStateManager.shared.appLinkPrime(
            destHash: dest, app: "rfed", aspects: ["distro", "register"])
        guard ConnectionStateManager.shared.appLinkStatus(destHash: dest) == 3 else {
            // Not an error: the armed handler drives the next attempt when the
            // link reaches ACTIVE. Status stays "Not yet registered".
            print("[Distro] register waits for rfed.distro.register ACTIVE")
            return
        }

        let resp = await ConnectionStateManager.shared.appLinkSend(
            destHash: dest, app: "rfed", aspects: ["distro", "register"],
            path: "/rfed/distro/register", payload: payload)
        guard isCurrent(k) else {
            print("[Distro] register result dropped: superseded")
            return
        }
        guard let resp else {
            // Re-arm: the one-shot handler may have fired (and removed itself)
            // while this request was in flight.
            armRetryOnActive(dest)
            fail(k, "RFed link not reachable")
            return
        }
        guard DistroCodec.isAffirmative(resp) else {
            // Stays armed, but fires only on the next ACTIVE edge (Android
            // parity): a refusal while the link stays up waits for that edge
            // or the next stack start. Retrying at once would be a retry loop.
            armRetryOnActive(dest)
            fail(k, "RFed refused registration")
            return
        }

        disarm()
        registeredKey = k
        status.registered = true
        status.lastError = nil
        print("[Distro] registered with RFed")

        // Pre-signed announce (Android publishAnnounce, kt:104-117).
        guard let announce = Self.announcePayload(distro: k.handle) else {
            status.announced = false
            status.lastError = "announce payload: \(RetichatBridge.shared.rnsLastError() ?? "unknown error")"
            print("[Distro] \(status.lastError ?? "")")
            return
        }
        let aresp = await ConnectionStateManager.shared.appLinkSend(
            destHash: dest, app: "rfed", aspects: ["distro", "register"],
            path: "/rfed/distro/announce", payload: announce)
        guard isCurrent(k) else {
            print("[Distro] announce result dropped: superseded")
            return
        }
        if DistroCodec.isAffirmative(aresp) {
            status.announced = true
            print("[Distro] RFed accepted the pre-signed announce")
        } else {
            // Not fatal: registration stands and fan-out still works for anyone
            // who already holds a path; new senders cannot resolve the address.
            status.announced = false
            status.lastError = "RFed refused the pre-signed announce"
            print("[Distro] RFed refused the pre-signed announce")
        }

        // Drain anything RFed deferred. Pulling right after the announce reply
        // replaces Android's 7 s PULL_AFTER_REGISTER_MS timer — the reply IS the
        // readiness event (DESIGN_PRINCIPLES.md §5, §7).
        await pull()
    }

    /// One-shot: re-run registerIfNeeded on the next ACTIVE (3) edge of
    /// `dest`, then remove itself (fixes Android quirk 3, whose handler was
    /// never removed and re-registered on every later edge).
    private func armRetryOnActive(_ dest: Data) {
        armedRetryDest = dest
        ConnectionStateManager.shared.setAppLinkStatusHandler(destHash: dest) { [weak self] s in
            guard s == 3 else { return }
            ConnectionStateManager.shared.setAppLinkStatusHandler(destHash: dest, handler: nil)
            self?.armedRetryDest = nil
            self?.registerIfNeeded()
        }
    }

    private func disarm() {
        guard let dest = armedRetryDest else { return }
        ConnectionStateManager.shared.setAppLinkStatusHandler(destHash: dest, handler: nil)
        armedRetryDest = nil
    }

    /// Android RfedDistroClient.kt:119-130. Same payload as register, on the
    /// unregister destination. True only when RFed affirmed it.
    private func unregister(handle: UInt64) async -> Bool {
        guard let client else { return false }
        guard let dest = Data(hexString: unregisterDestHex), dest.count == 16 else {
            print("[Distro] unregister: no RFed node configured")
            return false
        }
        guard let payload = Self.registerPayload(device: client.identityHandle, distro: handle) else {
            print("[Distro] unregister payload: \(RetichatBridge.shared.rnsLastError() ?? "unknown error")")
            return false
        }
        ConnectionStateManager.shared.appLinkPrime(
            destHash: dest, app: "rfed", aspects: ["distro", "unregister"])
        let resp = await ConnectionStateManager.shared.appLinkSend(
            destHash: dest, app: "rfed", aspects: ["distro", "unregister"],
            path: "/rfed/distro/unregister", payload: payload)
        return DistroCodec.isAffirmative(resp)
    }

    // MARK: - Deferred delivery

    /// Drain blobs RFed held for this device (SPEC §17.8; Android kt:132-153).
    ///
    /// Concurrent callers share one in-flight pull for the current key. A
    /// pull started for a superseded key (stop, forget, replace) stops at its
    /// next await and is not shared, so a new key's pull is never swallowed.
    /// A no-op without a distro or a running stack. Returns the number of
    /// blobs received.
    @discardableResult
    func pull() async -> Int {
        if let running = pullTask, let rk = pullTaskKey, isCurrent(rk) {
            return await running.value
        }
        guard client != nil, let k = currentKey(),
              let dest = Data(hexString: registerDestHex), dest.count == 16 else { return 0 }
        let task = Task { [weak self] () -> Int in
            guard let self else { return 0 }
            return await self.runPull(k, dest)
        }
        pullTask = task
        pullTaskKey = k
        let n = await task.value
        if pullTask == task {
            pullTask = nil
            pullTaskKey = nil
        }
        return n
    }

    /// Rounds are sequential and awaited, never concurrent. Each round is
    /// still its own one-shot link request (ConnectionStateManager's
    /// ephemeral design for non-stream RFed aspects).
    private func runPull(_ k: RegKey, _ dest: Data) async -> Int {
        var total = 0
        for round in 1...Self.pullRoundsMax {
            guard isCurrent(k) else { break }
            let resp = await ConnectionStateManager.shared.appLinkSend(
                destHash: dest, app: "rfed", aspects: ["distro", "register"],
                path: "/rfed/pull", payload: DistroCodec.msgpackNil)
            guard isCurrent(k) else { break }
            guard let resp else {
                status.lastError = "RFed pull: link not reachable"
                print("[Distro] pull round \(round): link not reachable")
                break
            }
            if let code = DistroCodec.pullErrorCode(resp) {
                status.lastError = String(format: "RFed pull refused (0x%02X)", code)
                print("[Distro] pull round \(round): \(status.lastError ?? "")")
                break
            }
            guard let decoded = RfedChannelClient.decodePullResponse(resp) else {
                status.lastError = "RFed pull: malformed response"
                print("[Distro] pull round \(round): malformed response (\(resp.count) bytes)")
                break
            }
            print("[Distro] pull round \(round): sent c0, got \(decoded.pairs.count) blob(s), more=\(decoded.morePending)")
            // The pair's first element is the distro hash; the blob itself
            // already starts with it (dest(16)|encrypted).
            for pair in decoded.pairs { Self.ingestBlob(pair.1) }
            total += decoded.pairs.count
            if status.lastError?.hasPrefix("RFed pull") == true { status.lastError = nil }
            if !decoded.morePending { break }
        }
        if isCurrent(k) { status.lastPullCount = total }
        return total
    }

    // MARK: - Inbound

    private nonisolated enum Inbound: Sendable {
        case transfer(fromHex: String, keyHex: String)
        case notification
        case message(DistroMessage)
    }

    /// Handle one distro blob, from the propagation stream, a pull, or (for
    /// parity) rfed.delivery. `blob` = dest(16)|encrypted, where dest is the
    /// distro's lxmf.delivery hash. Safe from any thread.
    ///
    /// Unwrap and dedup run on `blobQueue`. The seen key is recorded only
    /// after the main-actor hand-off succeeds (fixes Android quirk 5, which
    /// marked a message seen before storing it). A copy that races through
    /// both the stream and a pull is caught by ChatRepository's msgId check.
    nonisolated static func ingestBlob(_ blob: Data) {
        blobQueue.async { unwrapAndDeliver(blob) }
    }

    nonisolated private static func unwrapAndDeliver(_ blob: Data) {
        let h = DistroManager.shared.handle
        guard h != 0 else {
            print("[Distro] blob dropped: no distro loaded")
            return
        }
        var outLen: UInt32 = 0
        let ptr = blob.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
            retichat_distro_unwrap(h, raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                   UInt32(blob.count), &outLen)
        }
        guard let ptr else {
            // Read on this thread: the Rust error slot is thread-local.
            print("[Distro] unwrap rejected blob: \(DistroMessageFFI.rnsLastError())")
            return
        }
        let json = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)

        // Zero length is not an error: the blob was addressed to a different
        // distro, which a node may legitimately hand over.
        guard !json.isEmpty else { return }
        guard let parsed = try? JSONDecoder().decode(UnwrappedBlob.self, from: json),
              let src = Data(hexString: parsed.source_hash), src.count == 16 else {
            print("[Distro] unwrap returned unreadable JSON (\(json.count) bytes)")
            return
        }
        let srcHex = src.hexString
        let key = DistroCodec.seenKey(sourceHex: srcHex, timestamp: parsed.timestamp)
        guard !seen.contains(key) else { return }

        let inbound: Inbound
        if let transfer = parsed.distro_transfer_key, !transfer.isEmpty {
            // An offer to act on, not a message to display.
            inbound = .transfer(fromHex: srcHex, keyHex: transfer)
        } else if parsed.is_delivery_notification {
            // This device signs as the distro, so recipients' delivery
            // notifications come back via fan-out. Storing them posts empty bubbles.
            inbound = .notification
        } else {
            inbound = .message(DistroMessage(sourceHash: src, title: parsed.title ?? "",
                                             content: parsed.content ?? "",
                                             timestamp: parsed.timestamp))
        }

        Task { @MainActor in
            let handed = RfedDistroClient.shared.deliver(inbound)
            if handed { blobQueue.async { seen.record(key) } }
        }
    }

    private func deliver(_ inbound: Inbound) -> Bool {
        switch inbound {
        case .transfer(let fromHex, let keyHex):
            offerTransfer(fromHashHex: fromHex, privateKeyHex: keyHex)
            return true
        case .notification:
            return true
        case .message(let m):
            guard let onMessage else {
                print("[Distro] no message sink; not recorded")
                return false
            }
            onMessage(m)
            return true
        }
    }

    private nonisolated struct UnwrappedBlob: Decodable, Sendable {
        let source_hash: String
        let timestamp: Double
        let title: String?
        let content: String?
        let is_delivery_notification: Bool
        let ticket: String?
        let distro_transfer_key: String?
    }

    // MARK: - Identity transfer (receive)

    /// Surface another device's distro offer (Android kt:195-203). Called for
    /// a transfer arriving by fan-out, by direct LXMF, or via the NSE import.
    ///
    /// Like Android and the web, offers are gated only by the user's answer to
    /// the dialog — nothing here trusts the sender.
    func offerTransfer(fromHashHex: String, privateKeyHex: String) {
        guard let key = DistroCodec.parsePrivateKey(privateKeyHex) else {
            print("[Distro] transfer from \(fromHashHex.prefix(8)) ignored: not a distro private key")
            return
        }
        let hex = key.hexString
        if hex == DistroManager.shared.exportHex() {
            print("[Distro] transfer from \(fromHashHex.prefix(8)) ignored: already hold this distro")
            return
        }
        // The DIRECT and propagated copies of one transfer both arrive.
        if pendingTransfer?.privateKeyHex == hex { return }
        pendingTransfer = DistroTransferOffer(
            id: UUID(), fromHashHex: fromHashHex.lowercased(), privateKeyHex: hex,
            replacesCurrent: hasDistro)
        print("[Distro] transfer offered by \(fromHashHex.prefix(8)) replacesCurrent=\(hasDistro)")
    }

    /// Clears the offer; on accept, imports the key and registers it, then
    /// reports the outcome via `notice`. The distro being replaced is NOT
    /// unregistered from RFed (Android resolveTransfer and web parity).
    func resolveTransfer(accept: Bool) {
        let offer = pendingTransfer
        pendingTransfer = nil
        guard accept, let offer else { return }
        Task { [weak self] in
            guard let self else { return }
            let r = await self.importKey(offer.privateKeyHex)
            self.notice = (r == .ok) ? "Distro identity imported" : "Could not import the distro identity"
        }
    }

    // MARK: - Identity screen actions

    func generate() async -> DistroKeyResult {
        let r = await Task.detached(priority: .userInitiated) { DistroManager.shared.generate() }.value
        adopted(r)
        return r
    }

    /// Accepts rfed-distro-private-key://, rfed-distro-id:// or bare 128-hex
    /// (any case; a trailing "/" is ignored).
    func importKey(_ text: String) async -> DistroKeyResult {
        let r = await Task.detached(priority: .userInitiated) { DistroManager.shared.importText(text) }.value
        adopted(r)
        return r
    }

    private func adopted(_ r: DistroKeyResult) {
        guard r == .ok else { return }
        epoch &+= 1
        registeredKey = nil
        status = .init()
        refresh()
        registerIfNeeded()
    }

    /// Unregister from RFed, then delete the key (Android IdentityScreen.kt:
    /// 221-237). Returns true only when RFed confirmed the unregister; the
    /// key is deleted either way, and the UI surfaces a `false`.
    ///
    /// The delete is conditional on the key still being the one Forget
    /// started with. The transfer-offer alert is presented by UIKit above
    /// every sheet, so the user can accept an offer while the unregister
    /// below is in flight; deleting unconditionally would then destroy the
    /// key just imported, which has no backup.
    func forget() async -> Bool {
        let h = DistroManager.shared.handle
        forgetInProgress = true
        epoch &+= 1
        disarm()
        registerAgain = false
        // Let any in-flight register land at RFed before the unregister, so
        // RFed never sees register-after-unregister.
        if let inFlight = registerTask { await inFlight.value }

        var confirmed = false
        if client != nil, h != 0 {
            confirmed = await unregister(handle: h)
        }
        let result = await Task.detached(priority: .userInitiated) {
            DistroManager.shared.forget(expectedHandle: h)
        }.value

        epoch &+= 1
        registeredKey = nil
        status = .init()
        refresh()
        forgetInProgress = false
        // A key adopted meanwhile (result == .superseded) had its register
        // blocked by forgetInProgress; enrol it now. No-op without a key.
        registerIfNeeded()

        if !confirmed {
            print("[Distro] forget: RFed did not confirm unregister (stack running=\(client != nil))")
        }
        switch result {
        case .deleted: break
        case .deleteFailed:
            print("[Distro] forget: Keychain delete failed; the key may reload on next launch")
        case .superseded:
            print("[Distro] forget: a new distro was adopted meanwhile; kept it")
        }
        return confirmed
    }

    // MARK: - Identity transfer (send)

    /// Send the distro private key to another of our devices (SPEC §17.9;
    /// Android RfedDistroClient.sendIdentityTo, kt:216-248).
    ///
    /// The message is signed as this DEVICE, never the distro: the receiver
    /// must see which device offered it. Sent DIRECT; DistroTransferTracker
    /// falls back to a propagated copy on PROP_FALLBACK_REQUESTED or failure.
    /// True means submitted, not delivered — the outcome arrives via `notice`.
    func sendIdentity(toDeviceHashHex: String) async -> Bool {
        let hex = toDeviceHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 32, let dest = Data(hexString: hex), dest.count == 16 else {
            print("[Distro] sendIdentity: not a 32-hex LXMF address")
            return false
        }
        guard let keyHex = DistroManager.shared.exportHex() else {
            print("[Distro] sendIdentity: no distro loaded")
            return false
        }
        guard let client else {
            print("[Distro] sendIdentity: stack not running")
            return false
        }
        guard hex != client.destHashHex, hex != distro?.deliveryHashHex else {
            print("[Distro] sendIdentity: refusing to send the identity to our own address")
            return false
        }
        let deviceHash = client.destHash
        let deviceHandle = client.identityHandle
        let direct = LxmfMethod.direct
        let bridge = RetichatBridge.shared

        return await Task.detached(priority: .userInitiated) { () -> Bool in
            // Android step 2: prime the path and link; the router requests the
            // recipient's key if it is unknown.
            _ = client.appLinkOpen(dest)

            let h = bridge.messageCreate(
                destHash: dest, sourceHash: deviceHash,
                content: "Distro identity transfer", title: "Distro Identity",
                method: direct, identityHandle: deviceHandle)
            guard h != 0 else { return false }

            guard DistroMessageFFI.addField(h, key: LxmfFieldKey.customType, value: DistroTransfer.customType),
                  DistroMessageFFI.addField(h, key: LxmfFieldKey.customData, value: keyHex) else {
                print("[Distro] sendIdentity: add field failed: \(DistroMessageFFI.lastError())")
                DistroMessageFFI.destroy(h)
                return false
            }
            guard DistroMessageFFI.sendViaAppLinks(h) else {
                print("[Distro] sendIdentity: send failed: \(DistroMessageFFI.lastError())")
                DistroMessageFFI.destroy(h)
                return false
            }
            if let hash = DistroMessageFFI.hash(h) {
                DistroTransferTracker.shared.track(hashHex: hash.hexString, handle: h)
            } else {
                // Submitted, but its outcome cannot be followed. Release our
                // registry handle — the router holds its own reference (as
                // sendPropagatedClone assumes), and nothing would ever
                // destroy it otherwise (GroupChatManager.track does the same).
                print("[Distro] sendIdentity: untracked transfer (no message hash)")
                DistroMessageFFI.destroy(h)
            }
            return true
        }.value
    }

    // MARK: - Notices

    /// Also used by ChatRepository for a transfer the NSE fetched but could
    /// not keep (PendingNotification.DistroTransferStash.lost).
    func post(notice: String) {
        self.notice = notice
    }

    func clearNotice() {
        notice = nil
    }

    // MARK: - FFI payload helpers

    nonisolated private static func registerPayload(device: UInt64, distro: UInt64) -> Data? {
        var outLen: UInt32 = 0
        guard let ptr = retichat_distro_register_payload(device, distro, &outLen) else { return nil }
        let data = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)
        return data.isEmpty ? nil : data
    }

    /// nil app_data: the Rust side (lxmf_rust::distro::announce_payload)
    /// always writes [nil, nil, [0xD0]] — SF_RFED_DISTRO, SPEC §17.10.
    nonisolated private static func announcePayload(distro: UInt64) -> Data? {
        var outLen: UInt32 = 0
        guard let ptr = retichat_distro_announce_payload(distro, nil, 0, &outLen) else { return nil }
        let data = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)
        return data.isEmpty ? nil : data
    }
}

// MARK: - Message FFI (off the main actor)

/// Thin nonisolated wrappers over the lxmf_message_* C calls. LxmfClient's
/// static helpers are main-actor isolated under the project's default
/// isolation, and the transfer send and its fallback run on detached tasks.
nonisolated enum DistroMessageFFI {
    static func addField(_ h: UInt64, key: UInt8, value: String) -> Bool {
        value.withCString { lxmf_message_add_field(h, key, $0) == 0 }
    }

    static func sendViaAppLinks(_ h: UInt64) -> Bool {
        lxmf_message_send_via_app_links(h) == 0
    }

    static func hash(_ h: UInt64) -> Data? {
        var buf = [UInt8](repeating: 0, count: 32)
        let len = lxmf_message_hash(h, &buf, 32)
        guard len > 0 else { return nil }
        return Data(buf[0..<Int(len)])
    }

    static func clonePropagated(_ h: UInt64) -> UInt64 {
        lxmf_message_clone_propagated(h)
    }

    static func destroy(_ h: UInt64) {
        _ = lxmf_message_destroy(h)
    }

    /// The retichat_*/rns_* error slot (thread-local in Rust): read on the
    /// thread whose call failed. Same as RetichatBridge.rnsLastError, callable
    /// without touching the main-actor `RetichatBridge.shared`.
    static func rnsLastError() -> String {
        guard let ptr = rns_last_error() else { return "unknown" }
        let s = String(cString: ptr)
        rns_free_string(ptr)
        return s.isEmpty ? "unknown" : s
    }

    /// The lxmf_* error slot. Read on the thread whose call failed.
    static func lastError() -> String {
        guard let ptr = lxmf_last_error() else { return "unknown" }
        let s = String(cString: ptr)
        lxmf_free_string(ptr)
        return s.isEmpty ? "unknown" : s
    }
}

// MARK: - Transfer outcome tracking

/// Follows an identity-transfer message to a user-visible outcome.
///
/// Mirrors GroupChatManager.swift:259-345 (and Android's DIRECT→PROPAGATED
/// order in sendIdentityTo): PROP_FALLBACK_REQUESTED (0x10) or a failure of
/// the DIRECT copy sends a propagated clone; the outcome is published as a
/// RfedDistroClient notice. The direct and propagated copies share one
/// message hash, so a second failure is the final one.
///
/// nonisolated + lock: tracked from a detached send task, consulted from
/// ChatRepository.handleMessageState on the main actor.
nonisolated final class DistroTransferTracker: @unchecked Sendable {

    static let shared = DistroTransferTracker()

    private struct Entry {
        let handle: UInt64
        var fallbackStarted: Bool
        var failures: Int
    }

    private let lock = NSLock()
    private var tracked: [String: Entry] = [:]
    private var _onTracked: (@Sendable (String) -> Void)?

    private init() {}

    /// Called after a hash is tracked, so ChatRepository can replay states
    /// that arrived before tracking (its earlyMessageStates buffer).
    var onTracked: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onTracked }
        set { lock.lock(); _onTracked = newValue; lock.unlock() }
    }

    func track(hashHex: String, handle: UInt64) {
        lock.lock()
        tracked[hashHex] = Entry(handle: handle, fallbackStarted: false, failures: 0)
        let cb = _onTracked
        lock.unlock()
        cb?(hashHex)
    }

    private enum Action {
        case none
        case fallback(UInt64)
        case finish(UInt64, notice: String?)
    }

    /// Returns false for hashes this tracker does not own. `client` is the
    /// running stack the caller holds; the tracker acts only while one exists
    /// (the FFI calls themselves are client-free).
    func handleMessageState(hashHex: String, state: UInt8, client: LxmfClient) -> Bool {
        let isFailure = state == 0xFD || state == 0xFE || state == 0xFF
        lock.lock()
        guard var e = tracked[hashHex] else {
            lock.unlock()
            return false
        }
        var action = Action.none
        switch state {
        case 0x10 where !e.fallbackStarted,
             _ where isFailure && !e.fallbackStarted:
            e.fallbackStarted = true
            if isFailure { e.failures += 1 }
            tracked[hashHex] = e
            action = .fallback(e.handle)
        case 0x04:
            // Direct SENT is terminal success; propagated SENT = held by the
            // node. The submission toast already said "Identity sent".
            tracked.removeValue(forKey: hashHex)
            action = .finish(e.handle, notice: nil)
        case 0x08:
            tracked.removeValue(forKey: hashHex)
            action = .finish(e.handle, notice: "Identity delivered")
        case _ where isFailure:
            e.failures += 1
            if e.failures >= 2 {
                tracked.removeValue(forKey: hashHex)
                action = .finish(e.handle, notice: "Could not deliver the identity")
            } else {
                tracked[hashHex] = e
            }
        default:
            break   // intermediate states, or a second 0x10
        }
        lock.unlock()

        switch action {
        case .none:
            break
        case .fallback(let handle):
            Task.detached(priority: .utility) { [weak self] in
                self?.sendPropagatedClone(hashHex: hashHex, directHandle: handle)
            }
        case .finish(let handle, let notice):
            DistroMessageFFI.destroy(handle)
            if let notice { Self.post(notice) }
        }
        return true
    }

    private func sendPropagatedClone(hashHex: String, directHandle: UInt64) {
        let clone = DistroMessageFFI.clonePropagated(directHandle)
        var sent = false
        if clone != 0 {
            sent = DistroMessageFFI.sendViaAppLinks(clone)
            if !sent { print("[Distro] transfer: propagated send failed: \(DistroMessageFFI.lastError())") }
            // The router retains the message; release the registry handle so it
            // cannot replace the direct handle under their shared hash.
            DistroMessageFFI.destroy(clone)
        } else {
            print("[Distro] transfer: propagated clone failed: \(DistroMessageFFI.lastError())")
        }
        if sent {
            print("[Distro] transfer: propagation fallback dispatched")
            Self.post("Not reachable directly — sending the identity via the propagation node")
            return
        }
        // The propagated copy counts as one failure; if the direct copy has
        // already failed too, this is final.
        lock.lock()
        var finalHandle: UInt64?
        if var e = tracked[hashHex] {
            e.failures += 1
            if e.failures >= 2 {
                tracked.removeValue(forKey: hashHex)
                finalHandle = e.handle
            } else {
                tracked[hashHex] = e
            }
        }
        lock.unlock()
        if let finalHandle {
            DistroMessageFFI.destroy(finalHandle)
            Self.post("Could not deliver the identity")
        }
    }

    /// Stack stop: release every tracked handle (ChatRepository.stopService
    /// does the same for its pendingOutbound).
    func clear() {
        lock.lock()
        let handles = tracked.values.map(\.handle)
        tracked.removeAll()
        lock.unlock()
        for h in handles { DistroMessageFFI.destroy(h) }
    }

    private static func post(_ notice: String) {
        Task { @MainActor in RfedDistroClient.shared.post(notice: notice) }
    }
}

// MARK: - Seen store

/// Remembers which distro messages have already been handed off.
///
/// Persisted, because the deferred queue outlives an app launch: a blob still
/// held by RFed would otherwise be re-admitted on next start and appear twice.
/// Keys are DistroCodec.seenKey (source:timestamp), oldest first, capped at 500
/// (Android UserPreferences.markDistroSeen).
nonisolated final class DistroSeenStore: @unchecked Sendable {
    private let defaultsKey = "distro_seen_keys"
    private let lock = NSLock()

    func contains(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).contains(key)
    }

    func record(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        let existing = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        let updated = DistroCodec.appendSeen(existing, key: key)
        if updated != existing { UserDefaults.standard.set(updated, forKey: defaultsKey) }
    }
}
