//
//  DistroOffline.swift
//  Retichat
//
//  Offline use of a distro address (RFed-rust SPEC.md §17.15, James 2026-11-17): the
//  device that cannot reach RFed, and the sender that reaches it over a mesh.
//  Retichat-android's service/DistroOffline.kt, event for event.
//
//  The device. While its offline toggle is on (Settings, Identity, "Offline use", off by
//  default) and it is offline (DistroOfflineRules.offline), it holds its offline address
//  `rfed.distro.direct.<random>` and the lookup address `rfed.distro.direct`, both with the
//  distro's key, until the app restarts; `<random>` is made once per distro and kept
//  (UserPreferences.distroOfflineRandom). It announces the offline address on each of its
//  mesh connections when it goes offline, and on a mesh connection that comes up while it is
//  offline; never on a timer. Once it reaches RFed again, or the toggle is turned off, it is
//  back: it announces once on its mesh connections that it is back, and the lookup answers
//  nothing. A message that comes to the offline address is kept as Distro mail from RFed is
//  (RfedDistroClient.takeDirect) and owed to RFed as a sent copy is
//  (DistroOutboxRuntime.oweDirect).
//
//  The sender. When this device sends a message to a distro, it also sends the same sealed
//  message, with the same stamp, to each offline address of that distro that is live (a
//  fan-out, `sentToDistro`). It keeps every offline address it learns; one is live from when
//  its announce, or an answer for it, says it is offline, or a lookup names it, until one says
//  it is back or a send to it fails. Once per distro each time a mesh connection comes up, a
//  send asks over the mesh connections: a path request for each kept address and for the
//  lookup. When an address becomes live, it is sent each message for the distro still waiting
//  to reach RFed, and each sent after asking, that it has not had. A failed send is said in the
//  log and never repeated (DESIGN_PRINCIPLES §3); the message still goes through RFed. A send
//  the device proves, or answers it holds, shows the message delivered.
//
//  Every event runs on one serial queue (`distro-offline`), in order. The link to RFed's
//  status, the interfaces' edges and the announces heard are its events; it starts no timer.
//

import Combine
import Foundation

nonisolated final class DistroOffline: @unchecked Sendable {
    /// Made on the main actor, which owns RetichatBridge.shared; a send captures it there before
    /// it leaves for the FFI queue (ChatRepository).
    @MainActor static let shared = DistroOffline(bridge: RetichatBridge.shared)

    private let queue = DispatchQueue(label: "distro-offline", qos: .utility)
    /// Only its nonisolated functions are called, from any thread.
    private let bridge: RetichatBridge

    /// Offline: went offline and is not back. Read on the stack's threads by `take`.
    private let flagLock = NSLock()
    private var offlineFlag = false
    private var offline: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return offlineFlag }
        set { flagLock.lock(); offlineFlag = newValue; flagLock.unlock() }
    }

    // Set at the stack's start (on `queue`).
    private var started = false
    private var configDir = ""
    private var rnodeNames: Set<String> = []
    private var propagationNode: Data?
    private var rfedPropagation: Data?
    private var collect: ((String) -> Void)?
    private var delivered: ((String) -> Void)?
    private var distroWatch: AnyCancellable?

    // The device (on `queue`).
    private var online: [String] = []
    private var rfedReached: Bool?
    private struct HeldPair { let distroHex: String; let random: String; let offline: Data }
    private var held: HeldPair?
    /// Siblings' offline addresses heard announced offline since this device last went offline.
    private var siblings: [String] = []

    // The sender (on `queue`).
    /// A copy of a message sent to a distro: the outbound message's `handle` says whether it
    /// has reached RFed.
    /// Read and written on `queue` alone; the outcome handler hands it back there.
    private final class Copy: @unchecked Sendable {
        let messageId: String
        let msgHash: String
        let bytes: Data
        let handle: UInt64
        var afterAsk: Bool
        var sentTo = Set<String>()
        init(messageId: String, msgHash: String, bytes: Data, handle: UInt64, afterAsk: Bool) {
            self.messageId = messageId
            self.msgHash = msgHash
            self.bytes = bytes
            self.handle = handle
            self.afterAsk = afterAsk
        }
    }
    /// Distro (hex) -> the copies kept for its offline addresses.
    private var copies: [String: [Copy]] = [:]
    /// Distro (hex) -> its offline addresses (random parts) live now.
    private var live: [String: Set<String>] = [:]
    /// Distros asked for since a mesh connection last came up.
    private var asked = Set<String>()
    /// Distros heard from since a mesh connection last came up.
    private var heard = Set<String>()

    private init(bridge: RetichatBridge) {
        self.bridge = bridge
    }

    private func say(_ line: String) { print("[DistroOffline] \(line)") }

    // MARK: Start and stop

    /// The stack is up (ChatRepository.finishStartService): listen to the link to RFed, to the
    /// interfaces' edges and to what comes to the offline address. What was held in an earlier
    /// start stays held (Reticulum keeps it until the app restarts), and so does being offline;
    /// what the new stack's link to RFed says decides from here. `collect` asks RFed for what
    /// it holds (a device that holds no link to it); `delivered` shows a message delivered.
    @MainActor
    func start(configDir: String, rnodeNames: Set<String>, collect: @escaping (String) -> Void,
               delivered: @escaping (String) -> Void) {
        let prefs = UserPreferences.shared
        func hash16(_ hex: String) -> Data? {
            Data(hexString: hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap { $0.count == 16 ? $0 : nil }
        }
        let propagationNode = hash16(prefs.effectiveLxmfPropagationHash)
        let rfedPropagation = hash16(prefs.rfedDerivedLxmfPropagationHash)
        let rfedNode = prefs.effectiveRfedNodeIdentityHash.lowercased()
        queue.async {
            self.configDir = configDir
            self.rnodeNames = rnodeNames
            self.propagationNode = propagationNode
            self.rfedPropagation = rfedPropagation
            self.collect = collect
            self.delivered = delivered
            self.online = self.bridge.onlineInterfaces()
            self.rfedReached = nil
            self.started = true
        }
        if !bridge.distroDirectRegister(
            take: { [weak self] distro, sealed, stamp in self?.take(distro: distro, sealed: sealed, stamp: stamp) ?? 0 },
            offline: { [weak self] distro, random, back in
                guard let self else { return }
                let d = distro.hexString
                self.queue.async { self.heardOfflineAddress(d, random: random, back: back) }
            },
            lookup: { [weak self] distro, randoms in
                guard let self else { return }
                let d = distro.hexString
                self.queue.async { self.heardLookup(d, randoms: randoms) }
            }) {
            say("offline use of the distro address not registered: \(DistroMessageFFI.rnsLastError())")
        }
        if !bridge.interfaceEdgesRegister(handler: { [weak self] in
            guard let self else { return }
            self.queue.async { self.interfacesChanged() }
        }) {
            say("interface edges not registered: \(DistroMessageFFI.rnsLastError())")
        }
        if rfedNode.count == 32 {
            RfedLink.shared.setStatusListener(nodeHex: rfedNode, owner: "distro-offline") { [weak self] status in
                guard let self else { return }
                self.queue.async { self.onRfedStatus(status) }
            }
        }
        if distroWatch == nil {
            distroWatch = RfedDistroClient.shared.$distro.sink { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.evaluate("the distro held changed") }
            }
        }
    }

    /// The stack is stopping: nothing is told until the next start, and a copy that comes
    /// meanwhile is refused, said in the log.
    @MainActor
    func stop() {
        bridge.distroDirectUnregister()
        bridge.interfaceEdgesClear()
        queue.async { self.started = false }
    }

    /// The offline toggle (Settings, "Offline use"): turned on, the device goes offline when
    /// it next is; turned off while offline, it is back.
    func setEnabled(_ on: Bool) {
        UserPreferences.setDistroOfflineEnabled(on)
        queue.async { self.evaluate(on ? "the offline toggle was turned on" : "the offline toggle was turned off") }
    }

    // MARK: The device

    private func isMesh(_ name: String) -> Bool { DistroOfflineRules.isMesh(name, rnodeNames: rnodeNames) }

    private func interfacesChanged() {
        guard started else { return }
        let now = bridge.onlineInterfaces()
        let meshUp = now.filter { !online.contains($0) && isMesh($0) }
        online = now
        if !meshUp.isEmpty {
            // The sender: each distro is asked for once more, at its next send.
            asked.removeAll()
            heard.removeAll()
            for list in copies.values { for copy in list { copy.afterAsk = false } }
            // The device: offline, it announces on a mesh connection that comes up.
            if offline, let pair = held { announce(pair, on: meshUp, why: "the mesh connection \(meshUp.joined(separator: ", ")) came up") }
            // A device that holds no link to RFed (a slow route) tries RFed when a mesh
            // connection comes up, and decides from that attempt (§17.15).
            if UserPreferences.distroOfflineEnabled, rfedReached != true, let collect {
                Task { @MainActor in
                    let node = UserPreferences.shared.effectiveRfedNodeIdentityHash.lowercased()
                    if node.count == 32, RfedLink.shared.holdsNoLink(nodeHex: node) { collect("a mesh connection came up (§17.15)") }
                }
            }
        }
        evaluate("the interfaces changed")
    }

    private func onRfedStatus(_ status: UInt8) {
        guard let reached = DistroOfflineRules.reached(status), reached != rfedReached else { return }
        rfedReached = reached
        evaluate(reached ? "RFed was reached" : "the link to RFed failed or closed")
    }

    /// Offline or back, by what is known now.
    private func evaluate(_ why: String) {
        guard started else { return }
        let enabled = UserPreferences.distroOfflineEnabled
        let signing = DistroManager.shared.signing()
        if offline, let pair = held {
            let back: String?
            if !enabled { back = "the offline toggle was turned off" }
            else if rfedReached == true { back = "RFed was reached again" }
            else if pair.distroHex != signing?.info.deliveryHashHex { back = "the distro held changed" }
            else { back = nil }
            if let back { goBack(pair, why: back) }
        }
        if !offline, let signing,
           DistroOfflineRules.offline(enabled: enabled, holdsDistro: true, rfedReached: rfedReached, online: online, rnodeNames: rnodeNames) {
            goOffline(signing.info, handle: signing.handle, why: why)
        }
    }

    private func goOffline(_ distro: DistroInfo, handle: UInt64, why: String) {
        guard let random = UserPreferences.distroOfflineRandom(distroHex: distro.deliveryHashHex) else {
            say("offline (\(why)), but its random part could not be kept: no offline address is held (§17.15)")
            return
        }
        if rfedPropagation == nil {
            say("the RFed node's lxmf.propagation is not known: a message that comes direct cannot have its stamp checked, and is refused")
        }
        let dir = URL(fileURLWithPath: configDir).appendingPathComponent("distro-direct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ratchets = dir.appendingPathComponent("\(distro.deliveryHashHex)-\(random).ratchets").path
        siblings.removeAll()
        guard let address = bridge.distroDirectHold(distroHandle: handle, random: random, ratchetsPath: ratchets,
                                                    node: rfedPropagation, back: false, lookup: [random]) else {
            say("offline (\(why)), but the addresses could not be held: \(DistroMessageFFI.rnsLastError()) (§17.15)")
            return
        }
        let pair = HeldPair(distroHex: distro.deliveryHashHex, random: random, offline: address)
        held = pair
        offline = true
        say("offline (\(why)): the distro \(distro.deliveryHashHex.prefix(8)) is reached at \(address.hexString.prefix(8)) over the mesh (§17.15)")
        announce(pair, on: online.filter(isMesh), why: "it went offline")
    }

    private func goBack(_ pair: HeldPair, why: String) {
        offline = false
        siblings.removeAll()
        if !bridge.distroDirectSetAppData(offline: pair.offline, back: true, lookup: []) {
            say("back (\(why)), but the addresses' app_data was not set: \(DistroMessageFFI.rnsLastError())")
        }
        say("back (\(why)): the offline address says so once on each mesh connection (§17.15)")
        announce(pair, on: online.filter(isMesh), why: "it is back")
    }

    private func announce(_ pair: HeldPair, on interfaces: [String], why: String) {
        guard !interfaces.isEmpty else {
            say("\(why): no mesh connection is up, so nothing is announced now (§17.15)")
            return
        }
        let count = bridge.distroDirectAnnounce(offline: pair.offline, interfaces: interfaces)
        if count < 0 {
            say("\(why): the offline address was not announced: \(DistroMessageFFI.rnsLastError())")
        } else {
            say("\(why): the offline address \(pair.offline.hexString.prefix(8)) announced on \(count) mesh connection(s) (§17.15)")
        }
    }

    /// A copy that came to the offline address, on the stack's thread that waits for the answer:
    /// kept first, then answered.
    private func take(distro: Data, sealed: Data, stamp: Data) -> Int32 {
        let back = offline ? 0 : RetichatBridge.DistroDirect.back
        let kept = RfedDistroClient.takeDirect(sealed: sealed, stamp: stamp)
        say("a message came direct to the offline address of \(distro.hexString.prefix(8)): \(kept ? "held" : "not kept") (§17.15)")
        return (kept ? RetichatBridge.DistroDirect.held : 0) | back
    }

    // MARK: The sender

    /// A distro this device sends to: a contact it knows as one, or an address that announced
    /// it is one (§17.10).
    private func sendsTo(_ d: String) -> Bool {
        UserPreferences.isDistroContactKnown(d) || (Data(hexString: d).map { bridge.peerIsDistro(destHash: $0) } ?? false)
    }

    private func heardOfflineAddress(_ d: String, random: String, back: Bool) {
        guard started, DistroOfflineRules.isRandomPart(random) else { return }
        if d == DistroManager.shared.deliveryHashHex {
            // A sibling of this device's own distro: the lookup names those heard offline since it went offline.
            guard offline, let pair = held, random != pair.random else { return }
            let had = siblings.contains(random)
            if back { siblings.removeAll { $0 == random } } else if !had { siblings.append(random) }
            if had != siblings.contains(random),
               !bridge.distroDirectSetAppData(offline: pair.offline, back: false,
                                              lookup: DistroOfflineRules.lookup(own: pair.random, siblings: siblings)) {
                say("the lookup's answer was not updated: \(DistroMessageFFI.rnsLastError())")
            }
            return
        }
        guard sendsTo(d) else { return }
        if UserPreferences.keepDistroOfflineAddress(distroHex: d, random: random) {
            say("kept \(d.prefix(8))'s offline address \(random) (§17.15)")
        }
        heard.insert(d)
        if back {
            if live[d]?.remove(random) != nil { say("\(d.prefix(8))'s offline address \(random) says it is back: it is no longer sent to (§17.15)") }
            return
        }
        if live[d, default: []].insert(random).inserted { say("\(d.prefix(8))'s offline address \(random) is live (§17.15)") }
        sendKept(d, to: [random])
    }

    private func heardLookup(_ d: String, randoms: [String]) {
        guard started, d != DistroManager.shared.deliveryHashHex, sendsTo(d) else { return }
        heard.insert(d)
        let named = randoms.filter(DistroOfflineRules.isRandomPart)
        guard !named.isEmpty else { return }
        say("\(d.prefix(8))'s lookup names \(named.count) offline address(es) (§17.15)")
        for random in named {
            _ = UserPreferences.keepDistroOfflineAddress(distroHex: d, random: random)
            live[d, default: []].insert(random)
        }
        sendKept(d, to: named)
    }

    /// A message this device just sent to the distro `distro` through propagation (the
    /// outbound message `handle`, its row `messageId`), from the send's own queue: made into a
    /// copy for the distro's offline addresses off that queue (a stamp not made yet is mined
    /// here, the one the router would mine), then sent to each live one, asking first when it
    /// is time. Never throws.
    func sentToDistro(distro: Data, handle: UInt64, messageId: String) {
        let d = distro.hexString
        let bridge = bridge
        queue.async {
            guard self.started else { return }
            guard let node = self.propagationNode else {
                self.say("no propagation node is configured: the message to \(d.prefix(8)) has no copy for its offline devices (§17.15)")
                return
            }
            // Mining blocks: its own thread, never this queue's or the send's.
            DispatchQueue.global(qos: .utility).async {
                guard let copy = bridge.distroDirectCopy(handle: handle, node: node) else {
                    // Read on this thread, at once: the Rust error slot is thread-local.
                    let error = DistroMessageFFI.rnsLastError()
                    self.queue.async { self.say("the message to \(d.prefix(8)) has no copy for its offline devices: \(error) (§17.15)") }
                    return
                }
                var hash = [UInt8](repeating: 0, count: 32)
                let len = lxmf_message_hash(handle, &hash, 32)
                let msgHash = len > 0 ? Data(hash.prefix(Int(len))).hexString : ""
                self.queue.async {
                    self.fanOut(d, Copy(messageId: messageId, msgHash: msgHash, bytes: copy, handle: handle, afterAsk: false))
                }
            }
        }
    }

    private func fanOut(_ d: String, _ copy: Copy) {
        prune(d)
        let meshUp = online.filter(isMesh)
        let asks = DistroOfflineRules.asks(meshUp: !meshUp.isEmpty, askedSince: asked.contains(d), heardSince: heard.contains(d))
        if asks || asked.contains(d) { copy.afterAsk = true }
        copies[d, default: []].append(copy)
        if asks, let distro = Data(hexString: d) {
            asked.insert(d)
            let kept = Array(UserPreferences.distroOfflineKept(distroHex: d))
            let count = bridge.distroDirectAsk(distro: distro, randoms: kept, withLookup: true, interfaces: meshUp)
            if count < 0 {
                say("asking for \(d.prefix(8))'s offline devices failed: \(DistroMessageFFI.rnsLastError())")
            } else {
                say("asked for \(d.prefix(8))'s offline devices: \(count) path request(s) over \(meshUp.count) mesh connection(s) (§17.15)")
            }
        }
        let addresses = Array(live[d] ?? [])
        if !addresses.isEmpty { send(d, to: addresses, [copy]) }
    }

    /// Send each kept copy for `d` that `randoms` should have: still waiting to reach RFed, or
    /// sent after asking.
    private func sendKept(_ d: String, to randoms: [String]) {
        prune(d)
        let kept = (copies[d] ?? []).filter { $0.afterAsk || waiting($0) }
        if !kept.isEmpty { send(d, to: randoms, kept) }
    }

    /// Send `list` to each of `randoms` that has not had it; an address with no path is asked
    /// for once, over the mesh.
    private func send(_ d: String, to randoms: [String], _ list: [Copy]) {
        guard let distro = Data(hexString: d) else { return }
        var noPath: [String] = []
        for random in randoms {
            for copy in list where !copy.sentTo.contains(random) {
                let went = bridge.distroDirectSend(distro: distro, random: random, copy: copy.bytes) { [weak self] bits in
                    guard let self else { return }
                    self.queue.async { self.sent(d, random: random, copy: copy, outcome: bits) }
                }
                if went == 1 {
                    copy.sentTo.insert(random)
                    say("the message \(copy.msgHash.prefix(8)) went to \(d.prefix(8))'s offline address \(random) (§17.15)")
                } else if went == 0 {
                    noPath.append(random)
                    break
                } else {
                    say("the message \(copy.msgHash.prefix(8)) did not go to \(d.prefix(8))'s offline address \(random): \(DistroMessageFFI.rnsLastError())")
                }
            }
        }
        let meshUp = online.filter(isMesh)
        if !noPath.isEmpty && !meshUp.isEmpty {
            // Its answer makes the address live again, and the copies go then.
            _ = bridge.distroDirectAsk(distro: distro, randoms: noPath, withLookup: false, interfaces: meshUp)
            say("no path to \(d.prefix(8))'s offline address(es) \(noPath.joined(separator: ", ")): asked for one over the mesh (§17.15)")
        }
    }

    private func sent(_ d: String, random: String, copy: Copy, outcome: Int32) {
        let deliveredNow = outcome & RetichatBridge.DistroDirect.held != 0
        let back = outcome & RetichatBridge.DistroDirect.back != 0
        if deliveredNow {
            say("the message \(copy.msgHash.prefix(8)) reached \(d.prefix(8))'s offline address \(random)\(back ? ", which is back" : "") (§17.15)")
            delivered?(copy.messageId)
        } else {
            // Reported, never repeated (DESIGN_PRINCIPLES §3): the message still goes through RFed.
            say("the message \(copy.msgHash.prefix(8)) did not reach \(d.prefix(8))'s offline address \(random): not sent again, and it goes through RFed as before (§17.15)")
        }
        if !deliveredNow || back { live[d]?.remove(random) }
    }

    private func waiting(_ copy: Copy) -> Bool {
        DistroOfflineRules.waitingForRfed(Int(lxmf_message_state(copy.handle)))
    }

    /// Keep only the copies an address that becomes live could still need: waiting to reach
    /// RFed, or sent after asking.
    private func prune(_ d: String) {
        copies[d]?.removeAll { !$0.afterAsk && !waiting($0) }
        if copies[d]?.isEmpty == true { copies.removeValue(forKey: d) }
    }
}
