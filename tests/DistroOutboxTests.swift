// DistroOutboxTests.swift
//
// What a device owes its distro (RFed SPEC §17.12 "On the sending device",
// §17.11, "The phones' outbox"), driven with fake link and upload events: every
// ruling of James's of 2026-10-03 and 2026-10-04 as a case, and the tests the
// spec asks every client for ("Tests every client makes for the sending
// device"). A port of Retichat-android's DistroOutboxTest.kt: the same cases
// against the same logic, with a stamp that takes a while held by a gate. The
// mutation each guards is named where it is not obvious.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/distro-outbox \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/tests/DistroOutboxTests.swift && \
//     /private/tmp/claude-501/distro-outbox
//
// The outbox, its failure records and every ruling run for real, against
// fakes of the store and of the propagation link. The wiring needs the FFI and
// SwiftData: DistroOutboxWiringTests.swift asserts it on the source. Source
// pins at the end of this file say who may call what in the outbox: an owed
// upload goes again only when the propagation link comes up (DESIGN_PRINCIPLES
// §3, the distro exception), never on its own failure and never on a timer.

import Foundation

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func check(_ ok: Bool, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !ok {
        failures.append("\(currentTest): \(what)")
        print("FAIL: \(currentTest): \(what) (\(file):\(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

let d1 = HeldDistro(delivery: String(repeating: "d", count: 32), publicKey: String(repeating: "1", count: 128))
let d2 = HeldDistro(delivery: String(repeating: "e", count: 32), publicKey: String(repeating: "2", count: 128))

// MARK: - Fakes

/// A lock around a value, for fakes the outbox's executor and the test both touch.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// How many tasks are parked on a gate right now: the settle loop waits until
/// everything else has finished.
let parked = Locked(0)

/// A stamp that takes a while: the next build waits for `release()`.
final class Gate: @unchecked Sendable {
    private let state = Locked<(open: Bool, cont: CheckedContinuation<Void, Never>?)>((false, nil))

    nonisolated(nonsending) func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.with { s -> Bool in
                if s.open { return true }
                s.cont = c
                parked.with { $0 += 1 }
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func release() {
        let cont = state.with { s -> CheckedContinuation<Void, Never>? in
            s.open = true
            let c = s.cont
            s.cont = nil
            if c != nil { parked.with { $0 -= 1 } }
            return c
        }
        cont?.resume()
    }
}

/// What a later run loads: only what the store was given and not told to remove.
final class FakeStore: OutboxStore, @unchecked Sendable {
    let rows = Locked<[(id: String, entry: OwedEntry)]>([])
    let refuse = Locked(false)
    let refuseRemoval = Locked(false)

    struct Refused: Error {}

    var held: [OwedEntry] { rows.with { $0.map(\.entry) } }
    func has(_ id: String) -> Bool { rows.with { $0.contains { $0.id == id } } }

    nonisolated(nonsending) func loadAll() async -> [OwedEntry] { held }

    nonisolated(nonsending) func put(_ entry: OwedEntry) async -> Bool {
        if refuse.with({ $0 }) { return false }
        rows.with { r in
            r.removeAll { $0.id == entry.id }
            r.append((entry.id, entry))
        }
        return true
    }

    nonisolated(nonsending) func remove(id: String, msgHash: String) async {
        rows.with { r in r.removeAll { $0.id == id && $0.entry.msgHash == msgHash } }
    }

    nonisolated(nonsending) func removeId(_ id: String) async throws {
        if refuseRemoval.with({ $0 }) { throw Refused() }
        rows.with { r in r.removeAll { $0.id == id } }
    }
}

/// One upload that left, with the sink the stack would call.
struct Sent {
    let linkId: String
    let entryId: String
    let msgHash: String
    let key: String
    let sink: UploadSink
    func proved() { sink.proved() }
    func lost() { sink.lost() }
}

/// A sink that hears nothing: what `nth` hands back for an upload that never left.
final class NoSink: UploadSink, @unchecked Sendable {
    func proved() {}
    func lost() {}
}

/// The `i`th upload that left. One that did not is a failed check, not a crash that ends the run.
func nth(_ list: [Sent], _ i: Int) -> Sent {
    if i < list.count { return list[i] }
    check(false, "upload #\(i) was expected to have left, and only \(list.count) did")
    return Sent(linkId: "", entryId: "", msgHash: "", key: "", sink: NoSink())
}

struct TestError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FakePort: PropagationPort, @unchecked Sendable {
    private let state = Locked<(held: HeldLink?, resource: Bool, builds: [OwedEntry], sent: [Sent],
                                gates: [Gate], failNext: Error?)>((nil, false, [], [], [], nil))

    /// The link the stack holds for the propagation node now (what `held()` reads).
    var current: HeldLink? {
        get { state.with { $0.held } }
        set { state.with { $0.held = newValue } }
    }
    /// Uploads go as a Resource (over the link MDU) rather than one packet.
    var resource: Bool {
        get { state.with { $0.resource } }
        set { state.with { $0.resource = newValue } }
    }
    var builds: [OwedEntry] { state.with { $0.builds } }
    var sent: [Sent] { state.with { $0.sent } }

    /// The next build waits for the returned gate: a stamp that takes a while.
    func gateNextBuild() -> Gate {
        let gate = Gate()
        state.with { $0.gates.append(gate) }
        return gate
    }

    func failNextBuild(_ message: String) { state.with { $0.failNext = TestError(message: message) } }

    func held() -> HeldLink? { current }

    nonisolated(nonsending) func build(_ entry: OwedEntry) async throws -> Data {
        let gate = state.with { s -> Gate? in
            s.builds.append(entry)
            return s.gates.isEmpty ? nil : s.gates.removeFirst()
        }
        if let gate { await gate.wait() }
        if let error = state.with({ s -> Error? in let e = s.failNext; s.failNext = nil; return e }) { throw error }
        return Data("\(entry.id)|\(entry.msgHash)|\(entry.distroKey.prefix(4))".utf8)
    }

    func upload(_ upload: Data, sink: UploadSink) throws -> UploadLeft? {
        guard let link = current, link.active else { return nil }
        let parts = String(decoding: upload, as: UTF8.self).components(separatedBy: "|")
        state.with { $0.sent.append(Sent(linkId: link.id, entryId: parts[0], msgHash: parts[1], key: parts[2], sink: sink)) }
        return UploadLeft(linkId: link.id, resource: resource)
    }

    func uploads(of id: String) -> [Sent] { sent.filter { $0.entryId == id } }
}

final class Lines: OutboxLog, @unchecked Sendable {
    private let all = Locked<(info: [String], warn: [String], error: [String])>(([], [], []))
    var info: [String] { all.with { $0.info } }
    var warn: [String] { all.with { $0.warn } }
    var error: [String] { all.with { $0.error } }
    func info(_ message: String) { all.with { $0.info.append(message) } }
    func warn(_ message: String) { all.with { $0.warn.append(message) } }
    func error(_ message: String) { all.with { $0.error.append(message) } }
}

/// The outbox with fakes of everything around it. Everything the test launches
/// is counted with what the outbox spawns, so `settle` waits for all of it to
/// finish or park on a gate.
final class Rig: @unchecked Sendable {
    let store: FakeStore
    let port = FakePort()
    let lines = Lines()
    let clock = Locked<Int64>(1_000)
    let distro: Locked<HeldDistro?>
    /// Whether "no distro" can be believed (false: the Keychain cannot be read yet).
    let known: Locked<Bool>
    let activity = OutboxActivity()
    let outbox: DistroOutbox

    init(store: FakeStore = FakeStore(), distro: HeldDistro? = d1, known: Bool = true) {
        self.store = store
        self.distro = Locked(distro)
        self.known = Locked(known)
        let held = self.distro
        let known = self.known
        let clock = self.clock
        outbox = DistroOutbox(store: store, port: port, heldDistro: { held.with { $0 } },
                              distroKnown: { known.with { $0 } }, log: lines,
                              now: { clock.with { $0 } })
    }

    func setKnown(_ value: Bool) { known.with { $0 = value } }

    func link(_ id: String, active: Bool = true) { port.current = HeldLink(id: id, active: active) }

    func setDistro(_ d: HeldDistro?) { distro.with { $0 = d } }

    func advance(_ ms: Int64) { clock.with { $0 += ms } }

    /// A coroutine of the test: counted until it finishes.
    func launch(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        activity.begin()
        let activity = activity
        return Task {
            await work()
            activity.end()
        }
    }

    /// Run until everything is finished or parked on a gate (the Kotlin tests' `yield()`).
    /// Bounded, as a test failure mechanism only: never a path to success.
    func settle() async {
        var spins = 0
        while outbox.activity.count + activity.count > parked.with({ $0 }) {
            try? await Task.sleep(nanoseconds: 1_000_000)
            spins += 1
            if spins > 10_000 {
                check(false, "the outbox did not settle (\(outbox.activity.count) spawned, \(activity.count) launched, \(parked.with { $0 }) parked)")
                return
            }
        }
        // One more turn, so a task that finished while we looked has handed over.
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

func channel(_ op: String, _ name: String, _ hash: String, distro: HeldDistro = d1, at: Int64 = 1) -> OwedEntry {
    OwedEntry(id: DistroChannelSync.entryId("hash-of-\(name)"), kind: .channel,
              distro: distro.delivery, distroKey: distro.publicKey, msgHash: hash, packed: Data(hash.utf8),
              label: "the \(op) of #\(name) (§17.12)", op: op, name: name, atMs: at)
}

func sentCopy(_ hash: String, to: String = String(repeating: "c", count: 32), distro: HeldDistro = d1) -> OwedEntry {
    OwedEntry(id: "sent:\(hash)", kind: .sent, distro: distro.delivery, distroKey: distro.publicKey,
              msgHash: hash, packed: Data(hash.utf8), label: "the sent-copy for \(to.prefix(8)) (§17.11)", toHex: to)
}

func withRig(_ body: (Rig) async -> Void) async {
    let rig = Rig()
    await rig.outbox.start()
    await body(rig)
}

func ids(_ sent: [Sent]) -> [String] { sent.map(\.entryId) }
func links(_ sent: [Sent]) -> [String] { sent.map(\.linkId) }

// MARK: - owing

func anEntryIsKeptBeforeAnythingCanYieldAndWaitsForTheLinkWhenItIsNotUp() async {
    await withRig { rig in
        let join = channel("join", "public.x", "m1")
        await rig.outbox.owe(join)
        // Written, and nothing built or sent: the link is not up, and it is never started.
        checkEqual(rig.store.held, [join], "kept in storage")
        check(rig.port.builds.isEmpty, "nothing built")
        check(rig.lines.info.contains { $0.contains("owed to the distro") }, "said it waits")
        checkEqual(await rig.outbox.owed(), [join], "owed")
    }
}

func withTheLinkUpItGoesAtOnceAndOnlyTheNodesProofSettlesIt() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "m1")
        await rig.outbox.owe(join)
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "uploaded at once")
        // Sent is not proved: it is still owed, in storage too.
        checkEqual(await rig.outbox.owed(), [join], "still owed")
        check(rig.store.has(join.id), "still in storage")
        nth(rig.port.sent, 0).proved()
        await rig.settle()
        check(await rig.outbox.owed().isEmpty, "settled by the proof")
        check(rig.store.held.isEmpty, "storage lets it go too")
        check(rig.lines.info.contains { $0.contains("propagated to the distro as a packet") }, "said propagated")
        check(rig.lines.error.isEmpty, "no error")
    }
}

func theUsersOwnActionReadsNoFailureRecordAndIsNotHeldBackByAnEarlierFailure() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(sentCopy("a"))
        await rig.settle()
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        // A second message, owed after a failure of another, is the user's own action: it goes.
        await rig.outbox.owe(sentCopy("b"))
        await rig.settle()
        checkEqual(rig.port.sent.count, 2, "both went")
    }
}

// MARK: - what storage refuses

func storageThatRefusesAWriteLargerThanWhatItHoldsNeverKeepsAReplacedJoinForALaterRun() async {
    await withRig { rig in
        // Owe a join (kept), fill storage, owe a §17.11 sent copy (refused), then owe a
        // leave of the same channel (refused): what storage holds must not hold the join.
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        check(rig.store.has(join.id), "the join is kept")
        rig.store.refuse.with { $0 = true }
        await rig.outbox.owe(sentCopy("copy"))
        let leave = channel("leave", "public.x", "leave")
        await rig.outbox.owe(leave)
        check(!rig.store.has(join.id), "the replaced join is not left for a later run")
        // This run still holds what the user did last, and is told: never silent.
        checkEqual(Set(await rig.outbox.owed().map(\.id)), [sentCopy("copy").id, leave.id], "held in memory")
        checkEqual(rig.lines.error.filter { $0.contains("could not be kept in storage") }.count, 2, "said twice")
        // It still goes while the link is up in this run.
        rig.link("L1")
        await rig.outbox.onLinkEstablished("L1")
        await rig.settle()
        checkEqual(Set(ids(rig.port.sent)), [sentCopy("copy").id, leave.id], "both go")
        check(rig.port.sent.allSatisfy { $0.msgHash != "join" }, "the replaced join never goes")
    }
}

func storageThatRefusesEvenTheSmallerWriteIsSaid() async {
    await withRig { rig in
        await rig.outbox.owe(channel("join", "public.x", "join"))
        rig.store.refuse.with { $0 = true }
        rig.store.refuseRemoval.with { $0 = true }
        await rig.outbox.owe(channel("leave", "public.x", "leave"))
        check(rig.lines.error.contains { $0.contains("refuses even a smaller write") }, "said")
    }
}

// MARK: - a distro given up

func aMembershipMessageOwedToADistroGivenUpIsDroppedAndASentCopyKeepsItsOwnDistro() async {
    await withRig { rig in
        let join = channel("join", "public.x", "join")
        let copy = sentCopy("copy")
        await rig.outbox.owe(join)
        await rig.outbox.owe(copy)
        // Give up D (a log line says the join was dropped), import D again, bring the link up.
        rig.link("L0")
        await rig.outbox.onLinkEstablished("L0")
        await rig.settle()
        rig.port.sent.first { $0.entryId == join.id }?.lost()
        await rig.settle()
        check(await rig.outbox.unprovedAt(join) != nil, "the join's failure is recorded")
        rig.port.current = nil
        rig.setDistro(nil)
        await rig.outbox.onDistroChanged()
        await rig.settle()
        check(await rig.outbox.unprovedAt(join) == nil, "a record goes with the message it belongs to")
        check(rig.lines.warn.contains { $0.contains("no longer holds") && $0.contains("the join of #public.x") }, "said dropped")
        checkEqual(await rig.outbox.owed(), [copy], "the copy stays owed")
        check(!rig.store.has(join.id), "the join leaves storage")
        rig.setDistro(d1)
        rig.link("L1")
        await rig.outbox.onLinkEstablished("L1")
        await rig.settle()
        // The join is not uploaded again (mutation: keeping it while no distro is held uploads it, and
        // the sibling joins a channel this device left); the copy goes once.
        checkEqual(rig.port.sent.filter { $0.entryId == copy.id }.count, 1, "the copy goes once")
        checkEqual(rig.port.sent.filter { $0.entryId == join.id }.count, 1, "the join went only the once, before")
    }
}

/// iOS reads the distro's key from the Keychain, which cannot be read on a background launch before the
/// first unlock: then "no distro" is no finding, and nothing owed may be dropped on it.
func aDistroThatIsNotKnownYetDropsNothingAndOnceKnownDropsWhatIsOwedToAnother() async {
    let store = FakeStore()
    let first = Rig(store: store)
    await first.outbox.start()
    let join = channel("join", "public.x", "join")
    let copy = sentCopy("copy")
    await first.outbox.owe(join)
    await first.outbox.owe(copy)
    // The app starts again with the Keychain locked: the distro cannot be read, so it is not held and not known.
    let second = Rig(store: store, distro: nil, known: false)
    await second.outbox.start()
    checkEqual(await second.outbox.owed(), [join, copy], "nothing is dropped while the distro is not known")
    check(second.lines.warn.isEmpty && second.lines.info.contains { $0.contains("is not known yet") }, "and it says why")
    check(store.has(join.id), "the join stays in storage")
    await second.outbox.onDistroChanged()
    checkEqual(await second.outbox.owed(), [join, copy], "a change reported while it is not known drops nothing either")
    // The Keychain opens and holds the distro: what is owed to it stays.
    second.setDistro(d1)
    second.setKnown(true)
    await second.outbox.onDistroChanged()
    checkEqual(await second.outbox.owed(), [join, copy], "known and held: kept")
    // Known and given up: the join goes, the copy stays.
    second.setDistro(nil)
    await second.outbox.onDistroChanged()
    await second.settle()
    checkEqual(await second.outbox.owed(), [copy], "known and not held: the join is dropped, the copy stays")
    check(second.lines.warn.contains { $0.contains("no longer holds") }, "said")
}

func aSentCopyMadeUnderD1StillGoesToD1WhenTheDeviceHoldsD2() async {
    await withRig { rig in
        let old = sentCopy("old", distro: d1)
        await rig.outbox.owe(old)
        // Taking D2 drops no sent copy: it is already packed and signed as D1, with D1's key.
        rig.setDistro(d2)
        await rig.outbox.onDistroChanged()
        let fresh = sentCopy("fresh", distro: d2)
        await rig.outbox.owe(fresh)
        rig.link("L1")
        await rig.outbox.onLinkEstablished("L1")
        await rig.settle()
        // Each is built with its OWN distro's key (mutation: the key of the distro held now would
        // encrypt D1's copy to D2, which D1's devices cannot read).
        checkEqual(rig.port.sent.map(\.key), ["1111", "2222"], "the keys sent with")
        checkEqual(rig.port.builds.map(\.distroKey), [d1.publicKey, d2.publicKey], "the keys built with")
    }
}

func givingUpTheDistroWhileASentCopyIsBuiltStillUploadsItToItsOwnDistro() async {
    await withRig { rig in
        rig.link("L1")
        let gate = rig.port.gateNextBuild()
        await rig.outbox.owe(sentCopy("copy"))
        await rig.settle()
        rig.setDistro(nil)
        await rig.outbox.onDistroChanged()
        gate.release()
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "uploaded")
        checkEqual(rig.port.sent.first?.key ?? "", "1111", "to its own distro")
    }
}

func theLogLineSaysAnUploadAlreadyOnTheWireCannotBeTakenBack() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        rig.setDistro(nil)
        await rig.outbox.onDistroChanged()
        check(rig.lines.warn.count == 1 && rig.lines.warn[0].contains("already left"), "the line says it already left")
        // And its proof, if the node gives it, is said as any proof is.
        nth(rig.port.sent, 0).proved()
        await rig.settle()
        check(rig.lines.info.contains { $0.contains("propagated") }, "its proof is said")
    }
}

// MARK: - the app stops and starts

func whatIsOwedSurvivesARestartAndGoesOnceOnTheNextLink() async {
    let store = FakeStore()
    let first = Rig(store: store)
    await first.outbox.start()
    let join = channel("join", "public.x", "join")
    await first.outbox.owe(join)
    // The app stops before the link ever came up: a new process loads the store.
    let second = Rig(store: store)
    await second.outbox.start()
    checkEqual(await second.outbox.owed(), [join], "loaded")
    second.link("L1")
    await second.outbox.onLinkEstablished("L1")
    await second.settle()
    checkEqual(second.port.sent.count, 1, "uploaded once")
    nth(second.port.sent, 0).proved()
    await second.settle()
    check(store.held.isEmpty, "settled in storage")
}

func theStacksStopDecidesAnOpenUploadAndSendsNothingAndItGoesOnTheNextStart() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        // A newer link is up when the stop decides it: still nothing is sent.
        rig.link("L2")
        await rig.outbox.onStop()
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "nothing sent by the stop")
        checkEqual(await rig.outbox.owed(), [join], "still owed")
        check(rig.lines.error.contains { $0.contains("the connection stopped") }, "said")
        // Stopped, the next start's first link carries it, once.
        rig.link("L9")
        await rig.outbox.start()
        await rig.outbox.onLinkEstablished("L9")
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L9"], "once on the next start's link")
    }
}

// MARK: - an upload that is lost

func anUploadReportedLostIsSaidAndWaitsForTheNextComingUpThenGoesOnce() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        // Said: a log line and an error the client can show. It stays owed, and is not sent at the
        // failure itself (mutation: uploading it again at the failure sends it with no coming-up).
        check(rig.lines.error.contains { $0.contains("was not proved") && $0.contains("still owed") }, "said")
        checkEqual(await rig.outbox.owed(), [join], "still owed")
        checkEqual(rig.port.sent.count, 1, "not sent at the failure")
        // The next coming-up is the link's next establishment...
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L2"], "sent on the next establishment")
        // ...and it goes once.
        nth(rig.port.sent, 1).proved()
        await rig.settle()
        rig.link("L3")
        await rig.outbox.onLinkEstablished("L3")
        await rig.settle()
        checkEqual(rig.port.sent.count, 2, "once")
    }
}

func theNextComingUpMayBeAStaleLinksRecoveryOnTheSameLink() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        // The link recovers from STALE: it comes up. Mutation: no flush on the recovery leaves it
        // waiting for an establishment that may never come.
        await rig.outbox.onLinkRecovered("L1")
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L1"], "sent on the recovery")
    }
}

func aStaleLinkThatANewOneReplacedStartsNoFlushWhenItRecovers() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        rig.link("L2")
        // L1 is no longer the propagation link: its recovery sends nothing and counts nothing.
        let before = await rig.outbox.propComingUps
        await rig.outbox.onLinkRecovered("L1")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "nothing sent")
        checkEqual(await rig.outbox.propComingUps, before, "nothing counted")
        // L2's own coming-up carries it.
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L2"], "L2 carries it")
    }
}

func nothingButTheLinkComingUpStartsAFlush() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        // Not a distro change, not another action, not a start: a failed upload goes again only on a coming-up.
        await rig.outbox.onDistroChanged()
        await rig.outbox.start()
        await rig.outbox.owe(sentCopy("other"))
        await rig.settle()
        checkEqual(ids(rig.port.sent), ["channel:hash-of-public.x", "sent:other"], "only the new action went")
        checkEqual(rig.port.uploads(of: "channel:hash-of-public.x").count, 1, "the failed one did not go again")
    }
}

func aProofAfterTheLossReportSettlesItAndItDoesNotGoAgain() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        // The node had the packet after all.
        nth(rig.port.sent, 0).proved()
        await rig.settle()
        check(await rig.outbox.owed().isEmpty, "settled")
        check(rig.store.held.isEmpty, "settled in storage")
        check(rig.lines.warn.contains { $0.contains("proved after all") }, "said")
        // Mutation: ignoring the late proof uploads it again on the next link.
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "not again")
    }
}

func aProofLaterThanFiveSecondsIsLoggedAsAViolationAndSettlesAllTheSame() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(sentCopy("copy"))
        await rig.settle()
        rig.advance(7_000)
        nth(rig.port.sent, 0).proved()
        await rig.settle()
        check(rig.lines.error.contains { $0.contains("§1 VIOLATION") && $0.contains("7000 ms") }, "the violation is logged")
        check(await rig.outbox.owed().isEmpty, "settled all the same")
    }
}

func aBuildThatThrowsIsSaidKeptOwedAndGoesOnceOnTheNextComingUp() async {
    await withRig { rig in
        rig.link("L1")
        rig.port.failNextBuild("the stamp cannot be mined")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        check(rig.port.sent.isEmpty, "nothing left")
        check(rig.lines.error.contains { $0.contains("the stamp cannot be mined") && $0.contains("still owed") }, "said")
        checkEqual(await rig.outbox.owed(), [join], "still owed")
        // A flush under way that listed it does not build it again, and the link coming up does.
        await rig.outbox.onLinkEstablished("L1")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "goes on the coming-up")
    }
}

func anUploadWhoseBuildThrowsWhileAFlushThatListedItBuildsAnEarlierEntryIsNotBuiltAgainByThatFlush() async {
    await withRig { rig in
        let early = sentCopy("early")
        let x = channel("join", "public.x", "x")
        // Both owed with the link down.
        await rig.outbox.owe(early)
        await rig.outbox.owe(x)
        rig.link("L1")
        // The established flush lists early and x, and builds early (a stamp that takes a while).
        let gate = rig.port.gateNextBuild()
        let first = rig.launch { await rig.outbox.onLinkEstablished("L1") }
        await rig.settle()
        // A second coming-up (a recovery) lists them too: early is in flight, x is built, and its build throws.
        rig.port.failNextBuild("the key cannot be read")
        let second = rig.launch { await rig.outbox.onLinkRecovered("L1") }
        await rig.settle()
        await second.value
        check(rig.lines.error.contains { $0.contains("the key cannot be read") }, "said")
        checkEqual(rig.port.builds.filter { $0.id == x.id }.count, 1, "x built once")
        // The first flush reaches x: its failure was decided at this coming-up or later, so it is not built
        // again (mutation: a build failure left unrecorded is built again by the flush under way, with no
        // coming-up between).
        gate.release()
        await first.value
        checkEqual(rig.port.builds.filter { $0.id == x.id }.count, 1, "x not built again by the first flush")
        check(rig.port.sent.allSatisfy { $0.entryId != x.id }, "x not sent")
        // It goes once on the next coming-up.
        await rig.outbox.onLinkEstablished("L1")
        await rig.settle()
        checkEqual(rig.port.builds.filter { $0.id == x.id }.count, 2, "built on the next coming-up")
        checkEqual(rig.port.sent.filter { $0.entryId == x.id }.count, 1, "sent once")
    }
}

// MARK: - a STALE link replaced by a new one (the third ruling)

func aReplacedLinkDecidesNothingTheNewLinkDoesNotUploadWhileTheFirstUploadIsOpenAndTheLateProofSettlesIt() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "uploaded on L1")
        // L1 goes STALE and L2 replaces it: L2's coming-up must not upload the entry a second time
        // while the first upload is open (mutation: an in-flight check for the same link only).
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "not uploaded twice")
        // The node proves the upload over the old link: one upload, one stamp, one fan-out.
        nth(rig.port.sent, 0).proved()
        await rig.settle()
        check(await rig.outbox.owed().isEmpty, "settled")
        rig.link("L3")
        await rig.outbox.onLinkEstablished("L3")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "once")
    }
}

func theOldLinksUploadLostWhileANewerLinkIsUpGoesOnceOnTheNewerLinkAtOnce() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "L2 sent nothing")
        // The old link's upload is reported lost (the phones' receipt timeout, or a Resource's failure):
        // that is the event. Mutation: leaving it for the next coming-up while the newer link is up.
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L2"], "goes once on L2 at once")
        check(rig.lines.error.contains { $0.contains("goes once on that one now") }, "said")
        // A failure of that upload on the newer link waits for the next coming-up like any other.
        nth(rig.port.sent, 1).lost()
        await rig.settle()
        checkEqual(rig.port.sent.count, 2, "waits")
        rig.link("L3")
        await rig.outbox.onLinkEstablished("L3")
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L2", "L3"], "goes on the next coming-up")
    }
}

func withNoNewerLinkUpAnOldLinksLossWaitsForTheNextComingUp() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        // L1 was replaced by L2, which has not come up yet (still establishing).
        rig.link("L2", active: false)
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "not sent")
        // Not even built: a link that is not up is no event.
        checkEqual(rig.port.builds.count, 1, "not built")
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L2"], "goes on the coming-up")
    }
}

func aLateProofOverTheOldLinkAfterTheLossSentItOnTheNewLinkSettlesItAndTheNewUploadsLossSendsNothing() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        checkEqual(rig.port.sent.count, 2, "sent on L2")
        // The node then proves the first upload late: owed no more.
        nth(rig.port.sent, 0).proved()
        await rig.settle()
        check(await rig.outbox.owed().isEmpty, "settled")
        // The new link's upload is lost: nothing goes, now or on the next coming-up.
        nth(rig.port.sent, 1).lost()
        await rig.settle()
        rig.link("L3")
        await rig.outbox.onLinkEstablished("L3")
        await rig.settle()
        checkEqual(rig.port.sent.count, 2, "nothing more")
        // And if both uploads reached the node, the sibling holds the second as a repeat: the same message.
        checkEqual(nth(rig.port.sent, 0).msgHash, nth(rig.port.sent, 1).msgHash, "the same message")
    }
}

func aStopDecidesTheOldUploadWithANewerLinkUpAndSendsNothing() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.outbox.onStop()
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "nothing sent")
    }
}

// MARK: - flushes and the failure record

func twoFlushesOnOneLinkWithALossBetweenThemTheEarlierDoesNotUploadAgainWhatTheNewerSawLost() async {
    await withRig { rig in
        let y = sentCopy("y")
        let ch = channel("join", "public.x", "join")
        await rig.outbox.owe(y)
        await rig.outbox.owe(ch)
        rig.link("L1")
        // The established flush builds y (a stamp that takes a while); a recovered flush then runs
        // and uploads ch, whose packet is reported lost; then the first flush reaches ch.
        let gate = rig.port.gateNextBuild()
        let established = rig.launch { await rig.outbox.onLinkEstablished("L1") }
        await rig.settle()
        let recovered = rig.launch { await rig.outbox.onLinkRecovered("L1") }
        await rig.settle()
        await recovered.value
        // The recovered flush (coming-up 2) skipped y (in flight for the first flush) and uploaded ch.
        checkEqual(ids(rig.port.sent), [ch.id], "the recovered flush uploaded ch")
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        gate.release()
        await established.value
        await rig.settle()
        // The earlier flush uploaded y and did not upload ch again, though ch is owed and not in
        // flight: mutation, a flush that goes on after a newer one began uploads it with no coming-up.
        checkEqual(rig.port.sent.filter { $0.entryId == ch.id }.count, 1, "ch once")
        checkEqual(rig.port.sent.filter { $0.entryId == y.id }.count, 1, "y once")
    }
}

/// An entry y owed after a loss, then the user's own entry ch uploaded at once: the case of the first two tests below.
func yOwedAfterALossThenChUploaded(_ rig: Rig) async -> (OwedEntry, OwedEntry) {
    rig.link("L1")
    let y = sentCopy("y")
    await rig.outbox.owe(y)
    await rig.settle()
    rig.port.sent.first { $0.entryId == y.id }?.lost()
    await rig.settle()
    let ch = channel("join", "public.x", "join")
    await rig.outbox.owe(ch)
    await rig.settle()
    checkEqual(rig.port.sent.filter { $0.entryId == ch.id }.count, 1, "ch uploaded at once")
    return (y, ch)
}

func theUsersOwnUploadReportedLostWhileARecoveredFlushBuildsAnEarlierEntryIsNotUploadedByThatFlush() async {
    await withRig { rig in
        let (y, ch) = await yOwedAfterALossThenChUploaded(rig)
        // The link goes STALE and recovers: the recovered flush lists y and ch and builds y.
        let gate = rig.port.gateNextBuild()
        let flush = rig.launch { await rig.outbox.onLinkRecovered("L1") }
        await rig.settle()
        checkEqual(rig.port.builds.last?.id ?? "", y.id, "the flush builds y first")
        // ch's packet is reported lost while the flush builds y.
        rig.port.sent.first { $0.entryId == ch.id }?.lost()
        await rig.settle()
        gate.release()
        await flush.value
        await rig.settle()
        // Mutation: a flush that checks only that the entry is owed and not in flight uploads it at
        // once, with no coming-up after the failure (Retichat-js 145ca2f).
        checkEqual(rig.port.sent.filter { $0.entryId == ch.id }.count, 1, "ch not uploaded by the flush")
        checkEqual(rig.port.sent.filter { $0.entryId == y.id }.count, 2, "y uploaded by the flush")
        // Nor did the flush mine a stamp for it.
        checkEqual(rig.port.builds.filter { $0.id == ch.id }.count, 1, "no stamp for ch")
        // It goes once on the link's next coming-up, which may be on the same link.
        await rig.outbox.onLinkRecovered("L1")
        await rig.settle()
        checkEqual(rig.port.sent.filter { $0.entryId == ch.id }.count, 2, "ch on the next coming-up")
    }
}

func anUploadOnAReplacedLinkDecidedWhileTheNewLinksFlushBuildsAnEarlierEntryGoesOnceOnTheNewLinkAndItsFailureWaits() async {
    await withRig { rig in
        let (y, ch) = await yOwedAfterALossThenChUploaded(rig)
        // L1 goes STALE and L2 replaces it; L2's established flush lists y and ch, and builds y. ch is
        // open on L1 and so left alone.
        rig.link("L2")
        let gate = rig.port.gateNextBuild()
        let flush = rig.launch { await rig.outbox.onLinkEstablished("L2") }
        await rig.settle()
        checkEqual(rig.port.builds.last?.id ?? "", y.id, "the flush builds y")
        // L1's upload of ch is reported lost: the newer link is up, so it goes once on L2 at once (the third ruling).
        rig.port.sent.first { $0.entryId == ch.id && $0.linkId == "L1" }?.lost()
        await rig.settle()
        let onL2 = rig.port.sent.first { $0.entryId == ch.id && $0.linkId == "L2" }
        check(onL2 != nil, "ch went on L2 at once")
        // That upload is reported lost too, still while the flush builds y: a failure waits for the next coming-up.
        onL2?.lost()
        await rig.settle()
        gate.release()
        await flush.value
        await rig.settle()
        // Mutation: a flush that does not read when an upload failed uploads it a third time at once.
        checkEqual(rig.port.sent.filter { $0.entryId == ch.id }.count, 2, "ch twice, not three times")
        checkEqual(rig.port.builds.filter { $0.id == ch.id }.count, 2, "built for L1, and again for the send on L2, never a third time")
        rig.link("L3")
        await rig.outbox.onLinkEstablished("L3")
        await rig.settle()
        checkEqual(rig.port.sent.filter { $0.entryId == ch.id }.count, 3, "ch on the next coming-up")
    }
}

func anUploadAnEarlierFlushMadeReportedLostWhileALaterFlushOnTheSameLinkBuildsIsNotUploadedByIt() async {
    await withRig { rig in
        let y = sentCopy("y")
        let ch = channel("join", "public.x", "join")
        // y's upload is open on L1 (the user's own action) and ch is owed with no link up: [y, ch].
        rig.link("L1")
        await rig.outbox.owe(y)
        await rig.settle()
        let yUpload = nth(rig.port.sent, 0)
        rig.port.current = nil
        await rig.outbox.owe(ch)
        rig.link("L1")
        // The first flush (coming-up 1) leaves y to its open upload and uploads ch.
        await rig.outbox.onLinkEstablished("L1")
        await rig.settle()
        let chUpload = nth(rig.port.sent.filter { $0.entryId == ch.id }, 0)
        // y's upload is lost before the second flush starts; the second (coming-up 2) builds y.
        yUpload.lost()
        await rig.settle()
        let gate = rig.port.gateNextBuild()
        let second = rig.launch { await rig.outbox.onLinkRecovered("L1") }
        await rig.settle()
        checkEqual(rig.port.builds.last?.id ?? "", y.id, "the second flush builds y")
        // ch, made by the FIRST flush, is reported lost while the second builds y. The failure is
        // recorded at the coming-up current now (2), not the first flush's (1).
        chUpload.lost()
        await rig.settle()
        gate.release()
        await second.value
        await rig.settle()
        // Mutation: recording the failure at the coming-up of the flush that made the upload (1) lets the
        // second flush (2) upload it again at once.
        checkEqual(rig.port.sent.filter { $0.entryId == ch.id }.count, 1, "ch not again")
        checkEqual(rig.port.builds.filter { $0.id == ch.id }.count, 1, "no stamp for ch")
    }
}

// MARK: - two actions on one channel whose decisions overlap

/// The user joins CH and the join's upload stays open on L1; L2 replaces L1; the user leaves CH and the
/// leave goes at once on L2. An older entry `early` (owed after a loss) is listed before the leave. A
/// recovered flush on L2 builds `early`. Returns what the cases below decide in different orders.
final class Overlap {
    let rig: Rig
    let early = sentCopy("early")
    let join = channel("join", "public.x", "join")
    let leave = channel("leave", "public.x", "leave")
    var joinUpload: Sent!
    var leaveUpload: Sent!
    var flush: Task<Void, Never>!
    var gate: Gate!

    init(_ rig: Rig) { self.rig = rig }

    func setUp() async {
        rig.link("L1")
        await rig.outbox.owe(early)
        await rig.settle()
        rig.port.sent.first { $0.entryId == early.id }?.lost()
        await rig.settle()
        await rig.outbox.owe(join)
        await rig.settle()
        joinUpload = nth(rig.port.sent.filter { $0.entryId == join.id }, 0)
        rig.link("L2")
        await rig.outbox.owe(leave)
        await rig.settle()
        leaveUpload = nth(rig.port.sent.filter { $0.msgHash == "leave" }, 0)
        checkEqual(leaveUpload.linkId, "L2", "the leave goes at once on the newer link")
        // A coming-up's flush on L2 lists early, then the leave, and builds early.
        gate = rig.port.gateNextBuild()
        let rig = self.rig
        flush = rig.launch { await rig.outbox.onLinkRecovered("L2") }
        await rig.settle()
        checkEqual(rig.port.builds.last?.id ?? "", early.id, "the flush builds early")
    }

    func finish() async {
        gate.release()
        await flush.value
        await rig.settle()
        // The flush neither uploaded the leave nor mined a stamp for it.
        checkEqual(rig.port.sent.filter { $0.msgHash == "leave" }.count, 1, "the leave once")
        checkEqual(rig.port.builds.filter { $0.msgHash == "leave" }.count, 1, "one stamp for the leave")
        // It goes once on the next coming-up; the join, owed no more, never goes again.
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(rig.port.sent.filter { $0.msgHash == "leave" }.count, 2, "the leave on the next coming-up")
        checkEqual(rig.port.sent.filter { $0.msgHash == "join" }.count, 1, "the join never again")
    }
}

func aFailureBelongsToTheExactMessageTheJoinDecidedByItsLossAfterTheLeavesLossTakesNoRecordAndCostsTheLeaveNothing() async {
    let rig = Rig(); await rig.outbox.start()
    let o = Overlap(rig); await o.setUp()
    // The leave's upload is reported lost while the flush builds `early`: its record is written.
    o.leaveUpload.lost()
    await rig.settle()
    // Then the old link's loss decides the join, owed no more: it keeps no record, and takes no other's.
    o.joinUpload.lost()
    await rig.settle()
    check(await rig.outbox.unprovedAt(o.leave) != nil, "the leave's record stays")
    check(await rig.outbox.unprovedAt(o.join) == nil, "a message owed no more keeps no record")
    await o.finish()
}

func theJoinDecidedBeforeTheLeavesLossOrProvedLateAfterItChangesNothingForTheLeave() async {
    // Before: the join's loss, then the leave's.
    do {
        let rig = Rig(); await rig.outbox.start()
        let o = Overlap(rig); await o.setUp()
        o.joinUpload.lost(); await rig.settle()
        o.leaveUpload.lost(); await rig.settle()
        check(await rig.outbox.unprovedAt(o.join) == nil, "before: the join keeps no record")
        check(await rig.outbox.unprovedAt(o.leave) != nil, "before: the leave's record")
        await o.finish()
    }
    // Proved after: the leave's loss, then the join proved (late, over the old link).
    do {
        let rig = Rig(); await rig.outbox.start()
        let o = Overlap(rig); await o.setUp()
        o.leaveUpload.lost(); await rig.settle()
        o.joinUpload.proved(); await rig.settle()
        check(await rig.outbox.unprovedAt(o.leave) != nil, "proved after: the older action's proof does not clear the newer's record")
        await o.finish()
    }
    // Reported lost before the leave's loss and proved late after it.
    do {
        let rig = Rig(); await rig.outbox.start()
        let o = Overlap(rig); await o.setUp()
        o.joinUpload.lost(); await rig.settle()
        o.leaveUpload.lost(); await rig.settle()
        o.joinUpload.proved(); await rig.settle()
        check(await rig.outbox.unprovedAt(o.leave) != nil, "lost then proved: the leave's record stays")
        await o.finish()
    }
}

func aJoinReplacedByALeaveIsNeverBuiltByAFlushThatListedItAndTheLeaveKeepsItsRecord() async {
    let rig = Rig(); await rig.outbox.start()
    let early = sentCopy("early")
    let join = channel("join", "public.x", "join")
    let leave = channel("leave", "public.x", "leave")
    rig.link("L1")
    await rig.outbox.owe(early)
    await rig.settle()
    nth(rig.port.sent, 0).lost()
    await rig.settle()
    rig.port.current = nil
    await rig.outbox.owe(join)           // owed, link down
    rig.link("L1")
    let gate = rig.port.gateNextBuild()
    let flush = rig.launch { await rig.outbox.onLinkEstablished("L1") }  // lists [early, join], builds early (gated)
    await rig.settle()
    // The user leaves while that flush builds: the leave replaces the join, goes at once, and is lost.
    await rig.outbox.owe(leave)
    await rig.settle()
    rig.port.sent.first { $0.msgHash == "leave" }?.lost()
    await rig.settle()
    gate.release()
    await flush.value
    await rig.settle()
    // The flush listed the join; it was replaced, so it was never built or sent.
    check(rig.port.builds.allSatisfy { $0.msgHash != "join" }, "the join was never built")
    checkEqual(rig.port.sent.filter { $0.msgHash == "leave" }.count, 1, "the leave once")
    check(await rig.outbox.unprovedAt(join) == nil, "the join keeps no record")
    check(await rig.outbox.unprovedAt(leave) != nil, "the leave keeps its record")
}

func aReplacedJoinWhoseBuildThrowsAfterTheLeavesLossTakesNoRecordAndNothingFromTheLeave() async {
    let rig = Rig(); await rig.outbox.start()
    let early = sentCopy("early")
    let join = channel("join", "public.x", "join")
    let leave = channel("leave", "public.x", "leave")
    // early failed before; the join is owed with the link down.
    rig.link("L1")
    await rig.outbox.owe(early)
    await rig.settle()
    nth(rig.port.sent, 0).lost()
    await rig.settle()
    rig.port.current = nil
    await rig.outbox.owe(join)
    rig.link("L1")
    // A flush builds early, then the join; the join's build waits (a stamp) and will throw.
    let earlyGate = rig.port.gateNextBuild()
    let joinGate = rig.port.gateNextBuild()
    let flush = rig.launch { await rig.outbox.onLinkEstablished("L1") }
    await rig.settle()
    earlyGate.release()
    await rig.settle()
    checkEqual(rig.port.builds.last?.msgHash ?? "", join.msgHash, "the join is being built")
    // The user leaves meanwhile: the leave replaces the join and is lost on L1.
    await rig.outbox.owe(leave)
    await rig.settle()
    rig.port.sent.first { $0.msgHash == "leave" }?.lost()
    await rig.settle()
    check(await rig.outbox.unprovedAt(leave) != nil, "the leave's record")
    // Now the join's build throws: it is a failure, but of a message owed no more.
    rig.port.failNextBuild("the key cannot be read")
    joinGate.release()
    await flush.value
    await rig.settle()
    check(rig.lines.info.contains { $0.contains("owed no more") }, "said owed no more")
    check(await rig.outbox.unprovedAt(join) == nil, "a message owed no more keeps no record")
    check(await rig.outbox.unprovedAt(leave) != nil, "and takes none from the leave")
    checkEqual(rig.port.sent.filter { $0.msgHash == "leave" }.count, 1, "the leave once")
    await rig.outbox.onLinkEstablished("L1")
    await rig.settle()
    checkEqual(rig.port.sent.filter { $0.msgHash == "leave" }.count, 2, "the leave on the next coming-up")
    checkEqual(rig.port.sent.filter { $0.msgHash == "join" }.count, 0, "the join never")
}

func twoSentCopiesInPlaceOfAJoinAndALeaveTheOlderIsStillOwedAndGoesOnceOnTheNewerLinkAtOnce() async {
    await withRig { rig in
        let older = sentCopy("older")
        let newer = sentCopy("newer")
        rig.link("L1")
        await rig.outbox.owe(older)
        await rig.settle()
        rig.link("L2")
        await rig.outbox.owe(newer)
        await rig.settle()
        // The older copy's upload (open on the replaced L1) is lost while L2 is up: once on L2 at once.
        rig.port.sent.first { $0.entryId == older.id }?.lost()
        await rig.settle()
        checkEqual(links(rig.port.sent.filter { $0.entryId == older.id }), ["L1", "L2"], "the older copy goes on L2")
        checkEqual(rig.port.sent.filter { $0.entryId == newer.id }.count, 1, "the newer once")
    }
}

func theOlderActionsProofDoesNotClearTheNewerActionsFailureRecord() async {
    let rig = Rig(); await rig.outbox.start()
    rig.link("L1")
    let join = channel("join", "public.x", "join")
    await rig.outbox.owe(join)
    await rig.settle()
    let joinUpload = nth(rig.port.sent, 0)
    rig.link("L2")
    let leave = channel("leave", "public.x", "leave")
    await rig.outbox.owe(leave)
    await rig.settle()
    let leaveUpload = nth(rig.port.sent.filter { $0.msgHash == "leave" }, 0)
    leaveUpload.lost()
    await rig.settle()
    // The join, proved late over the old link, is owed no more and clears only its own record.
    joinUpload.proved()
    await rig.settle()
    check(await rig.outbox.unprovedAt(leave) != nil, "the leave's record stays")
    check(await rig.outbox.unprovedAt(join) == nil, "the join's is gone")
    checkEqual(await rig.outbox.owed(), [leave], "only the leave is owed")
}

func aReplacedActionsFailureRecordGoesWithIt() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        check(await rig.outbox.unprovedAt(join) != nil, "the join's failure is recorded")
        checkEqual(await rig.outbox.unprovedCount(), 1, "one record")
        // The user leaves: the join is owed no more, and so is its record.
        await rig.outbox.owe(channel("leave", "public.x", "leave"))
        check(await rig.outbox.unprovedAt(join) == nil, "the join's record went")
        checkEqual(await rig.outbox.unprovedCount(), 0, "no record")
    }
}

func aReplacedActionIsNeverSentEvenWhenItWasReplacedWhileItsUploadWasBeingBuilt() async {
    let rig = Rig(); await rig.outbox.start()
    rig.link("L1")
    let gate = rig.port.gateNextBuild()
    let join = channel("join", "public.x", "join")
    await rig.outbox.owe(join)
    await rig.settle()
    // The user leaves while the join's stamp is being mined.
    let leave = channel("leave", "public.x", "leave")
    await rig.outbox.owe(leave)
    await rig.settle()
    gate.release()
    await rig.settle()
    // Only the newest action goes: the siblings would otherwise make the change the user undid.
    checkEqual(rig.port.sent.map(\.msgHash), ["leave"], "only the leave")
    check(rig.lines.info.contains { $0.contains("was replaced by a later action") }, "said")
}

func atMostOneUploadOfAnEntryIsInFlightAtATime() async {
    await withRig { rig in
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        // Established again (a new coming-up) while the first upload is open: not uploaded again.
        await rig.outbox.onLinkEstablished("L1")
        await rig.outbox.onLinkRecovered("L1")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "once")
    }
}

func anOpenUploadOfAnOlderActionDoesNotHoldBackTheNewerActionOnTheSameChannel() async {
    await withRig { rig in
        rig.link("L1")
        let join = channel("join", "public.x", "join")
        await rig.outbox.owe(join)
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "the join is open on L1")
        // The user leaves while no link is up: the leave is owed, the join's upload is still open on L1.
        rig.port.current = nil
        let leave = channel("leave", "public.x", "leave")
        await rig.outbox.owe(leave)
        // L2 comes up: the leave goes. At most one upload is in flight per MESSAGE, not per channel.
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(rig.port.sent.map(\.msgHash), ["join", "leave"], "both")
        checkEqual(rig.port.sent.last?.linkId ?? "", "L2", "the leave on L2")
    }
}

func aFlushWhoseLinkGoesDownMidwayLeavesTheRestForTheNextOne() async {
    let rig = Rig(); await rig.outbox.start()
    await rig.outbox.owe(sentCopy("a"))
    await rig.outbox.owe(sentCopy("b"))
    rig.link("L1")
    let gate = rig.port.gateNextBuild()
    let flush = rig.launch { await rig.outbox.onLinkEstablished("L1") }
    await rig.settle()
    rig.port.current = nil
    gate.release()
    await flush.value
    await rig.settle()
    // The first was built for a link that is gone: nothing left, nothing decided. Nor the second.
    check(rig.port.sent.isEmpty, "nothing sent")
    checkEqual(await rig.outbox.owed().count, 2, "both still owed")
    check(rig.lines.error.isEmpty, "no error")
    rig.link("L2")
    await rig.outbox.onLinkEstablished("L2")
    await rig.settle()
    checkEqual(rig.port.sent.count, 2, "both on the next link")
}

// MARK: - the phones' event

func aResourcesFailureDecidesItLikeAPacketsTimeoutAndNeedsNoPacketProofClock() async {
    await withRig { rig in
        rig.port.resource = true
        rig.link("L1")
        await rig.outbox.owe(sentCopy("big"))
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "uploaded")
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        check(rig.lines.error.contains { $0.contains("was not proved") && $0.contains("its Resource failed") }, "said")
        checkEqual(await rig.outbox.owed().count, 1, "still owed")
        // Still owed, and not sent again at the failure; the next coming-up carries it.
        checkEqual(rig.port.sent.count, 1, "not sent again at the failure")
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L2"], "on the next coming-up")
        // A Resource's own progress has its own §1 watch in the stack, so a long transfer is no violation here.
        rig.advance(60_000)
        nth(rig.port.sent, 1).proved()
        await rig.settle()
        check(rig.lines.error.allSatisfy { !$0.contains("§1 VIOLATION") }, "no violation")
        check(rig.lines.info.contains { $0.contains("propagated to the distro as a resource") }, "said resource")
        check(await rig.outbox.owed().isEmpty, "settled")
    }
}

func aResourcesFailureOnAReplacedLinkWithANewerLinkUpGoesOnceOnTheNewerLinkAtOnce() async {
    await withRig { rig in
        rig.port.resource = true
        rig.link("L1")
        await rig.outbox.owe(channel("join", "public.x", "join"))
        await rig.settle()
        rig.link("L2")
        await rig.outbox.onLinkEstablished("L2")
        await rig.settle()
        checkEqual(rig.port.sent.count, 1, "L2 sent nothing")
        // James, 2026-10-04: a Resource upload's own "failed" is the same event as the loss report.
        nth(rig.port.sent, 0).lost()
        await rig.settle()
        checkEqual(links(rig.port.sent), ["L1", "L2"], "once on L2 at once")
    }
}

func anEntryOwedWhileTheLinkIsNotActiveBuildsNothingAndSaysNothingWentWrong() async {
    await withRig { rig in
        rig.link("L1", active: false)
        // Not ACTIVE when the user acts: it waits (and is never started).
        await rig.outbox.owe(sentCopy("copy"))
        await rig.settle()
        check(rig.port.builds.isEmpty, "nothing built")
        check(rig.lines.error.isEmpty, "no error")
    }
}

// MARK: - who may call what (DESIGN_PRINCIPLES §3, the distro exception)

let outboxSource = source("Retichat/Services/DistroOutbox.swift")

/// The file's code with comments and string contents taken out, so a mention is not a call.
let outboxCode: String = {
    var text = outboxSource
    // Block comments.
    while let start = text.range(of: "/*"), let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
        text.removeSubrange(start.lowerBound..<end.upperBound)
    }
    return text.components(separatedBy: "\n").map { line -> String in
        var out = ""
        var inString = false
        var previous: Character = " "
        for ch in line {
            if ch == "\"" && previous != "\\" { inString.toggle(); out.append(ch); previous = ch; continue }
            if inString { previous = ch; continue }
            out.append(ch)
            previous = ch
        }
        if let cut = out.range(of: "//") { return String(out[..<cut.lowerBound]) }
        return out
    }.joined(separator: "\n")
}()

/// The member of DistroOutbox (a `func` declared directly in its body) each call of `callee` sits
/// in; a local function, a closure or a nested type belongs to the member around it.
func callersOf(_ callee: String) -> [String] {
    var callers: [String] = []
    var depth = 0
    var member = "<outside>"
    var inClass = false
    for line in outboxCode.components(separatedBy: "\n") {
        if line.hasPrefix("actor DistroOutbox") { inClass = true; depth = 0 }
        var declares: String?
        if let range = line.range(of: #"\bfunc (\w+)"#, options: .regularExpression) {
            declares = String(line[range]).replacingOccurrences(of: "func ", with: "")
        }
        // A member is a func declared at depth 1 of the actor (not nested in a type or another func).
        if inClass && depth == 1, let declares { member = declares }
        let called = line.range(of: #"\b"# + callee + #"\("#, options: .regularExpression) != nil
        if inClass && member != "<outside>" && called && declares != callee { callers.append(member) }
        depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }
    return callers
}

func onlyTheLinkComingUpStartsAFlush() {
    // Established and recovered: the two comings-up James ruled on. Nothing else calls the flush.
    checkEqual(callersOf("sendDistroOutbox"), ["onLinkEstablished", "onLinkRecovered"], "callers of the flush")
}

func anOwedUploadIsMadeByThreePathsAndNoOther() {
    // The coming-up pass, which reads the failure record with its coming-up, and uploadOwedAtOnce,
    // which reads none: the user's own action (owe) and the third ruling's send (inside uploadOwed's
    // loss handler). Anything else calling either would send an upload again on its own failure.
    checkEqual(callersOf("uploadOwed"), ["sendDistroOutbox", "uploadOwedAtOnce"], "callers of uploadOwed")
    checkEqual(callersOf("uploadOwedAtOnce"), ["owe", "uploadOwed"], "callers of uploadOwedAtOnce")
    // The upload it makes has one caller too.
    checkEqual(callersOf("uploadFor"), ["uploadOwed"], "callers of uploadFor")
}

func theThirdRulingsSendIsTheLossOfAnUploadOnAnotherLinkAndNothingElse() {
    guard let from = outboxCode.range(of: "upload.onOutcomeLost = {"), let to = outboxCode.range(of: "upload.onLateProof =") else {
        check(false, "the loss handler is in the source")
        return
    }
    let lost = String(outboxCode[from.lowerBound..<to.lowerBound])
    checkEqual(lost.components(separatedBy: "uploadOwedAtOnce(").count - 1, 1, "one send in the loss handler")
    // Only with a newer link held and up, the entry still owed, no attempt open on it, and the stack running.
    for guardText in ["held.id == newer", "held.active", "stillOwed(entry)", "!self.distroAttemptOpen(entry, newer)", "!self.stopped"] {
        check(lost.contains(guardText), "the loss handler checks \(guardText)")
    }
    // The upload's own failure is recorded before anything is considered (in the task of the event).
    check(outboxCode.contains("upload.onLost = { [unowned upload] in\n            recordUnproved()"), "the failure is recorded first")
}

func anUploadIsDecidedOnlyByItsProofItsLossOrTheStacksStop() {
    // The proof and the loss reach it from the sink the stack is handed, and the stop through cut.
    checkEqual(callersOf("uploadProved"), ["uploadFor"], "callers of uploadProved")
    checkEqual(callersOf("uploadLost"), ["uploadFor", "cut"], "callers of uploadLost")
    checkEqual(callersOf("cut"), ["onStop"], "callers of cut")
}

func theOutboxStartsNoLinkAndWaitsOnNoClock() {
    // It never starts the propagation link: its port has held(), build() and upload(), no open or reopen.
    check(!outboxCode.contains("appLinkOpen"), "no appLinkOpen")
    check(!outboxCode.lowercased().contains("reopen"), "no reopen")
    for clock in ["Task.sleep", "sleep(", "Timer", "schedule", "asyncAfter", "DispatchQueue", "withTimeout", "Date()"] {
        // `Date()` is the default of the clock parameter, the one place the real clock is named.
        let allowed = clock == "Date()" ? 1 : 0
        checkEqual(outboxCode.components(separatedBy: clock).count - 1, allowed, "the outbox names no clock: \(clock)")
    }
    // The one clock it reads is `now`, for the §1 report of a proof that came late: never to send.
    checkEqual(outboxCode.components(separatedBy: "now()").count - 1, 2, "now() is read twice")
}

// MARK: - the mutation run: each case, in turn

let allTests: [(String, () async -> Void)] = [
    ("an entry is kept before anything can yield and waits for the link when it is not up", anEntryIsKeptBeforeAnythingCanYieldAndWaitsForTheLinkWhenItIsNotUp),
    ("with the link up it goes at once and only the node's proof settles it", withTheLinkUpItGoesAtOnceAndOnlyTheNodesProofSettlesIt),
    ("the user's own action reads no failure record", theUsersOwnActionReadsNoFailureRecordAndIsNotHeldBackByAnEarlierFailure),
    ("storage that refuses a larger write never keeps a replaced join for a later run", storageThatRefusesAWriteLargerThanWhatItHoldsNeverKeepsAReplacedJoinForALaterRun),
    ("storage that refuses even the smaller write is said", storageThatRefusesEvenTheSmallerWriteIsSaid),
    ("a membership message owed to a distro given up is dropped and a sent copy keeps its own distro", aMembershipMessageOwedToADistroGivenUpIsDroppedAndASentCopyKeepsItsOwnDistro),
    ("a distro that is not known yet drops nothing; once known it drops what is owed to another", aDistroThatIsNotKnownYetDropsNothingAndOnceKnownDropsWhatIsOwedToAnother),
    ("a sent copy made under D1 still goes to D1 when the device holds D2", aSentCopyMadeUnderD1StillGoesToD1WhenTheDeviceHoldsD2),
    ("giving up the distro while a sent copy is built still uploads it to its own distro", givingUpTheDistroWhileASentCopyIsBuiltStillUploadsItToItsOwnDistro),
    ("the log line says an upload already on the wire cannot be taken back", theLogLineSaysAnUploadAlreadyOnTheWireCannotBeTakenBack),
    ("what is owed survives a restart and goes once on the next link", whatIsOwedSurvivesARestartAndGoesOnceOnTheNextLink),
    ("the stack's stop decides an open upload and sends nothing; it goes on the next start", theStacksStopDecidesAnOpenUploadAndSendsNothingAndItGoesOnTheNextStart),
    ("an upload reported lost is said and waits for the next coming-up, then goes once", anUploadReportedLostIsSaidAndWaitsForTheNextComingUpThenGoesOnce),
    ("the next coming-up may be a STALE link's recovery on the same link", theNextComingUpMayBeAStaleLinksRecoveryOnTheSameLink),
    ("a STALE link that a new one replaced starts no flush when it recovers", aStaleLinkThatANewOneReplacedStartsNoFlushWhenItRecovers),
    ("nothing but the link coming up starts a flush", nothingButTheLinkComingUpStartsAFlush),
    ("a proof after the loss report settles it and it does not go again", aProofAfterTheLossReportSettlesItAndItDoesNotGoAgain),
    ("a proof later than 5 s is logged as a violation and settles all the same", aProofLaterThanFiveSecondsIsLoggedAsAViolationAndSettlesAllTheSame),
    ("a build that throws is said, kept owed and goes once on the next coming-up", aBuildThatThrowsIsSaidKeptOwedAndGoesOnceOnTheNextComingUp),
    ("an upload whose build throws while a flush that listed it builds an earlier entry is not built again by that flush", anUploadWhoseBuildThrowsWhileAFlushThatListedItBuildsAnEarlierEntryIsNotBuiltAgainByThatFlush),
    ("a replaced link decides nothing: the late proof settles it", aReplacedLinkDecidesNothingTheNewLinkDoesNotUploadWhileTheFirstUploadIsOpenAndTheLateProofSettlesIt),
    ("the old link's upload lost while a newer link is up goes once on the newer link at once", theOldLinksUploadLostWhileANewerLinkIsUpGoesOnceOnTheNewerLinkAtOnce),
    ("with no newer link up an old link's loss waits for the next coming-up", withNoNewerLinkUpAnOldLinksLossWaitsForTheNextComingUp),
    ("a late proof over the old link after the loss sent it on the new link settles it", aLateProofOverTheOldLinkAfterTheLossSentItOnTheNewLinkSettlesItAndTheNewUploadsLossSendsNothing),
    ("a stop decides the old upload with a newer link up and sends nothing", aStopDecidesTheOldUploadWithANewerLinkUpAndSendsNothing),
    ("two flushes on one link with a loss between them: the earlier does not upload again what the newer saw lost", twoFlushesOnOneLinkWithALossBetweenThemTheEarlierDoesNotUploadAgainWhatTheNewerSawLost),
    ("the user's own upload reported lost while a recovered flush builds an earlier entry is not uploaded by that flush", theUsersOwnUploadReportedLostWhileARecoveredFlushBuildsAnEarlierEntryIsNotUploadedByThatFlush),
    ("an upload on a replaced link decided while the new link's flush builds goes once on the new link and its failure waits", anUploadOnAReplacedLinkDecidedWhileTheNewLinksFlushBuildsAnEarlierEntryGoesOnceOnTheNewLinkAndItsFailureWaits),
    ("an upload an earlier flush made, reported lost while a later flush builds, is not uploaded by it", anUploadAnEarlierFlushMadeReportedLostWhileALaterFlushOnTheSameLinkBuildsIsNotUploadedByIt),
    ("a failure belongs to the exact message: the join decided after the leave's loss", aFailureBelongsToTheExactMessageTheJoinDecidedByItsLossAfterTheLeavesLossTakesNoRecordAndCostsTheLeaveNothing),
    ("the join decided before the leave's loss or proved late after it changes nothing for the leave", theJoinDecidedBeforeTheLeavesLossOrProvedLateAfterItChangesNothingForTheLeave),
    ("a join replaced by a leave is never built by a flush that listed it", aJoinReplacedByALeaveIsNeverBuiltByAFlushThatListedItAndTheLeaveKeepsItsRecord),
    ("a replaced join whose build throws after the leave's loss takes no record and nothing from the leave", aReplacedJoinWhoseBuildThrowsAfterTheLeavesLossTakesNoRecordAndNothingFromTheLeave),
    ("two sent copies in place of a join and a leave: the older goes once on the newer link at once", twoSentCopiesInPlaceOfAJoinAndALeaveTheOlderIsStillOwedAndGoesOnceOnTheNewerLinkAtOnce),
    ("the older action's proof does not clear the newer action's failure record", theOlderActionsProofDoesNotClearTheNewerActionsFailureRecord),
    ("a replaced action's failure record goes with it", aReplacedActionsFailureRecordGoesWithIt),
    ("a replaced action is never sent even when it was replaced while its upload was built", aReplacedActionIsNeverSentEvenWhenItWasReplacedWhileItsUploadWasBeingBuilt),
    ("at most one upload of an entry is in flight at a time", atMostOneUploadOfAnEntryIsInFlightAtATime),
    ("an open upload of an older action does not hold back the newer action on the same channel", anOpenUploadOfAnOlderActionDoesNotHoldBackTheNewerActionOnTheSameChannel),
    ("a flush whose link goes down midway leaves the rest for the next one", aFlushWhoseLinkGoesDownMidwayLeavesTheRestForTheNextOne),
    ("a Resource's failure decides it like a packet's timeout", aResourcesFailureDecidesItLikeAPacketsTimeoutAndNeedsNoPacketProofClock),
    ("a Resource's failure on a replaced link with a newer link up goes once on the newer link at once", aResourcesFailureOnAReplacedLinkWithANewerLinkUpGoesOnceOnTheNewerLinkAtOnce),
    ("an entry owed while the link is not active builds nothing and says nothing went wrong", anEntryOwedWhileTheLinkIsNotActiveBuildsNothingAndSaysNothingWentWrong),
]

@main
enum DistroOutboxTests {
    static func main() async {
        check(!outboxSource.isEmpty, "DistroOutbox.swift is readable from the tests")
        for (name, run) in allTests {
            currentTest = name
            let before = failures.count
            await run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        let pins: [(String, () -> Void)] = [
            ("only the link coming up starts a flush", onlyTheLinkComingUpStartsAFlush),
            ("an owed upload is made by three paths and no other", anOwedUploadIsMadeByThreePathsAndNoOther),
            ("the third ruling's send is the loss of an upload on another link and nothing else", theThirdRulingsSendIsTheLossOfAnUploadOnAnotherLinkAndNothingElse),
            ("an upload is decided only by its proof, its loss or the stack's stop", anUploadIsDecidedOnlyByItsProofItsLossOrTheStacksStop),
            ("the outbox starts no link and waits on no clock", theOutboxStartsNoLinkAndWaitsOnNoClock),
        ]
        for (name, run) in pins {
            currentTest = name
            let before = failures.count
            run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(allTests.count + pins.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
