// DistroChannelSyncTests.swift
//
// RFed-rust SPEC §17.12 "Membership sync": the message C as received (field
// encodings, any integer encoding of `at_ms`), receive rules 1-5, rule 5's
// order and the repeat key, against the spec's own vectors and the web's. A
// port of Retichat-android's DistroChannelSyncTest.kt.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/distro-channel-sync \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DistroCodec.swift \
//     Retichat-ios/Retichat/Views/NewChat/ChannelNameRules.swift \
//     Retichat-ios/tests/DistroChannelSyncTests.swift && \
//     /private/tmp/claude-501/distro-channel-sync
//
// The reader, the rules and the order run for real; the devices below are
// models of the user's phones that apply what the rules decide, as
// RfedChannelClient.handleDistroChannelSync does (wiring: see
// DistroOutboxWiringTests.swift, which pins it on the source).

import CryptoKit
import Foundation

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func check(_ ok: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures.append("\(currentTest): \(what)")
        print("FAIL: \(currentTest): \(what) (line \(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

typealias Marker = DistroChannelSync.Marker
typealias Sync = DistroChannelSync.Sync
typealias Record = DistroChannelSync.Record
typealias Disposition = DistroChannelSync.Disposition

let device = String(repeating: "a", count: 32)
let sibling = String(repeating: "b", count: 32)
let third = String(repeating: "c", count: 32)
let distro = String(repeating: "d", count: 32)

// MARK: - msgpack, written by hand: the oracle is the spec's table, not this codebase's reader

func str(_ s: String) -> [UInt8] {
    let raw = Array(s.utf8)
    return raw.count < 32 ? [UInt8(0xa0 | raw.count)] + raw : [0xd9, UInt8(raw.count)] + raw
}

func bin(_ raw: [UInt8]) -> [UInt8] { [0xc4, UInt8(raw.count)] + raw }

func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> UInt64(8 * (n - 1 - $0))) & 0xff) } }

func uint64(_ v: UInt64) -> [UInt8] { [0xcf] + be(v, 8) }
func int64(_ v: Int64) -> [UInt8] { [0xd3] + be(UInt64(bitPattern: v), 8) }
func uint32(_ v: UInt64) -> [UInt8] { [0xce] + be(v, 4) }
func uint16(_ v: UInt64) -> [UInt8] { [0xcd] + be(v, 2) }
func uint8(_ v: UInt64) -> [UInt8] { [0xcc] + be(v, 1) }
func fixint(_ v: Int) -> [UInt8] { [UInt8(v)] }
func float64(_ v: Double) -> [UInt8] { [0xcb] + be(v.bitPattern, 8) }
func float32(_ v: Float) -> [UInt8] { [0xca] + be(UInt64(v.bitPattern), 4) }

func array(_ items: [UInt8]...) -> [UInt8] { [UInt8(0x90 | items.count)] + items.flatMap { $0 } }

/// A fixmap of (key bytes, value bytes) pairs.
func map(_ entries: ([UInt8], [UInt8])...) -> [UInt8] {
    [UInt8(0x80 | entries.count)] + entries.flatMap { $0.0 + $0.1 }
}

func key(_ k: Int) -> [UInt8] { k < 0x80 ? [UInt8(k)] : [0xcc, UInt8(k)] }

/// C's fields as §17.12's table gives them, `at` as given.
func fields(op: String = "join", name: String = "public.general", at: [UInt8] = uint64(1_767_225_600_000),
            by: String = sibling, type: [UInt8]? = nil, data: [UInt8]? = nil) -> [UInt8] {
    map((key(0x0c), bin([])),
        (key(0xfb), type ?? str(DistroChannelSync.type)),
        (key(0xfc), data ?? array(str(op), str(name), at)),
        (key(0xfd), str(by)))
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func unhex(_ h: String) -> [UInt8] {
    stride(from: 0, to: h.count, by: 2).map { i in
        let a = h.index(h.startIndex, offsetBy: i)
        return UInt8(h[a..<h.index(a, offsetBy: 2)], radix: 16)!
    }
}

func read(_ b: [UInt8]?) -> Marker? { DistroChannelSync.read(b.map { Data($0) }) }

/// The web's bytes: Retichat-js writes int 64 for 2026-01-01 00:00 UTC, `d3 00 00 01 9b 76 da a8 00` (§17.12).
let webAt: [UInt8] = [0xd3, 0x00, 0x00, 0x01, 0x9b, 0x76, 0xda, 0xa8, 0x00]

/// The fields of C as the phones write them (rust/retichat-ffi `distro_outbox.rs` pins this very
/// literal for the writer, and Retichat-android's reader test reads it): join, `public.general`,
/// 2026-01-01 00:00 UTC as uint 64, sent by device 0123...cdef.
let phonesC = "840cc400ccfbb3726665642e64697374726f2e6368616e6e656cccfc93a46a6f696eae7075626c69632e67656e6572616ccf0000019b76daa800ccfdd9203031323334353637383961626364656630313233343536373839616263646566"

// MARK: - Tests

func theBytesThePhonesWriteAreReadBackAsTheActionTheyCarry() {
    let marker = read(unhex(phonesC))
    check(marker != nil, "the phones' C is a membership message")
    check(marker?.problem == nil, "and has no problem")
    checkEqual(marker?.sync, Sync(op: "join", name: "public.general", atMs: 1_767_225_600_000), "the action")
    checkEqual(marker?.byHex ?? "", "0123456789abcdef0123456789abcdef", "the device")
    // And they are the very bytes the test's own builder makes of the same fields.
    checkEqual(phonesC, hex(fields(at: uint64(1_767_225_600_000), by: "0123456789abcdef0123456789abcdef")), "the builder agrees")
}

func theWebsInt64AndRmpvsUint64HoldingOneValueAreTheSameAction() {
    checkEqual(Int64(1_767_225_600_000), Int64(0x19b76daa800), "the value of both")
    let fromWeb = read(fields(at: webAt))
    let fromPhone = read(fields(at: uint64(1_767_225_600_000)))
    check(fromWeb != nil, "the web's C is read")
    checkEqual(fromWeb, fromPhone, "the web's and the phone's are the same action")
    checkEqual(fromWeb?.sync, Sync(op: "join", name: "public.general", atMs: 1_767_225_600_000), "the action")
    check(fromWeb?.problem == nil, "no problem")
    checkEqual(fromWeb?.byHex ?? "", sibling, "the device")
}

func everyIntegerEncodingIsTakenAndTheValueIsJudgedNeverTheTypeByte() {
    let encodings: [[UInt8]] = [
        fixint(5), uint8(200), uint16(60_000), uint32(4_000_000_000), uint64(5), int64(5),
        [0xd0, 5], [0xd1] + be(5, 2), [0xd2] + be(5, 4),
    ]
    for at in encodings {
        check(read(fields(at: at))?.problem == nil, "taken: \(hex(at))")
    }
    checkEqual(read(fields(at: [0xd2] + be(5, 4)))?.sync?.atMs, 5, "int 32")
    checkEqual(read(fields(at: fixint(0)))?.sync?.atMs, 0, "zero")
    checkEqual(read(fields(at: uint8(200)))?.sync?.atMs, 200, "uint 8")
    checkEqual(read(fields(at: uint32(4_000_000_000)))?.sync?.atMs, 4_000_000_000, "uint 32")
}

func aFloatANegativeAStrAndNilAreNoAtMs() {
    let notIntegers: [[UInt8]] = [
        float64(1_767_225_600_000.0), float64(5.0), float32(5),
        int64(-1), [0xd0, 0xff], [0xff],
        str("5"), [0xc0], [0xc3], bin([5]),
    ]
    for at in notIntegers {
        let marker = read(fields(at: at))
        check(marker != nil && marker?.sync == nil, "no at_ms: \(hex(at))")
        check(marker?.problem?.contains("at_ms") == true, "the problem names at_ms: \(hex(at))")
    }
}

func atMsIsBoundedAt2To53Minus1InAnyEncoding() {
    let max = (UInt64(1) << 53) - 1
    checkEqual(DistroChannelSync.maxAtMs, Int64(max), "the bound")
    checkEqual(read(fields(at: uint64(max)))?.sync?.atMs, Int64(max), "uint 64 at the bound")
    checkEqual(read(fields(at: int64(Int64(max))))?.sync?.atMs, Int64(max), "int 64 at the bound")
    // 2^53 and 2^53 + 1, as uint 64 and int 64, and 2^64 - 1: the clients would order them differently.
    let tooBig: [[UInt8]] = [uint64(max + 1), uint64(max + 2), int64(Int64(max + 1)), uint64(UInt64.max), uint64(UInt64(1) << 63)]
    for at in tooBig {
        let marker = read(fields(at: at))
        check(marker != nil && marker?.sync == nil, "refused: \(hex(at))")
        check(marker?.problem?.contains("2^53") == true, "the problem names 2^53: \(hex(at))")
    }
}

func theFieldsOfCAsWrittenAreReadBackWhole() {
    // The writer (retichat_message_set_distro_channel_sync) writes 0x0C as an empty bin, 0xFB as a
    // str, 0xFC as a native array [op, name, at_ms] and 0xFD as a str of the device's address.
    let marker = read(fields(op: "leave", name: "0123456789abcdef.team", by: device.uppercased()))
    checkEqual(marker?.sync, Sync(op: "leave", name: "0123456789abcdef.team", atMs: 1_767_225_600_000), "the action")
    // 0xFD is lowercased.
    checkEqual(marker?.byHex ?? "", device, "lowercased")
}

func aNameAnOpAndATypeMayBeStrOrBin() {
    // "receivers accept bin too": the type, the op and the name as bin.
    let marker = read(fields(
        type: bin(Array(DistroChannelSync.type.utf8)),
        data: array(bin(Array("join".utf8)), bin(Array("public.general".utf8)), uint64(5))))
    checkEqual(marker?.sync, Sync(op: "join", name: "public.general", atMs: 5), "bin everywhere")
}

func elementsAfterTheThirdAreIgnoredAndFewerThanThreeAreUnusable() {
    let extra = read(fields(data: array(str("join"), str("public.x"), uint64(7), str("later"), uint64(1))))
    checkEqual(extra?.sync, Sync(op: "join", name: "public.x", atMs: 7), "extra elements ignored")
    let two = read(fields(data: array(str("join"), str("public.x"))))
    check(two != nil && two?.sync == nil, "two elements are no C")
    check(two?.problem?.contains("2 element") == true, "and say so")
}

func bytesHoldingPackedMsgpackAreNotAnArray() {
    // CHECK_THESE_THINGS_FIRST §11: never a bin holding packed msgpack.
    let wrapped = read(fields(data: bin(array(str("join"), str("public.x"), uint64(7)))))
    check(wrapped != nil && wrapped?.sync == nil, "a bin is no array")
    check(wrapped?.problem?.contains("bin, not an array") == true, "and says so")
}

func anOpThatIsNotJoinOrLeaveAndANameThatIsEmptyOrNotUtf8AreUnusable() {
    check(read(fields(op: "Join"))?.problem?.contains("\"Join\"") == true, "Join is not join")
    check(read(fields(data: array(uint64(1), str("public.x"), uint64(7))))?.problem?.contains("not text") == true, "an op that is not text")
    check(read(fields(name: ""))?.problem?.contains("name") == true, "an empty name")
    let notUtf8 = read(fields(data: array(str("join"), bin([0xff, 0xfe]), uint64(7))))
    check(notUtf8 != nil && notUtf8?.sync == nil, "a name that is not UTF-8")
    check(notUtf8?.problem?.contains("name") == true, "says name")
    let nameNotText = read(fields(data: array(str("join"), uint64(5), uint64(7))))
    check(nameNotText != nil && nameNotText?.sync == nil, "a name that is not text")
}

func aMessageThatIsNotAMembershipMessageIsNil() {
    check(read(nil) == nil, "no fields")
    check(read([]) == nil, "empty fields")
    check(read(map((key(0xfb), str("rfed.distro.sent")))) == nil, "a sent copy")
    check(read(map((key(0xfc), array(str("join"), str("public.x"), fixint(1))))) == nil, "no type")
    check(read(map()) == nil, "an empty map")
    // Not a map at all.
    check(read(array(str("join"))) == nil, "an array")
    check(read([0xc0]) == nil, "nil")
    // A type that is not text.
    check(read(map((key(0xfb), uint64(1)))) == nil, "a type that is not text")
}

func aKeyMayBeInAnyIntegerWidthAndTheFirstEntryOfAKeyIsTheOneRead() {
    let wide = map(
        ([0xcc, 0xfb], str(DistroChannelSync.type)),
        ([0xcd, 0x00, 0xfc], array(str("join"), str("public.x"), fixint(3))),
        ([0xd3] + be(0xfd, 8), str(sibling)))
    checkEqual(read(wide)?.sync, Sync(op: "join", name: "public.x", atMs: 3), "wide keys")
    let twice = map(
        (key(0xfb), str(DistroChannelSync.type)),
        (key(0xfc), array(str("join"), str("public.first"), fixint(1))),
        (key(0xfc), array(str("leave"), str("public.second"), fixint(2))))
    checkEqual(read(twice)?.sync?.name, "public.first", "the first entry")
    // No 0xFD: byHex is empty, never anyone's address.
    checkEqual(read(twice)?.byHex ?? "?", "", "no device")
}

func aTypedMessageWithNoOrBrokenDataIsUnusableNeverAnOrdinaryMessage() {
    let none = read(map((key(0xfb), str(DistroChannelSync.type)), (key(0xfd), str(sibling))))
    check(none != nil && none?.sync == nil, "no 0xFC")
    checkEqual(none?.problem ?? "", "it carries no 0xFC", "says so")
    checkEqual(none?.byHex ?? "", sibling, "still names the device")
    let cut = fields(op: "join", name: "public.general")
    let truncated = read(Array(cut.dropLast(3)))
    // A field map too broken to be read is dropped as no membership message at all.
    check(truncated == nil || truncated?.sync == nil, "a truncated map is no usable C")
}

func hostileBytesNeverCrash() {
    // A claimed array of four billion (or 2^31 - 1) elements, nesting deeper than any real field,
    // every truncation: each is read as far as its bytes go and no further.
    let bomb = [0x82] + key(0xfb) + str(DistroChannelSync.type) + key(0xfc) + [0xdd, 0xff, 0xff, 0xff, 0xff]
    check(read(bomb) == nil, "an array of four billion")
    let large = [0x82] + key(0xfb) + str(DistroChannelSync.type) + key(0xfc) + [0xdd, 0x7f, 0xff, 0xff, 0xff]
    check(read(large) == nil, "an array of 2^31 - 1")
    let deep = [UInt8](repeating: 0x91, count: 5000)
    check(read([0x81] + key(0xfb) + deep) == nil, "nested deeper than any field")
    let whole = fields()
    for cut in 0...whole.count { _ = read(Array(whole.prefix(cut))) }
    check(true, "every truncation read without a crash")
    check(read([0xc1]) == nil, "no msgpack type")
}

// MARK: - rule 5

func aLaterTimeWinsAndAtAnEqualTimeALeaveReplacesAJoinButNeverTheOtherWayAround() {
    let joinAt10 = Record(op: "join", atMs: 10)
    let leaveAt10 = Record(op: "leave", atMs: 10)
    func s(_ op: String, _ at: Int64, _ r: Record?) -> Bool { DistroChannelSync.supersedes(op: op, atMs: at, recorded: r) }
    check(s("join", 11, joinAt10), "a later join")
    check(s("leave", 11, joinAt10), "a later leave")
    check(!s("join", 9, leaveAt10), "an earlier join")
    check(!s("leave", 9, leaveAt10), "an earlier leave")
    check(s("leave", 10, joinAt10), "a leave at an equal time replaces a join")
    check(!s("join", 10, leaveAt10), "a join at an equal time never replaces a leave")
    // The same action again at the same time changes nothing.
    check(!s("join", 10, joinAt10), "the same join")
    check(!s("leave", 10, leaveAt10), "the same leave")
    check(s("join", 0, nil), "anything with no record")
}

func theUsersOwnActionIsStampedAfterAnyRecordHeld() {
    func stamp(_ r: Record?, _ now: Int64) -> Int64? { try? DistroChannelSync.stampLocal(recorded: r, nowMs: now) }
    checkEqual(stamp(nil, 1_000), 1_000, "no record")
    checkEqual(stamp(Record(op: "join", atMs: 400), 1_000), 1_000, "an older record")
    // The record is later than the clock: one more than it.
    checkEqual(stamp(Record(op: "leave", atMs: 2_000), 1_000), 2_001, "a later record")
    // At the clock's own time: one more, so the action is strictly newer.
    checkEqual(stamp(Record(op: "leave", atMs: 1_000), 1_000), 1_001, "an equal record")
    // Outside 0...2^53 - 1 there is no stamp.
    check(stamp(nil, DistroChannelSync.maxAtMs + 1) == nil, "past the bound")
    check(stamp(nil, -1) == nil, "before the epoch")
    check(stamp(Record(op: "join", atMs: DistroChannelSync.maxAtMs), 5) == nil, "one more than the bound")
}

// MARK: - rules 1-5 and the devices' state

func channelHashOf(_ name: String) -> String {
    hex(Array(SHA256.hash(data: Data(name.utf8)).prefix(16)))
}

/// One of the user's devices: its channel list and rule 5's record, applying what it receives.
final class Phone {
    let address: String
    var clock: Int64
    var records: [String: Record] = [:]
    var joined = Set<String>()

    init(_ address: String, _ clock: Int64) { self.address = address; self.clock = clock }

    func disposition(_ marker: Marker, fromDistro: Bool = true, signed: Bool = true) -> Disposition {
        DistroChannelSync.disposition(
            marker: marker, fromDistro: fromDistro, signedByDistro: signed, ownDeviceHex: address,
            joinNameAccepted: ChannelNameRules.joinNameAccepted,
            channelHashOf: channelHashOf,
            recordOf: { self.records[$0] })
    }

    /// The user's own action here: recorded and stamped, then C is made.
    func act(_ op: String, _ name: String) -> [UInt8] {
        let hash = channelHashOf(name)
        let at = (try? DistroChannelSync.stampLocal(recorded: records[hash], nowMs: clock)) ?? clock
        records[hash] = Record(op: op, atMs: at)
        if op == "join" { joined.insert(hash) } else { joined.remove(hash) }
        return fields(op: op, name: name, at: uint64(UInt64(at)), by: address)
    }

    /// C arrives (rules 1-5, then 6 for an apply).
    @discardableResult
    func receive(_ c: [UInt8], fromDistro: Bool = true, signed: Bool = true) -> Disposition {
        let marker = read(c)!
        let d = disposition(marker, fromDistro: fromDistro, signed: signed)
        if case .apply(let op, _, let atMs, let hash) = d {
            if op == "join" { joined.insert(hash) } else { joined.remove(hash) }
            records[hash] = Record(op: op, atMs: atMs)
        }
        return d
    }
}

func ruleOf(_ d: Disposition) -> Int? {
    if case .drop(let rule, _) = d { return rule }
    return nil
}

func theRulesRunInOrderAndTheFirstThatDropsEndsTheCheck() {
    let phone = Phone(device, 1_000)
    let ok = read(fields())!
    // Rule 1.
    checkEqual(ruleOf(phone.disposition(ok, fromDistro: false, signed: false)), 1, "rule 1")
    // Rule 2: a claimed source D with no valid signature by D's key.
    checkEqual(ruleOf(phone.disposition(ok, signed: false)), 2, "rule 2")
    // Rule 3 comes after both: an own echo that fails the signature is a drop, not an echo.
    let own = read(fields(by: device))!
    checkEqual(ruleOf(phone.disposition(own, signed: false)), 2, "an unsigned own echo is a drop")
    checkEqual(phone.disposition(own), Disposition.echo, "rule 3")
    // An own echo is an echo even when what it says is unusable (rule 3 before rule 4).
    let ownBroken = read(fields(op: "bogus", by: device))!
    checkEqual(phone.disposition(ownBroken), Disposition.echo, "rule 3 before rule 4")
    // Rule 4.
    let broken = read(fields(op: "bogus"))!
    let drop4 = phone.disposition(broken)
    checkEqual(ruleOf(drop4), 4, "rule 4")
    if case .drop(_, let reason) = drop4 { check(reason.contains("bogus"), "the reason names the op") }
    // Rule 4: a join whose name this client's own join refuses.
    let refused = read(fields(op: "join", name: "public.Test"))!
    checkEqual(ruleOf(phone.disposition(refused)), 4, "a refused join name")
}

func aLeaveOfAChannelJoinedBeforeTheNameRulesIsAppliedAndAJoinOfThatNameIsDropped() {
    let phone = Phone(device, 1_000)
    let hash = channelHashOf("public.Test")
    phone.joined.insert(hash)
    let leave = read(fields(op: "leave", name: "public.Test", at: uint64(5)))!
    checkEqual(phone.disposition(leave), Disposition.apply(op: "leave", name: "public.Test", atMs: 5, channelHash: hash), "the leave applies")
    let join = read(fields(op: "join", name: "public.Test", at: uint64(5)))!
    checkEqual(ruleOf(phone.disposition(join)), 4, "the join of that name is dropped")
}

func aMessageOlderThanTheRecordIsStaleAndRecordedAsSeen() {
    let phone = Phone(device, 1_000)
    let hash = channelHashOf("public.general")
    phone.records[hash] = Record(op: "leave", atMs: 500)
    let old = read(fields(op: "join", name: "public.general", at: uint64(400)))!
    checkEqual(phone.disposition(old),
               Disposition.stale(op: "join", name: "public.general", atMs: 400, channelHash: hash, recorded: Record(op: "leave", atMs: 500)),
               "stale")
}

func aJoinAndALeaveWithOneTimeLeaveEveryDeviceLeftInEitherOrder() {
    let join = fields(op: "join", name: "public.general", at: uint64(1_000), by: sibling)
    let leave = fields(op: "leave", name: "public.general", at: uint64(1_000), by: third)
    for order in [[join, leave], [leave, join]] {
        let phone = Phone(device, 5_000)
        order.forEach { phone.receive($0) }
        check(phone.joined.isEmpty, "every device ends left")
        checkEqual(phone.records[channelHashOf("public.general")], Record(op: "leave", atMs: 1_000), "the record")
    }
}

func concurrentActionsEndInOneStateTheOneWithTheLargerAtMs() {
    let a = fields(op: "join", name: "public.general", at: uint64(2_000), by: sibling)
    let b = fields(op: "leave", name: "public.general", at: uint64(1_500), by: third)
    for order in [[a, b], [b, a]] {
        let phone = Phone(device, 9_000)
        order.forEach { phone.receive($0) }
        checkEqual(phone.joined, [channelHashOf("public.general")], "the larger at_ms wins")
    }
}

func aDeviceWithItsClockTenMinutesBehindStampsItsLaterJoinAfterASiblingsLeave() {
    let tenMinutes: Int64 = 600_000
    let a = Phone(sibling, 1_000_000)
    let b = Phone(device, 1_000_000 - tenMinutes)
    let name = "public.general"
    // Both are in the channel; A leaves at its clock. B takes A's record, then joins by its own (slow) clock.
    a.joined.insert(channelHashOf(name)); b.joined.insert(channelHashOf(name))
    let leave = a.act("leave", name)
    b.receive(leave)
    check(b.joined.isEmpty, "B left")
    let join = b.act("join", name)
    a.receive(join)
    checkEqual(a.joined, [channelHashOf(name)], "every device ends joined: A")
    checkEqual(b.joined, [channelHashOf(name)], "every device ends joined: B")
    // Stamped by the clock alone, B's join would be older than A's leave and A would end left.
    check(read(join)!.sync!.atMs > read(leave)!.sync!.atMs, "B's join is newer than A's leave")
    let clockAlone = fields(op: "join", name: name, at: uint64(UInt64(b.clock)), by: device)
    let a2 = Phone(sibling, 1_000_000)
    a2.joined.insert(channelHashOf(name))
    a2.receive(fields(op: "leave", name: name, at: uint64(1_000_000), by: third))
    a2.receive(clockAlone)
    check(a2.joined.isEmpty, "a clock-alone stamp leaves the devices disagreeing")
}

func anOwnEchoIsDroppedAndAppliedChangesAreNeverReSent() {
    let phone = Phone(device, 1_000)
    let c = phone.act("join", "public.general")
    // RFed fans C out to the sender too: dropped by 0xFD, the record untouched.
    checkEqual(phone.receive(c), Disposition.echo, "the echo")
    checkEqual(phone.records.count, 1, "the record is untouched")
}

// MARK: - the repeat key

func theSameCTwiceIsOneMessageAndTwoSiblingsCsInOneMillisecondAreTwo() {
    let atMs = uint64(1_000)
    let fromSibling = read(fields(op: "join", name: "public.x", at: atMs, by: sibling))!
    let fromOther = read(fields(op: "leave", name: "public.x", at: atMs, by: third))!
    let ts = 1_767_225_600.123
    // Same source, same LXMF timestamp, empty content: the generic key would be one.
    checkEqual(DistroCodec.seenKey(sourceHex: distro, timestamp: ts), DistroCodec.seenKey(sourceHex: distro, timestamp: ts), "the generic key is one")
    check(DistroChannelSync.repeatKey(sourceHex: distro, timestamp: ts, marker: fromSibling)
          != DistroChannelSync.repeatKey(sourceHex: distro, timestamp: ts, marker: fromOther), "two siblings' Cs are two")
    // Two uploads of one C, or its live arrival and its pull, are the same key.
    let again = read(fields(op: "join", name: "public.x", at: int64(1_000), by: sibling))!
    checkEqual(DistroChannelSync.repeatKey(sourceHex: distro, timestamp: ts, marker: fromSibling),
               DistroChannelSync.repeatKey(sourceHex: distro, timestamp: ts, marker: again), "one C twice is one")
    // A different action by the same device in the same instant is another message too.
    let laterAction = read(fields(op: "leave", name: "public.x", at: uint64(1_001), by: sibling))!
    check(DistroChannelSync.repeatKey(sourceHex: distro, timestamp: ts, marker: fromSibling)
          != DistroChannelSync.repeatKey(sourceHex: distro, timestamp: ts, marker: laterAction), "another action is another message")
}

func entryIdIsTheChannelsSoALaterActionReplacesIt() {
    checkEqual(DistroChannelSync.entryId("abc"), "channel:abc", "the id")
}

// MARK: - RFed SPEC §17.12 rule 4: the join a sibling made (ChannelNameRules.joinNameAccepted)

func aSiblingsJoinIsAcceptedOnlyForANameTheFormWouldBuild() {
    for name in ["public.general", "public.team.ops-1", "0123456789abcdef.nametest-096499", "public.caf\u{e9}", "4cdc4115.nametest"] {
        check(ChannelNameRules.joinNameAccepted(name), "accepted: \(name)")
    }
}

func aNameTheFormWouldHaveChangedIsRefused() {
    // Nothing is trimmed, lowercased, normalized or filtered: the channel is derived from these
    // bytes, so a different name is a different channel.
    for name in ["public.Test", "Public.test", " public.test", "public.test ", "public.te st", "public.te_st",
                 // A decomposed é is not the NFC name the form builds.
                 "public.cafe\u{301}"] {
        check(!ChannelNameRules.joinNameAccepted(name), "refused: \(name.debugDescription)")
    }
    // Only the first "." ends the root: "pub" is a private root here.
    check(ChannelNameRules.joinNameAccepted("pub.lic.test"), "pub.lic.test is a private channel")
}

func aNameWithNoRootOrNoNameIsRefused() {
    for name in ["", "general", ".general", "public.", "0123456789abcdef."] {
        check(!ChannelNameRules.joinNameAccepted(name), "refused: \(name.debugDescription)")
    }
}

func theRootRulesHoldForAPrivateRoot() {
    // A private root is letters, digits and "-" (never "_" or a dot).
    check(ChannelNameRules.joinNameAccepted("my-team.ops"), "my-team.ops")
    check(!ChannelNameRules.joinNameAccepted("my_team.ops"), "my_team.ops")
    check(!ChannelNameRules.joinNameAccepted("MY-team.ops"), "MY-team.ops")
}

let allTests: [(String, () -> Void)] = [
    ("the bytes the phones write are read back as the action they carry", theBytesThePhonesWriteAreReadBackAsTheActionTheyCarry),
    ("the web's int 64 and rmpv's uint 64 holding one value are the same action", theWebsInt64AndRmpvsUint64HoldingOneValueAreTheSameAction),
    ("every integer encoding is taken and the value is judged, never the type byte", everyIntegerEncodingIsTakenAndTheValueIsJudgedNeverTheTypeByte),
    ("a float, a negative, a str and nil are no at_ms", aFloatANegativeAStrAndNilAreNoAtMs),
    ("at_ms is bounded at 2^53 - 1 in any encoding", atMsIsBoundedAt2To53Minus1InAnyEncoding),
    ("the fields of C as written are read back whole", theFieldsOfCAsWrittenAreReadBackWhole),
    ("a name, an op and a type may be str or bin", aNameAnOpAndATypeMayBeStrOrBin),
    ("elements after the third are ignored and fewer than three are unusable", elementsAfterTheThirdAreIgnoredAndFewerThanThreeAreUnusable),
    ("bytes holding packed msgpack are not an array", bytesHoldingPackedMsgpackAreNotAnArray),
    ("an op that is not join or leave, and a name that is empty or not UTF-8, are unusable", anOpThatIsNotJoinOrLeaveAndANameThatIsEmptyOrNotUtf8AreUnusable),
    ("a message that is not a membership message is nil", aMessageThatIsNotAMembershipMessageIsNil),
    ("a key may be in any integer width and the first entry of a key is the one read", aKeyMayBeInAnyIntegerWidthAndTheFirstEntryOfAKeyIsTheOneRead),
    ("a typed message with no or broken data is unusable, never an ordinary message", aTypedMessageWithNoOrBrokenDataIsUnusableNeverAnOrdinaryMessage),
    ("hostile bytes never crash", hostileBytesNeverCrash),
    ("a later time wins; at an equal time a leave replaces a join, never the other way", aLaterTimeWinsAndAtAnEqualTimeALeaveReplacesAJoinButNeverTheOtherWayAround),
    ("the user's own action is stamped after any record held", theUsersOwnActionIsStampedAfterAnyRecordHeld),
    ("the rules run in order and the first that drops ends the check", theRulesRunInOrderAndTheFirstThatDropsEndsTheCheck),
    ("a leave of a channel joined before the name rules is applied; a join of that name is dropped", aLeaveOfAChannelJoinedBeforeTheNameRulesIsAppliedAndAJoinOfThatNameIsDropped),
    ("a message older than the record is stale", aMessageOlderThanTheRecordIsStaleAndRecordedAsSeen),
    ("a join and a leave with one time: every device left, in either order", aJoinAndALeaveWithOneTimeLeaveEveryDeviceLeftInEitherOrder),
    ("concurrent actions end in one state, the one with the larger at_ms", concurrentActionsEndInOneStateTheOneWithTheLargerAtMs),
    ("a device with its clock ten minutes behind stamps its later join after a sibling's leave", aDeviceWithItsClockTenMinutesBehindStampsItsLaterJoinAfterASiblingsLeave),
    ("an own echo is dropped and applied changes are never re-sent", anOwnEchoIsDroppedAndAppliedChangesAreNeverReSent),
    ("the same C twice is one message and two siblings' Cs in one millisecond are two", theSameCTwiceIsOneMessageAndTwoSiblingsCsInOneMillisecondAreTwo),
    ("the entry id is the channel's, so a later action replaces it", entryIdIsTheChannelsSoALaterActionReplacesIt),
    ("a sibling's join is accepted only for a name the form would build", aSiblingsJoinIsAcceptedOnlyForANameTheFormWouldBuild),
    ("a name the form would have changed is refused", aNameTheFormWouldHaveChangedIsRefused),
    ("a name with no root or no name is refused", aNameWithNoRootOrNoNameIsRefused),
    ("the root rules hold for a private root", theRootRulesHoldForAPrivateRoot),
]

@main
enum DistroChannelSyncTests {
    static func main() {
        for (name, run) in allTests {
            currentTest = name
            let before = failures.count
            run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(allTests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
