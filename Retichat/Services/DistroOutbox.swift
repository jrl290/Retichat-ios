//
//  DistroOutbox.swift
//  Retichat
//
//  What this device still owes its distro D: the messages it uploads for D
//  through the propagation node, each kept until the node proves it has it
//  (RFed-rust SPEC.md §17.12 "On the sending device", §17.11, "The phones'
//  outbox"). Mirrors Retichat-android service/DistroOutbox.kt, which mirrors
//  Retichat-js 90640bf (`lib/distro_outbox.js`, `lib/distro_upload.js`, and
//  `_oweDistro`, `_sendDistroOutbox`, `_unprovedSince`, `_distroAttemptOpen`,
//  `_uploadOwed`, `_stillOwed`, `_dropMembershipOwedToOtherDistros` in
//  `app.js`). Pure logic, Foundation only, no FFI: the store, the propagation
//  link and the clock are ports, so tests/DistroOutboxTests.swift drives it with
//  fake link and upload events (DESIGN_PRINCIPLES.md §10).
//
//  Two kinds are owed: the §17.12 membership message C, the newest action per
//  channel only (a later join or leave of the channel replaces the one still
//  owed: its id is the channel's), and the §17.11 sent copy of a message sent as
//  D, one per message. Each entry is the LXMF message exactly as D packed and
//  signed it when the user acted, never packed again, so every upload of it is
//  one and the same message and a sibling that gets it twice holds the second
//  as a repeat.
//
//  An entry is written before anything can yield. It is uploaded at once when
//  the propagation link is up, and otherwise when the link next comes up. It
//  leaves only when the node proves the upload. An upload that is not proved
//  (its packet reported lost, its Resource failed, the connection stopped) is
//  uploaded again when the propagation link next comes up. That second upload is
//  a send retry, which DESIGN_PRINCIPLES §3 forbids, allowed here only by the
//  exception James decided on 2026-10-03 ("what a device owes its distro") and
//  for these two messages alone. His rulings of that day, and of 2026-10-04:
//
//   - The link comes up when a new propagation link is established
//     (`onLinkEstablished`), or when a STALE link recovers because the node is
//     heard from on it again (`onLinkRecovered`).
//   - An upload is never sent again on the strength of its own failure alone: a
//     failure waits for the next coming-up, even when a flush is already running
//     on the link that is up (`unproved`, `propComingUps`).
//   - A STALE link replaced by a new one decides nothing: the node may still
//     prove the upload over it. When that upload is then decided not proved
//     while a newer propagation link is up, that decision is the event and the
//     entry goes once on the newer link at once (`uploadOwed`). On the phones the
//     decision is the upload's own loss: the packet receipt's timeout (LXMF
//     `__link_packet_timed_out`, which also tears the link down, so the close
//     that follows is the same event) or the Resource's failure. A failure of
//     that upload on the newer link waits for the next coming-up like any other.
//   - When the device forgets or replaces its distro, the membership messages it
//     owed that distro are dropped. Its sent copies are still owed, and still
//     uploaded to that distro, the same bytes.
//
//  At most one upload of an entry is in flight at a time: while one has left and
//  is not decided, no flush uploads it, on its link or on a newer one.
//
//  Every event runs to completion before the next one begins (an actor: the
//  Swift counterpart of the distro-outbox thread Android runs them on); the only
//  suspensions are the store's writes and building an upload (its stamp can take
//  a while), after which an entry is checked again. No timer, no retry loop
//  (DESIGN_PRINCIPLES §3, §5).
//

import Foundation

// MARK: - Values

nonisolated enum OwedKind: String, Sendable {
    case channel
    case sent
}

/// One thing owed. `id` is `channel:<channel hash>` or `sent:<LXMF message
/// hash>`; `msgHash` is the LXMF message hash of `packed`, which is what tells
/// one message from another under the same id. `distro` is D's `lxmf.delivery`
/// hash and `distroKey` D's public key (hex), so a sent copy is still encrypted
/// to its own distro after the device gives that distro up. A channel entry adds
/// `op`, `name` and `atMs`; a sent entry `toHex`.
nonisolated struct OwedEntry: Equatable, Sendable, CustomStringConvertible {
    let id: String
    let kind: OwedKind
    let distro: String
    let distroKey: String
    let msgHash: String
    let packed: Data
    let label: String
    var op: String? = nil
    var name: String? = nil
    var atMs: Int64? = nil
    var toHex: String? = nil

    /// The same message, as packed (not another action under the same id).
    func sameMessage(_ other: OwedEntry?) -> Bool {
        guard let other else { return false }
        return id == other.id && msgHash == other.msgHash
    }

    static func == (a: OwedEntry, b: OwedEntry) -> Bool { a.sameMessage(b) && a.distro == b.distro }

    var description: String { "OwedEntry(\(id), \(label))" }
}

/// The distro this device holds: its `lxmf.delivery` hash and public key (hex).
nonisolated struct HeldDistro: Equatable, Sendable {
    let delivery: String
    let publicKey: String
}

/// The propagation link the stack holds: its id (hex) and whether it is ACTIVE.
nonisolated struct HeldLink: Equatable, Sendable {
    let id: String
    let active: Bool
}

/// An upload that left: the link (hex) it went on, and whether it is a Resource.
nonisolated struct UploadLeft: Equatable, Sendable {
    let linkId: String
    let resource: Bool
}

// MARK: - Ports

/// Where an upload's outcome is reported. Called from whatever thread the stack
/// decides it on: each only hands the event to the outbox, which runs it in its
/// turn.
nonisolated protocol UploadSink: AnyObject, Sendable {
    /// The node proved the packet, or the Resource completed.
    func proved()

    /// The packet's receipt timed out, or the Resource failed: it will not be proved.
    func lost()
}

/// Where owed entries are kept across a restart (SwiftData).
nonisolated protocol OutboxStore: Sendable {
    nonisolated(nonsending) func loadAll() async -> [OwedEntry]

    /// Keep `entry`, replacing the one under its id. False when storage refused it.
    nonisolated(nonsending) func put(_ entry: OwedEntry) async -> Bool

    /// The message `msgHash` under `id` is owed no more; a later one under the same id stays.
    nonisolated(nonsending) func remove(id: String, msgHash: String) async

    /// Whatever is under `id`: a replaced message when the write of its replacement was refused.
    nonisolated(nonsending) func removeId(_ id: String) async throws
}

/// The propagation link and the uploads on it (the C bridge).
nonisolated protocol PropagationPort: Sendable {
    /// The link held for the propagation node as it is now, or nil. A read, never a wait.
    func held() -> HeldLink?

    /// Build the propagation upload of `entry`: its packed message encrypted to
    /// `OwedEntry.distroKey` and no other key, stamped for the node. Suspends
    /// while the stamp is mined; throws when it cannot be built.
    nonisolated(nonsending) func build(_ entry: OwedEntry) async throws -> Data

    /// Hand `upload` to the held ACTIVE link. Nil when it did not leave (no
    /// active link, or it could not be queued): `sink` is then never called.
    /// Otherwise `sink` hears its proof or its loss, each at most once, and a
    /// proof can follow a loss. Synchronous: nothing may come between the
    /// outbox's last check that the link is up and the upload leaving.
    func upload(_ upload: Data, sink: UploadSink) throws -> UploadLeft?
}

nonisolated protocol OutboxLog: Sendable {
    func info(_ message: String)
    func warn(_ message: String)

    /// An error the client can show the user: an upload that failed while still
    /// owed, a write storage refused.
    func error(_ message: String)
}

// MARK: - Failure records

/// The messages owed to the distro whose last upload, or its build, was decided
/// not proved, each with the propagation link's coming-up it was decided at
/// (`DistroOutbox.propComingUps`). A flush taken at a coming-up no later than
/// that does not upload the message, and the next coming-up does: an upload is
/// never sent again on the strength of its own failure alone.
///
/// A record belongs to one message: the entry's id and the message packed under
/// it. One id (a channel's) may name several messages over time, a join and
/// then a leave, and the upload of each is decided on its own, in any order: the
/// older one's on the link it went on, which may close long after the newer
/// one's upload was reported lost. So recording, reading or forgetting one
/// message's record never replaces, reads or removes another's. What is recorded
/// is this process's alone (its coming-up counts start at zero): it lives in
/// memory, never in storage, and the first coming-up after a start sends
/// everything owed.
nonisolated final class UnprovedUploads {
    private var byId: [String: [String: Int64]] = [:]

    init() {}

    /// The upload of the message `entry` was decided not proved at coming-up `at`.
    func record(_ entry: OwedEntry, at: Int64) {
        byId[entry.id, default: [:]][entry.msgHash] = at
    }

    /// The coming-up the last failure of `entry` was decided at, or nil.
    func at(_ entry: OwedEntry) -> Int64? { byId[entry.id]?[entry.msgHash] }

    /// Whether the last failure of `entry` was decided at coming-up `comingUp` or later.
    func since(_ entry: OwedEntry, comingUp: Int64) -> Bool {
        guard let at = at(entry) else { return false }
        return at >= comingUp
    }

    /// `entry` is owed no more (proved, replaced by a later action, dropped with
    /// its distro): its record goes, and only its own.
    func forget(_ entry: OwedEntry) {
        guard var messages = byId[entry.id] else { return }
        guard messages.removeValue(forKey: entry.msgHash) != nil else { return }
        if messages.isEmpty { byId.removeValue(forKey: entry.id) } else { byId[entry.id] = messages }
    }

    var size: Int { byId.values.reduce(0) { $0 + $1.count } }
}

/// What the outbox has in flight, for a test to wait on: every task it spawned
/// and has not finished. A task parked on something the test holds (a stamp that
/// takes a while) counts until the test lets it go.
nonisolated final class OutboxActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0

    func begin() { lock.lock(); running += 1; lock.unlock() }
    func end() { lock.lock(); running -= 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return running }
}

nonisolated func describeOutboxError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
}

// MARK: - The outbox

actor DistroOutbox {
    /// DESIGN_PRINCIPLES §1: the longest the propagation node may take to prove an upload packet.
    nonisolated static let proofLiveMs: Int64 = 5_000

    private enum Settled { case proved, lost }

    /// One upload from its leaving until it is decided: the web's `DistroUploads.track`.
    /// Only the outbox's own executor touches it (the sinks pass it back to the outbox).
    private final class Upload: @unchecked Sendable {
        let label: String
        var linkId: String
        var how: String
        var leftAt: Int64?
        var settled: Settled?
        var lostWhy = ""
        var lateProof = false
        var onLateProof: (() -> Void)?
        /// Told in the task of the event that decides a loss: records the failure and notes a newer link.
        var onLost: (() -> Void)?
        var onOutcomeProved: (() -> Void)?
        var onOutcomeLost: ((String) -> Void)?

        init(label: String, linkId: String, how: String) {
            self.label = label
            self.linkId = linkId
            self.how = how
        }
    }

    /// An attempt at an entry, from its build until it is decided. The upload is
    /// weak: the outbox's `open` list holds it while it is undecided, which is all
    /// `distroAttemptOpen` asks, and the upload's own handlers hold the flight.
    private final class Flight: @unchecked Sendable {
        let linkId: String
        let msgHash: String
        weak var upload: Upload?

        init(linkId: String, msgHash: String) {
            self.linkId = linkId
            self.msgHash = msgHash
        }
    }

    /// The sink the stack is handed for one upload: each event is handed to the outbox.
    private final class ClosureSink: UploadSink, @unchecked Sendable {
        private let onProved: @Sendable () -> Void
        private let onLost: @Sendable () -> Void

        init(onProved: @escaping @Sendable () -> Void, onLost: @escaping @Sendable () -> Void) {
            self.onProved = onProved
            self.onLost = onLost
        }

        func proved() { onProved() }
        func lost() { onLost() }
    }

    private let store: OutboxStore
    private let port: PropagationPort
    private let heldDistro: @Sendable () -> HeldDistro?
    private let distroKnown: @Sendable () -> Bool
    private let log: OutboxLog
    private let now: @Sendable () -> Int64

    /// What is owed, oldest first: the mirror of what the store holds, which this
    /// outbox is the only writer of. An entry replaced under its id goes to the end.
    private var order: [String] = []
    private var entries: [String: OwedEntry] = [:]

    /// Entries whose write is still under way: a flush leaves them to their own `owe`.
    private var writing = Set<String>()

    /// id -> the attempt at that entry, whose upload (once it has left) is not yet decided.
    private var inFlight: [String: Flight] = [:]

    /// Every upload not yet decided, for `cut`.
    private var open: [Upload] = []

    /// How many times the propagation link has come up in this process: each
    /// established link and each STALE link's recovery (James, 2026-10-03: both
    /// are the link coming up). Each runs one flush of what the distro is owed,
    /// which takes the new value (`sendDistroOutbox`).
    private(set) var propComingUps: Int64 = 0

    /// The messages owed whose last upload (or its build) was decided not proved,
    /// with the coming-up it was at.
    private let unproved = UnprovedUploads()

    private var loaded = false
    private var stopped = false

    /// Tasks spawned and not finished, for a test to wait on.
    nonisolated let activity = OutboxActivity()

    /// `heldDistro` is the distro this device holds now, or nil. `distroKnown` says
    /// whether nil can be believed: false while the device cannot tell what it holds
    /// (iOS: the Keychain is not read yet, or cannot be before the first unlock), when
    /// no membership message may be dropped for "a distro this device does not hold".
    init(store: OutboxStore,
         port: PropagationPort,
         heldDistro: @escaping @Sendable () -> HeldDistro?,
         distroKnown: @escaping @Sendable () -> Bool = { true },
         log: OutboxLog,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.port = port
        self.heldDistro = heldDistro
        self.distroKnown = distroKnown
        self.log = log
        self.now = now
    }

    /// What is owed now, oldest first.
    func owed() -> [OwedEntry] { order.compactMap { entries[$0] } }

    /// The coming-up the last failure of `entry` was decided at (test and log reading).
    func unprovedAt(_ entry: OwedEntry) -> Int64? { unproved.at(entry) }

    /// How many failure records are held (one per message).
    func unprovedCount() -> Int { unproved.size }

    // MARK: Start and stop

    /// Load what a previous run left owed (the first start only) and begin to
    /// take events again (after a stop). Membership messages owed to a distro
    /// this device does not hold are dropped here, as on every change of the
    /// distro held (James, 2026-10-03).
    func start() async {
        if !loaded {
            loaded = true
            for entry in await store.loadAll() where entries[entry.id] == nil { set(entry) }
        }
        stopped = false
        dropMembershipOwedToOtherDistros()
    }

    /// The stack stopped: no proof can come for an upload still open, so each is
    /// decided not proved, and none is sent again by this (the stack is gone, and
    /// what is owed goes on the first link of the next start). A proof that comes
    /// all the same is a late proof.
    func onStop() {
        stopped = true
        _ = cut("the connection stopped")
    }

    // MARK: Owing

    /// Owe the distro `entry` (a §17.11 sent copy or a §17.12 membership message,
    /// packed and signed by D): written first, before anything can yield, then
    /// uploaded at once if the propagation link is up (on its own task: the user's
    /// action never waits for a stamp), and otherwise when the link next comes up.
    /// One already owed under its id (an earlier join or leave of the same
    /// channel) is replaced and never goes, even if its upload is being built. It
    /// is the user's own action, and reads no failure record: only the user's own
    /// send, join or leave calls it.
    func owe(_ entry: OwedEntry) async {
        // The message this one replaces is owed no more: its failure record, if
        // any, goes with it, and only its own.
        let replaced = entries[entry.id]
        if let replaced, !replaced.sameMessage(entry) { unproved.forget(replaced) }
        remove(entry.id)
        set(entry)
        let key = "\(entry.id)|\(entry.msgHash)"
        writing.insert(key)
        let kept = await store.put(entry)
        writing.remove(key)
        if !kept {
            // Storage refused it: this process holds it, and it goes when the
            // propagation link is up while it runs, but nothing keeps it past
            // that. The message it replaced is taken out of storage with a write
            // no larger than what storage holds, so a later run never sends an
            // action the user has since undone. Said, never silent.
            log.error("\(entry.label) could not be kept in storage: this device holds it, and it goes when the propagation link is up while the app runs; a restart loses it")
            if let replaced, !replaced.sameMessage(entry) {
                do {
                    try await store.removeId(entry.id)
                } catch {
                    log.error("Storage refuses even a smaller write: it still holds \(replaced.label), owed no more, which a later run would send")
                }
            }
        }
        // Replaced again, or proved, while the write ran: owed no more.
        guard entry.sameMessage(entries[entry.id]) else { return }
        if let held = port.held(), held.active {
            uploadOwedAtOnce(held.id, entry)
            return
        }
        log.info("\(entry.label) is owed to the distro: it goes when the propagation link is up (§17.11, §17.12)")
    }

    // MARK: The propagation link comes up

    /// A new propagation link `linkId` was established (James, 2026-10-03):
    /// upload on it what is owed, oldest first. Each call is one coming-up, and
    /// counts it: only this and `onLinkRecovered` start a flush, so a failed
    /// upload never goes again on its own failure.
    func onLinkEstablished(_ linkId: String) async { await sendDistroOutbox(linkId, trigger: "established") }

    /// A STALE propagation link `linkId` recovered because the node was heard
    /// from on it again (James, 2026-10-03): the link comes up, and what is owed
    /// goes on it. Only while it is still the propagation link: a STALE link that
    /// a new one has replaced is no longer the propagation link (it keeps only its
    /// grace for a late proof), so its recovery runs no flush and what is owed
    /// waits for the current link's next coming-up. This section's reading of the
    /// first and third rulings, not James's words.
    ///
    /// Ready and tested, and called from nowhere in the app: the shared crates do
    /// not say when a STALE link recovers (see DistroOutboxRuntime).
    func onLinkRecovered(_ linkId: String) async {
        guard port.held()?.id == linkId else { return }
        await sendDistroOutbox(linkId, trigger: "recovered")
    }

    /// Upload on `linkId`, oldest first, what is still owed to the distro
    /// (`trigger`: "established" or "recovered"). Each call is one coming-up and
    /// takes the new count. An entry is uploaded only when no attempt of it is
    /// open and its last failure, if any, came before this coming-up:
    ///  - one being built for this link is left to that build, and one whose
    ///    upload has left and is not yet decided, on this link or on one it
    ///    replaced, is left to its proof or to the event that decides it;
    ///  - one whose upload was decided not proved at this coming-up or later (the
    ///    user's own upload, made while this flush ran, lost while it built an
    ///    earlier entry; an upload on a newer link after an old one was lost; a
    ///    newer flush's) waits for the next coming-up.
    /// The uploads are built one after the other (a stamp yields), so each entry
    /// is checked again when its turn comes, and again once it is built
    /// (`uploadOwed`). Once the link has gone the rest wait for the next one.
    private func sendDistroOutbox(_ linkId: String, trigger: String) async {
        propComingUps += 1
        let comingUp = propComingUps
        dropMembershipOwedToOtherDistros()
        let owedNow = order.compactMap { entries[$0] }.filter { !writing.contains("\($0.id)|\($0.msgHash)") }
        if owedNow.isEmpty { return }
        log.info("Propagation link \(trigger): \(owedNow.count) upload(s) owed to the distro (§17.11, §17.12)")
        for entry in owedNow {
            if !linkUp(linkId) {
                log.info("Propagation link gone mid-flush: what the distro is still owed waits for the next one")
                return
            }
            // Read when the flush began, and every build before this one
            // yielded: a later action on the channel may have replaced it, an
            // upload made meanwhile been proved, or the distro changed.
            if !stillOwed(entry) { continue }
            if distroAttemptOpen(entry, linkId) { continue }
            if unprovedSince(entry, comingUp) {
                log.info("\(entry.label) was not proved since this flush began: it waits for the propagation link's next coming-up (DESIGN_PRINCIPLES §3, the distro exception)")
                continue
            }
            await uploadOwed(linkId, entry, comingUp: comingUp)
        }
    }

    private func linkUp(_ linkId: String) -> Bool {
        guard let held = port.held() else { return false }
        return held.id == linkId && held.active
    }

    /// Whether an attempt at the owed `entry` is open for a flush on `linkId`:
    /// being built for that link, or uploaded on any link and not yet decided. A
    /// build for another link never leaves (`uploadFor`), so it holds nothing back.
    private func distroAttemptOpen(_ entry: OwedEntry, _ linkId: String) -> Bool {
        guard let flight = inFlight[entry.id] else { return false }
        guard flight.msgHash == entry.msgHash else { return false }
        if flight.linkId == linkId { return true }
        if let upload = flight.upload, upload.settled == nil { return true }
        return false
    }

    /// Whether the last upload of the owed message `entry` (its build included)
    /// was decided not proved at coming-up `comingUp` or later: a flush taken at
    /// `comingUp` does not upload it, and the next coming-up does. Only that
    /// message's own record is read, never that of another action under the same id.
    private func unprovedSince(_ entry: OwedEntry, _ comingUp: Int64) -> Bool {
        unproved.since(entry, comingUp: comingUp)
    }

    // MARK: One upload

    /// The user's own action, and the third ruling's send: an upload on its own
    /// task, begun in this one. Its in-flight record is made now, before any
    /// other event can run (the Kotlin UNDISPATCHED start, a JS async call): an
    /// attempt open for `linkId`, which a flush on that link leaves alone.
    private func uploadOwedAtOnce(_ linkId: String, _ entry: OwedEntry) {
        let flight = Flight(linkId: linkId, msgHash: entry.msgHash)
        inFlight[entry.id] = flight
        spawn { await self.uploadOwed(linkId, entry, comingUp: nil, flight: flight) }
    }

    /// Upload the owed `entry` on `linkId`: build its propagation upload (it is
    /// encrypted to the entry's distro and stamped for the node anew each time;
    /// the LXMF message inside is the one packed when the user acted) and hand it
    /// to the link. `comingUp` is the flush's coming-up when a flush uploads it
    /// (`sendDistroOutbox`), nil for the user's own action and for a replaced
    /// link's decision. Returns once it has left, or could not leave; never
    /// throws. Its proof makes it owed no more. If it is not proved, or its build
    /// fails, that is recorded with the coming-up it was decided at (`unproved`),
    /// and it is uploaded again on the propagation link's next coming-up, never on
    /// the failure alone. One exception, also James's: an upload on a STALE link
    /// that a newer propagation link replaced, decided not proved while the newer
    /// link is up, goes once on the newer link at once: that decision is the
    /// event. A failure of that upload is like any other. Each outcome is said
    /// (`distroOwedOutcome`).
    ///
    /// Its callers are three and no other: the coming-up pass
    /// (`sendDistroOutbox`), the user's own action (`owe`) and that send on a
    /// replaced link's decision, below. Called without a coming-up it reads no
    /// failure record, so any other caller would send an upload again on its own
    /// failure (tests/DistroOutboxTests.swift pins them).
    private func uploadOwed(_ linkId: String, _ entry: OwedEntry, comingUp: Int64?, flight preMade: Flight? = nil) async {
        let flight = preMade ?? Flight(linkId: linkId, msgHash: entry.msgHash)
        inFlight[entry.id] = flight
        func landed() {
            if inFlight[entry.id] === flight { inFlight.removeValue(forKey: entry.id) }
        }
        // A failure is recorded when it is decided, with the coming-up it was
        // decided at: a flush begun after it, in the same task, takes it. That is
        // the coming-up current then, never the one of the flush that made this
        // upload: a later flush, under way on the same link when the failure is
        // decided, must leave it for the next coming-up. It is this message's
        // record, and only while this message is the one owed under its id: a
        // decision about it never replaces or clears the record of another action
        // on the channel.
        func recordUnproved() {
            if entries[entry.id]?.msgHash == entry.msgHash { unproved.record(entry, at: propComingUps) }
        }
        // Proved (late, too): owed no more, its record goes, and only its own.
        func forgetUnproved() { unproved.forget(entry) }

        let upload: Upload?
        do {
            let bytes = try await port.build(entry)
            // Building it yielded: a later action on the same channel may have
            // replaced it meanwhile, or another upload of it been proved, or the
            // distro changed. Then it is not sent.
            if !stillOwed(entry) {
                landed()
                log.info("\(entry.label) was replaced by a later action, proved, or left behind by a change of distro while it was built: not sent")
                return
            }
            // Nor is it sent by a flush when an upload of it was decided not
            // proved since that flush's coming-up: that waits for the next.
            if let comingUp, unprovedSince(entry, comingUp) {
                landed()
                log.info("\(entry.label) was not proved since this flush began: built, not sent; it waits for the propagation link's next coming-up")
                return
            }
            upload = try uploadFor(linkId, bytes, entry.label)
        } catch {
            // A build that throws is a failure: said, recorded as an upload decided
            // not proved, so no send pass already under way builds it again.
            landed()
            recordUnproved()
            distroOwedOutcome(entry, how: nil, error: describeOutboxError(error))
            return
        }
        guard let upload else {
            // Building the upload (its stamp) yields, and can take seconds: the
            // link went down meanwhile. Nothing left, so nothing is decided: it
            // stays owed and goes when the link is next up.
            landed()
            log.info("The propagation link went down while \(entry.label) was built: nothing left, and it goes when the link is next up")
            return
        }
        // It left: until it is decided, no flush uploads this entry again, on this
        // link or on one that replaces it.
        flight.upload = upload
        // Told in the task of the event that decides it (the loss, the stop),
        // before anything else runs: its failure is recorded then, and so is the
        // newer propagation link that had replaced its link while STALE, if any.
        // If that link is up and still the propagation link once the decision is
        // made, this decision is the event, and the entry goes once on it. On the
        // current link, or with no newer link up, it waits for the next coming-up.
        var goesOn: String? = nil
        upload.onLost = { [unowned upload] in
            recordUnproved()
            let newer = self.port.held()?.id
            if let newer, upload.linkId != newer { goesOn = newer }
        }
        upload.onOutcomeProved = { [unowned upload] in
            landed()
            forgetUnproved()
            self.settle(entry)
            self.distroOwedOutcome(entry, how: upload.how, error: nil)
        }
        upload.onOutcomeLost = { [unowned upload] why in
            landed()
            let newer = goesOn
            let held = self.port.held()
            if let newer, !self.stopped, let held, held.id == newer, held.active,
               self.stillOwed(entry), !self.distroAttemptOpen(entry, newer) {
                self.distroOwedOutcome(entry, how: upload.how, error: why, goesNow: true)
                self.uploadOwedAtOnce(newer, entry)
            } else {
                self.distroOwedOutcome(entry, how: upload.how, error: why)
            }
        }
        // A proof after the upload was reported lost (the node had the packet
        // after all) is the truth all the same: the node has it, so it is owed
        // no more, and is not sent again.
        upload.onLateProof = { [unowned upload] in
            forgetUnproved()
            self.settle(entry)
            self.distroOwedOutcome(entry, how: upload.how, error: nil)
        }
        // Decided before the handlers were set (a synchronous sink): the same
        // handlers run for it now.
        switch upload.settled {
        case .lost:
            upload.onLost?()
            upload.onOutcomeLost?(upload.lostWhy)
        case .proved:
            upload.onOutcomeProved?()
        case nil:
            break
        }
    }

    /// Hand `bytes` to the propagation link `linkId`, never started here. Nil
    /// when `linkId` is no longer the propagation link or no longer up: nothing
    /// left. Otherwise the upload, decided by the node's proof or by its loss. A
    /// packet's proof has a §1 watch: a proof later than 5 s is logged as the
    /// violation it is, and it settles the entry all the same.
    private func uploadFor(_ linkId: String, _ bytes: Data, _ label: String) throws -> Upload? {
        guard linkUp(linkId) else { return nil }
        let upload = Upload(label: label, linkId: linkId, how: "packet")
        let sink = ClosureSink(
            onProved: { self.spawn { await self.uploadProved(upload) } },
            onLost: { self.spawn { await self.uploadLost(upload) } })
        open.append(upload)
        let left: UploadLeft?
        do {
            left = try port.upload(bytes, sink: sink)
        } catch {
            open.removeAll { $0 === upload }
            throw error
        }
        guard let left else {
            open.removeAll { $0 === upload }
            return nil
        }
        upload.linkId = left.linkId
        upload.how = left.resource ? "resource" : "packet"
        // Its proof has its own §1 watch for a Resource (its progress is watched
        // in the stack); a packet's clock starts when it has left.
        if !left.resource && upload.settled == nil { upload.leftAt = now() }
        return upload
    }

    /// The node proved the packet of `upload`. True when this decided it.
    @discardableResult
    private func uploadProved(_ upload: Upload) -> Bool {
        let waited = upload.leftAt.map { now() - $0 } ?? 0
        if waited > Self.proofLiveMs {
            // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
            log.error("§1 VIOLATION: the propagation node proved \(upload.label) \(waited) ms after its upload (a late success is a failure)")
        }
        if upload.settled == .lost {
            log.warn("\(upload.label) was proved after all, after it was reported lost")
            if !upload.lateProof {
                upload.lateProof = true
                upload.onLateProof?()
            }
            return false
        }
        if upload.settled != nil { return false }
        upload.settled = .proved
        open.removeAll { $0 === upload }
        upload.onOutcomeProved?()
        return true
    }

    /// `upload` will never be proved: `why` (the stop says; the sink's loss does
    /// not, and what it says depends on what the upload is). True when this decided
    /// it; `onLost` is told first.
    @discardableResult
    private func uploadLost(_ upload: Upload, why: String? = nil) -> Bool {
        if upload.settled != nil { return false }
        let why = why ?? (upload.how == "resource"
            ? "its Resource failed"
            : "its packet was reported lost (the receipt timed out)")
        upload.settled = .lost
        upload.lostWhy = why
        open.removeAll { $0 === upload }
        upload.onLost?()
        upload.onOutcomeLost?(why)
        return true
    }

    /// The proof of every upload not yet decided can no longer come: `why`. Each is lost.
    private func cut(_ why: String) -> Int {
        var cut = 0
        for upload in open where uploadLost(upload, why: why) { cut += 1 }
        return cut
    }

    /// The upload of `entry` was proved: it is owed no more, and only that message.
    private func settle(_ entry: OwedEntry) {
        if entries[entry.id]?.msgHash == entry.msgHash { remove(entry.id) }
        persistRemoval(entry)
    }

    private func persistRemoval(_ entry: OwedEntry) {
        spawn { await self.store.remove(id: entry.id, msgHash: entry.msgHash) }
    }

    /// Whether `entry` is still owed as it is: the message owed under its id now
    /// (not replaced by a later action, not yet proved), and, for a membership
    /// message, owed to the distro this device holds now. A sent copy is owed to
    /// the distro it was made for whatever this device holds now (James,
    /// 2026-10-03). What a flush listed, or an upload was built from, may no
    /// longer be, since a build yields.
    private func stillOwed(_ entry: OwedEntry) -> Bool {
        if entries[entry.id]?.msgHash != entry.msgHash { return false }
        if entry.kind != .channel { return true }
        return heldDistro()?.delivery == entry.distro
    }

    // MARK: A distro given up

    /// James, 2026-10-03 (DESIGN_PRINCIPLES §3, what a device owes its distro):
    /// when this device forgets its distro D or replaces it, the membership
    /// messages it owed D are dropped, with a log line for each. One is never kept
    /// in case D comes back: it would go then, after changes the user made without
    /// D that no message reported (a leave of the same channel, say), and the
    /// siblings would join a channel the user had left. Nor is it ever sent under
    /// another distro. Its sent copies are not dropped: each is already packed and
    /// signed as D, with D's key in its entry, and is still uploaded to D, the same
    /// bytes, on later comings-up, never addressed to another distro or packed
    /// again. Runs on every change of the distro held (`onDistroChanged`), at
    /// `start`, and before each flush.
    ///
    /// The line says what is true: this device sends it no more. One whose upload
    /// has already left and is not decided cannot be taken back, and the line says
    /// that too, because the node may prove that upload and fan it out.
    func dropMembershipOwedToOtherDistros() {
        // Not on a guess: with the distro's state unknown (a Keychain that cannot be read yet),
        // "no distro held" is no finding, and what is owed stays until it is.
        guard distroKnown() else {
            log.info("The distro this device holds is not known yet: no membership message owed to a distro is dropped on it (§17.12)")
            return
        }
        let held = heldDistro()?.delivery
        let dropped = order.compactMap { entries[$0] }.filter { $0.kind == .channel && $0.distro != held }
        for entry in dropped {
            remove(entry.id)
            unproved.forget(entry)
            persistRemoval(entry)
            let flight = inFlight[entry.id]
            let onTheWire = flight?.msgHash == entry.msgHash && flight?.upload != nil && flight?.upload?.settled == nil
            log.warn(
                "\(entry.label) was owed to \(entry.distro.prefix(8)), a distro this device no longer holds — dropped: this device sends it no more"
                    + (onTheWire
                        ? "; one upload of it has already left on the propagation link and cannot be taken back: if the propagation node proves it, the distro's devices get it (§17.12)"
                        : " (§17.12)"))
        }
    }

    /// The distro this device holds changed (forgotten, generated or imported).
    func onDistroChanged() { dropMembershipOwedToOtherDistros() }

    // MARK: Saying how it ended

    /// Say how the upload of the owed `entry` ended: proved (`error` nil, sent as
    /// `how`, "packet" or "resource"), or not (`error`). The log says
    /// "propagated" only for a proof (CHECK_THESE_THINGS_FIRST §14), and an
    /// upload lost or cut while the entry is still owed is an error the client can
    /// show. It then goes on the propagation link's next coming-up, or, with
    /// `goesNow`, at once on a newer link that replaced the one it was on. One
    /// whose entry is owed no more by then (another upload of it was proved, a
    /// later action replaced it, or its membership message was dropped with its
    /// distro) failed no one: a log line says so, and neither "still owed" nor an
    /// error.
    private func distroOwedOutcome(_ entry: OwedEntry, how: String?, error: String?, goesNow: Bool = false) {
        if let error, !stillOwed(entry) {
            log.info("An upload of \(entry.label) was not proved (\(error)), but it is owed no more (proved by another upload, replaced by a later action, or dropped with its distro): nothing goes again")
            return
        }
        if let error {
            log.error(
                "\(entry.label) was not proved by the propagation node: \(error) — still owed: "
                    + (goesNow
                        ? "the propagation link it went on was replaced, and the newer one is up, so it goes once on that one now (DESIGN_PRINCIPLES §3, the distro exception)"
                        : "it goes when the propagation link is next up (DESIGN_PRINCIPLES §3, the distro exception)"))
            return
        }
        let how = how ?? "packet"
        if entry.kind == .channel {
            log.info("The \(entry.op ?? "?") of #\(entry.name ?? "?") (at \(entry.atMs.map(String.init) ?? "?")) propagated to the distro as a \(how): the propagation node proved it (§17.12)")
        } else {
            log.info("Sent-copy for \((entry.toHex ?? "").prefix(8)) propagated to the distro as a \(how): the propagation node proved it (§17.11)")
        }
    }

    // MARK: Order and tasks

    /// An entry replaced under its id goes to the end, as the web's outbox does.
    private func set(_ entry: OwedEntry) {
        order.removeAll { $0 == entry.id }
        order.append(entry.id)
        entries[entry.id] = entry
    }

    private func remove(_ id: String) {
        order.removeAll { $0 == id }
        entries.removeValue(forKey: id)
    }

    /// Run `work` as a task of this outbox, counted in `activity` until it ends.
    /// The sinks call it from the stack's threads.
    nonisolated func spawn(_ work: @escaping @Sendable () async -> Void) {
        activity.begin()
        let activity = activity
        Task {
            await work()
            activity.end()
        }
    }
}
