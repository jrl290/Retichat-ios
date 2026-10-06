//
//  DistroOutboxRuntime.swift
//  Retichat
//
//  What this device owes its distro, on iOS: the DistroOutbox wired to
//  SwiftData (SwiftDataOutboxStore), to the propagation link and uploads in the
//  glue crate (RetichatBridge.propagationUpload and its link events), to the
//  stack's start and stop, and to the distro the device holds (DistroManager).
//  RFed SPEC §17.12 "On the sending device", §17.11, "The phones' outbox".
//  Mirrors Retichat-android service/DistroOutboxRuntime.kt.
//
//  The outbox decides on its own executor (an actor, as Android decides on its
//  distro-outbox thread), so each event, a proof, a loss or a link coming up,
//  runs to completion before the next: the stack's threads only hand them over.
//  Building an upload (its stamp) runs off every actor, on a detached task.
//
//  It never starts the propagation link: the link is the one the router holds
//  for the propagation node (ChatRepository.startPropagationPolling and the poll
//  set the node on the router, which opens it), and what is owed waits for that
//  link to come up. The node is the RFed node's own lxmf.propagation, or the
//  Settings override (UserPreferences.effectiveLxmfPropagationHash): the one a
//  distro's messages are fanned out from.
//
//  The link comes up in two ways (James, 2026-10-03), and both are events the
//  stack tells, never read by polling (DESIGN_PRINCIPLES §1 and §3): a new link's
//  establishment (AppLinks' ACTIVE, DistroOutbox.onLinkEstablished), and a STALE
//  link's recovery because the node is heard on it again (AppLinks' RECOVERED,
//  DistroOutbox.onLinkRecovered). The reference's `Link.__receive` makes a STALE
//  link ACTIVE again and tells no one; Reticulum-rust's `link_recovered` callback
//  (an API extension, PARITY-AUDIT-1.5.2.md A34) tells AppLinks, which reports
//  RECOVERED with the link's id, for the link it still holds. Until that was
//  wired (2026-10-06) what was owed when a STALE link recovered waited for the
//  next establishment (about 35 s on staging). A held STALE link that is replaced
//  by a new one, or that times out and is re-opened, is an establishment as
//  before; the outbox itself runs a recovery only while that link is still the
//  propagation link (DistroOutbox.onLinkRecovered). The same as Android's.
//
//  An upload that never left the device, because no interface could carry its
//  packet (the glue's send could not queue it), is no failure: it goes when an
//  interface comes back online as well as at the next coming-up (James, 2026-10-06).
//  That third event is the stack's own interface up-edge (Transport's
//  `set_interface_online`, told by `retichat_interface_up_register`), never the
//  OS's "the network is available" (DistroOutbox.onInterfaceUp).
//

import Combine
import Foundation
import SwiftData

// MARK: - Log

/// Where the outbox says what it says. An error is also kept for a screen that shows it.
nonisolated final class DistroOutboxLog: OutboxLog, @unchecked Sendable {
    func info(_ message: String) { print("[DistroOutbox] \(message)") }
    func warn(_ message: String) { print("[DistroOutbox] WARN \(message)") }
    func error(_ message: String) {
        print("[DistroOutbox] ERROR \(message)")
        Task { @MainActor in DistroOutboxRuntime.shared.lastError = message }
    }
}

// MARK: - The propagation link and the uploads on it

nonisolated struct DistroOutboxFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// `PropagationPort` over the glue crate: the link AppLinks holds for the
/// propagation node, and uploads on it.
nonisolated final class FFIPropagationPort: PropagationPort, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Data?
    private let bridge: RetichatBridge

    init(bridge: RetichatBridge) {
        self.bridge = bridge
    }

    /// The propagation node this device uploads to, or nil when none is known.
    func setNode(_ node: Data?) {
        lock.lock(); defer { lock.unlock() }
        current = node
    }

    func node() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func held() -> HeldLink? {
        guard let node = node(), let link = bridge.propagationLink(node: node) else { return nil }
        return HeldLink(id: link.id, active: link.active)
    }

    nonisolated(nonsending) func build(_ entry: OwedEntry) async throws -> Data {
        guard let node = node() else { throw DistroOutboxFailure(message: "no propagation node is configured") }
        guard let key = Data(hexString: entry.distroKey), key.count == 64 else {
            throw DistroOutboxFailure(message: "the distro's key is not 64 bytes of hex")
        }
        let packed = entry.packed
        let bridge = bridge
        // Mining the stamp blocks: it runs on its own thread, never the caller's.
        return try await Task.detached(priority: .utility) { () throws -> Data in
            guard let upload = bridge.propagationBuildUpload(distroPublicKey: key, packed: packed, node: node) else {
                throw DistroOutboxFailure(message: DistroMessageFFI.rnsLastError())
            }
            return upload
        }.value
    }

    func upload(_ upload: Data, sink: UploadSink) throws -> UploadLeft? {
        guard let node = node() else { return nil }
        let watched = WatchedSink(sink)
        guard let started = bridge.propagationUpload(node: node, upload: upload, sink: watched) else {
            print("[DistroOutbox] upload did not leave: \(DistroMessageFFI.rnsLastError())")
            return nil
        }
        if !started.resource {
            // DESIGN_PRINCIPLES §1: the node proves a packet it holds at once. At 5 s with no
            // proof the violation is logged; it decides nothing (the proof, or the packet's
            // loss, does). A Resource's own progress is watched in the stack.
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(DistroOutbox.proofLiveMs + 1) * 1_000_000)
                if !watched.decided {
                    // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
                    print("[DistroOutbox] §1 VIOLATION: the propagation node has not proved an upload within "
                          + "\(DistroOutbox.proofLiveMs / 1000) s; its proof, or the packet's loss, decides it")
                }
            }
        }
        return UploadLeft(linkId: started.linkId, resource: started.resource)
    }
}

/// An upload's sink that notes it was decided, for the §1 watch.
nonisolated private final class WatchedSink: UploadSink, @unchecked Sendable {
    private let inner: UploadSink
    private let lock = NSLock()
    private var flag = false

    init(_ inner: UploadSink) { self.inner = inner }

    var decided: Bool { lock.lock(); defer { lock.unlock() }; return flag }

    private func mark() { lock.lock(); flag = true; lock.unlock() }

    func proved() { mark(); inner.proved() }
    func lost() { mark(); inner.lost() }
}

/// Where the stack's threads hand a link's coming-up: the one outbox and the node it watches.
nonisolated private enum PropagationLinkTarget {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var target: (node: String, outbox: DistroOutbox)?

    static func set(node: Data?, outbox: DistroOutbox?) {
        lock.lock(); defer { lock.unlock() }
        if let node, let outbox { target = (node.hexString, outbox) } else { target = nil }
    }

    /// A new propagation link's establishment is its ACTIVE event, carrying the link;
    /// a STALE one's recovery (the node was heard on it again) is its RECOVERED event,
    /// carrying the link too. Each is its own coming-up, on the outbox's own executor.
    static func deliver(dest: Data, status: UInt8, linkId: Data?) {
        lock.lock()
        let current = target
        lock.unlock()
        guard let current, dest.hexString == current.node, let linkId, !linkId.isEmpty else { return }
        let id = linkId.hexString
        if status == RetichatBridge.appLinkActive {
            print("[DistroOutbox] propagation link established \(id.prefix(8))")
            current.outbox.spawn { await current.outbox.onLinkEstablished(id) }
        } else if status == RetichatBridge.appLinkRecovered {
            print("[DistroOutbox] propagation link recovered \(id.prefix(8))")
            current.outbox.spawn { await current.outbox.onLinkRecovered(id) }
        }
    }

    /// A Reticulum interface came online: what never left the device goes now, if the
    /// propagation link is up (DistroOutbox.onInterfaceUp), on the outbox's own executor.
    static func deliverInterfaceUp(name: String) {
        lock.lock()
        let current = target
        lock.unlock()
        guard let current else { return }
        print("[DistroOutbox] interface \(name) online")
        current.outbox.spawn { await current.outbox.onInterfaceUp(name) }
    }
}

// MARK: - The runtime

@MainActor
final class DistroOutboxRuntime: ObservableObject {
    static let shared = DistroOutboxRuntime()

    /// The last thing the outbox said as an error (an upload not proved, a write
    /// refused), for a screen that shows it.
    @Published fileprivate(set) var lastError: String?

    private var container: ModelContainer?
    private var outbox: DistroOutbox?
    private let bridge = RetichatBridge.shared
    private let port: FFIPropagationPort
    private weak var client: LxmfClient?
    private var distroWatch: AnyCancellable?
    /// Waiting for the Keychain to say what distro this device holds (`start`).
    private var settledWatch: AnyCancellable?
    private var linkEventsRegistered = false
    private var interfaceUpRegistered = false

    /// Bumped by start and stop: a start that finds it changed has been stopped.
    private var generation = 0
    /// Start and stop run in the order they were asked, never over one another.
    private var lifecycle: Task<Void, Never>?

    private init() {
        port = FFIPropagationPort(bridge: bridge)
    }

    /// The store's container, from the app (RetichatAppDelegate), before the stack starts.
    func configure(container: ModelContainer) {
        self.container = container
    }

    /// The outbox, made on first use. It loads what a previous run left owed in `start`.
    private func ensureOutbox() -> DistroOutbox? {
        if let outbox { return outbox }
        guard let container else { return nil }
        let created = DistroOutbox(
            store: SwiftDataOutboxStore(container: container),
            port: port,
            heldDistro: { DistroManager.shared.info().map { HeldDistro(delivery: $0.deliveryHashHex, publicKey: $0.publicKeyHex) } },
            distroKnown: { DistroManager.shared.isSettled },
            log: DistroOutboxLog())
        outbox = created
        // Every change of the distro held (forgotten, generated, imported), and once at load:
        // the membership messages owed to a distro no longer held are dropped (James, 2026-10-03).
        distroWatch = RfedDistroClient.shared.$distro.sink { _ in
            created.spawn { await created.onDistroChanged() }
        }
        return created
    }

    private func chain(_ work: @escaping @Sendable () async -> Void) {
        let previous = lifecycle
        lifecycle = Task {
            await previous?.value
            await work()
        }
    }

    /// The propagation node: the Settings override, else the RFed node's own
    /// lxmf.propagation (UserPreferences.effectiveLxmfPropagationHash).
    private func refreshNode() {
        let hex = UserPreferences.shared.effectiveLxmfPropagationHash
        let node = Data(hexString: hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        port.setNode(node.flatMap { $0.count == 16 ? $0 : nil })
    }

    /// The stack is up (called from its start, once the router has its propagation node): load
    /// what a previous run left owed and listen for the propagation link. The link's
    /// coming-up (a new link's establishment) is what uploads it. A propagation link that is
    /// already ACTIVE when this runs came up before it listened, and is that link's
    /// coming-up all the same.
    ///
    /// It starts once the device knows what distro it holds (DistroManager.isSettled): on a
    /// background launch before the first unlock the Keychain cannot be read, and "no distro" is
    /// no finding, so nothing is loaded, dropped or uploaded until it is (an event, never a
    /// timer: RfedDistroClient publishes `distroSettled`). A link already ACTIVE then is
    /// the first the outbox hears of, and its coming-up all the same.
    func start(client: LxmfClient) {
        self.client = client
        generation += 1
        let mine = generation
        settledWatch = nil
        guard DistroManager.shared.isSettled else {
            print("[DistroOutbox] waiting for the Keychain: the distro this device holds is not known yet")
            settledWatch = RfedDistroClient.shared.$distroSettled.sink { [weak self] settled in
                // Published before the property changes: read it on the next turn of the main actor.
                guard settled else { return }
                Task { @MainActor in
                    guard let self, mine == self.generation, self.settledWatch != nil else { return }
                    self.settledWatch = nil
                    self.begin(mine)
                }
            }
            return
        }
        begin(mine)
    }

    private func begin(_ mine: Int) {
        refreshNode()
        guard let outbox = ensureOutbox() else {
            print("[DistroOutbox] no store is configured: nothing is kept for the distro")
            return
        }
        PropagationLinkTarget.set(node: port.node(), outbox: outbox)
        chain { [weak self] in
            await outbox.start()
            await self?.listen(outbox, generation: mine)
        }
    }

    /// Register for the link's events and take the link already up as a coming-up.
    private func listen(_ outbox: DistroOutbox, generation mine: Int) {
        guard mine == generation else { return }
        if !linkEventsRegistered {
            if bridge.propagationLinkEventsRegister(handler: { dest, status, linkId in
                PropagationLinkTarget.deliver(dest: dest, status: status, linkId: linkId)
            }) {
                linkEventsRegistered = true
            } else {
                print("[DistroOutbox] link events not registered: \(DistroMessageFFI.rnsLastError())")
            }
        }
        // An interface that comes back online sends what never left the device (James, 2026-10-06).
        if !interfaceUpRegistered {
            if bridge.interfaceUpRegister(handler: { name in PropagationLinkTarget.deliverInterfaceUp(name: name) }) {
                interfaceUpRegistered = true
            } else {
                print("[DistroOutbox] interface up-edges not registered: \(DistroMessageFFI.rnsLastError())")
            }
        }
        // Not awaited: a flush builds stamps, and the lifecycle must not wait for it.
        let port = port
        if let held = port.held(), held.active {
            outbox.spawn { await outbox.onLinkEstablished(held.id) }
        }
    }

    /// The stack is stopping: no proof can come for an upload still open, so each is
    /// decided not proved, and nothing is sent. The stack's shutdown drops the link
    /// callbacks and `interfaceUpClear` the interface one; the next `start` registers them again.
    func stop() {
        generation += 1
        settledWatch = nil
        linkEventsRegistered = false
        bridge.propagationLinkEventsClear()
        interfaceUpRegistered = false
        bridge.interfaceUpClear()
        PropagationLinkTarget.set(node: nil, outbox: nil)
        guard let outbox else { return }
        chain { await outbox.onStop() }
    }

    // MARK: What the user's actions owe

    /// The user joined or left `channelName` on this device (`op` "join" or "leave", at `atMs`
    /// from `DistroChannelSync.stampLocal`): with a distro, owe it the membership message C
    /// (RFed SPEC §17.12 "Who sends it"). The message is packed and signed by the distro
    /// once, here, and kept until the node proves it. A later action on the channel
    /// replaces it. Nothing here waits for the network: the upload is made on its own task.
    /// Never throws.
    func oweChannelSync(op: String, channelName: String, channelHashHex: String, atMs: Int64) async {
        guard let (distro, signer) = DistroManager.shared.signing() else { return }
        guard let outbox = ensureOutbox() else { return }
        refreshNode()
        guard let deviceHex = client?.destHashHex, DistroCodec.isAddressHex(deviceHex) else {
            print("[DistroOutbox] the \(op) of #\(channelName) not sent to the distro: this device's address is not known (§17.12)")
            return
        }
        let bridge = bridge
        guard let (packed, hash) = await Self.pack(bridge: bridge, distro: distro, signer: signer, title: "", content: "",
                                                   method: LxmfMethod.direct, fields: { handle in
            bridge.messageSetDistroChannelSync(handle: handle, op: op, name: channelName, atMs: atMs, deviceHex: deviceHex)
        }) else {
            fail("The \(op) of #\(channelName) was not sent to the distro: it could not be made")
            return
        }
        await outbox.owe(OwedEntry(
            id: DistroChannelSync.entryId(channelHashHex), kind: .channel,
            distro: distro.deliveryHashHex, distroKey: distro.publicKeyHex,
            msgHash: hash, packed: packed, label: "the \(op) of #\(channelName) (§17.12)",
            op: op, name: channelName, atMs: atMs))
    }

    /// The §17.11 sent copy of a message this device just sent as the distro to
    /// `recipient`: the same text, from D to D, with the recipient (0xFC) and this
    /// device's address (0xFD), packed and signed once and owed until the node proves
    /// it. Never throws.
    func oweSentCopy(recipient: Data, title: String, content: String) async {
        guard let (distro, signer) = DistroManager.shared.signing() else { return }
        guard let outbox = ensureOutbox() else { return }
        refreshNode()
        let recipientHex = recipient.hexString
        guard let deviceHex = client?.destHashHex, DistroCodec.isAddressHex(deviceHex) else {
            print("[DistroOutbox] sent copy: this device's address is not known — no copy for \(recipientHex.prefix(8))")
            return
        }
        let bridge = bridge
        guard let (packed, hash) = await Self.pack(bridge: bridge, distro: distro, signer: signer, title: title, content: content,
                                                   method: LxmfMethod.direct, fields: { handle in
            DistroMessageFFI.addField(handle, key: LxmfFieldKey.customType, value: DistroSent.customType)
                && DistroMessageFFI.addField(handle, key: LxmfFieldKey.customData, value: recipientHex)
                && DistroMessageFFI.addField(handle, key: LxmfFieldKey.customMeta, value: deviceHex)
        }) else {
            fail("A sent message was not copied to the distro: the copy could not be made")
            return
        }
        await outbox.owe(OwedEntry(
            id: "sent:\(hash)", kind: .sent,
            distro: distro.deliveryHashHex, distroKey: distro.publicKeyHex,
            msgHash: hash, packed: packed, label: "the sent-copy for \(recipientHex.prefix(8)) (§17.11)",
            toHex: recipientHex))
    }

    private func fail(_ message: String) {
        print("[DistroOutbox] \(message)")
        lastError = message
    }

    /// Make a message from the distro to the distro (its key, the identity `signer`, signs it),
    /// set its fields with `fields`, pack and sign it once, and return its LXMF bytes and message
    /// hash (hex). Nil, said, when any step fails. The message is made DIRECT only so that
    /// packing needs no destination: it is never sent from here; only the bytes it packs to are
    /// kept. Runs on a detached task: signing is not the main actor's.
    private static func pack(
        bridge: RetichatBridge, distro: DistroInfo, signer: UInt64, title: String, content: String,
        method: UInt8, fields: @escaping @Sendable (UInt64) -> Bool
    ) async -> (Data, String)? {
        await Task.detached(priority: .userInitiated) { () -> (Data, String)? in
            guard let distroHash = Data(hexString: distro.deliveryHashHex), distroHash.count == 16 else { return nil }
            let handle = bridge.messageCreate(destHash: distroHash, sourceHash: distroHash, content: content, title: title,
                                              method: method, identityHandle: signer)
            guard handle != 0 else { return nil }
            defer { DistroMessageFFI.destroy(handle) }
            guard fields(handle) else {
                print("[DistroOutbox] setting the fields failed: \(DistroMessageFFI.rnsLastError())")
                return nil
            }
            guard let packed = bridge.messagePack(handle: handle), let hash = DistroMessageFFI.hash(handle) else {
                print("[DistroOutbox] packing failed: \(DistroMessageFFI.rnsLastError())")
                return nil
            }
            return (packed, hash.hexString)
        }.value
    }
}
