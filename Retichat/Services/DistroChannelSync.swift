//
//  DistroChannelSync.swift
//  Retichat
//
//  Channel membership across a distro's devices: RFed-rust SPEC.md §17.12
//  "Membership sync" (James, 2026-10-03). Pure rules, Foundation only, no FFI,
//  so it compiles standalone with swiftc for tests/DistroChannelSyncTests.swift
//  (DESIGN_PRINCIPLES.md §10). Mirrors Retichat-android
//  service/DistroChannelSync.kt and the web's lib/channel_sync.js.
//
//  Joining or leaving a channel on one device is applied on every other device
//  of the distro D. The change travels as one LXMF message C from D to D, the
//  way a §17.11 sent copy does; each sibling subscribes or unsubscribes with
//  its own device key, so RFed sees only ordinary subscriptions. C's fields:
//
//   - 0x0C FIELD_TICKET: an empty bin. No ticket: it makes older clients take C
//     for a delivery notification and drop it. Never read here.
//   - 0xFB FIELD_CUSTOM_TYPE: `type`.
//   - 0xFC FIELD_CUSTOM_DATA: `[op, name, at_ms]` as a native msgpack array,
//     never a bin holding packed msgpack (CHECK_THESE_THINGS_FIRST §11).
//   - 0xFD FIELD_CUSTOM_META: the sending device's own `lxmf.delivery` address.
//
//  C is written by retichat_message_set_distro_channel_sync (rust/retichat-ffi
//  distro_outbox.rs) and read here from the bytes of the unwrapped fields map,
//  which lxmf_rust::distro::unwrap_blob hands on exactly as the sender packed
//  them (the unwrap JSON's "fields"). The reader takes every msgpack integer
//  encoding for `at_ms` and judges the value, never the type byte: the web
//  writes int 64 (0xd3), rmpv and umsgpack uint 64 (0xcf). A float, even an
//  integral one, a negative integer, a str and nil are no `at_ms`.
//

import Foundation

/// nonisolated: the project isolates to MainActor by default, and these run on
/// the distro blob queue and in tests.
nonisolated enum DistroChannelSync {

    /// FIELD_CUSTOM_TYPE of a membership message.
    static let type = "rfed.distro.channel"

    static let opJoin = "join"
    static let opLeave = "leave"

    /// `at_ms` is a msgpack integer from 0 to 2^53 - 1 (§17.12 "`at_ms` on the
    /// wire"): the web holds it in a JavaScript number, exact only up to there,
    /// so a larger one would be ordered differently on the clients. A writer
    /// never writes one and a receiver drops it, whatever its encoding.
    static let maxAtMs: Int64 = (Int64(1) << 53) - 1

    private static let fieldCustomType: Int64 = 0xFB
    private static let fieldCustomData: Int64 = 0xFC
    private static let fieldCustomMeta: Int64 = 0xFD

    /// The id C is owed under: one per channel, so a later action replaces it.
    static func entryId(_ channelHashHex: String) -> String { "channel:\(channelHashHex)" }

    /// What a usable C says: the user's `op` on `name` (the channel's full
    /// name) at `atMs`.
    struct Sync: Equatable, Sendable {
        let op: String
        let name: String
        let atMs: Int64
    }

    /// The membership marker of a received message: `byHex` is 0xFD lowercased
    /// ("" when absent; never format-checked: a malformed one is simply never
    /// this device's own address). `sync` is set for a usable 0xFC; otherwise
    /// `problem` says why not, and §17.12 rule 4 drops C with it.
    struct Marker: Equatable, Sendable {
        let byHex: String
        let sync: Sync?
        let problem: String?
    }

    /// The membership marker of a message whose unwrapped LXMF fields map is
    /// `fieldsMap` (msgpack, as the sender packed it): nil when the message is
    /// no membership message (no fields map, or 0xFB is not `type`, as str or
    /// bin); a Marker with a Sync for a usable one; a Marker with a problem once
    /// the type matches but 0xFC is unusable (rule 4: dropped and logged, never
    /// taken for an ordinary message). `op` must be "join" or "leave"; `name` a
    /// non-empty str or bin of valid UTF-8; `at_ms` an integer from 0 to
    /// `maxAtMs`, in any integer encoding. Elements after the third are ignored.
    /// The name rules of a join are the disposition's, not this reader's: a
    /// leave is not held to them. Never throws.
    static func read(_ fieldsMap: Data?) -> Marker? {
        guard let fieldsMap, !fieldsMap.isEmpty else { return nil }
        let b = [UInt8](fieldsMap)
        var typePos = -1
        var dataPos = -1
        var metaPos = -1
        do {
            let map = try readHead(b, 0)
            guard map.kind == .map else { return nil }
            var pos = map.end
            for _ in 0..<map.count {
                let key = try readHead(b, pos)
                pos = try skip(b, pos, 0)
                if key.kind == .int && !key.overflow {
                    // The first entry of a key is the one read.
                    switch key.int {
                    case fieldCustomType: if typePos < 0 { typePos = pos }
                    case fieldCustomData: if dataPos < 0 { dataPos = pos }
                    case fieldCustomMeta: if metaPos < 0 { metaPos = pos }
                    default: break
                    }
                }
                pos = try skip(b, pos, 0)
            }
            guard typePos >= 0, try textOf(b, typePos) == type else { return nil }
        } catch {
            // Too broken to name its type: no membership message.
            return nil
        }
        var byHex = ""
        func bad(_ problem: String) -> Marker { Marker(byHex: byHex, sync: nil, problem: problem) }
        do {
            if metaPos >= 0 { byHex = (try textOf(b, metaPos) ?? "").lowercased() }
            if dataPos < 0 { return bad("it carries no 0xFC") }
            let data = try readHead(b, dataPos)
            if data.kind != .array { return bad("its 0xFC is a \(data.kind.rawValue), not an array") }
            if data.count < 3 { return bad("its 0xFC holds \(data.count) element(s), not [op, name, at_ms]") }
            let opPos = data.end
            let namePos = try skip(b, opPos, 0)
            let atPos = try skip(b, namePos, 0)
            let op = try textOf(b, opPos)
            if op != opJoin && op != opLeave {
                return bad("its op is \(op == nil ? "not text" : "\"\(op!)\""), not \"join\" or \"leave\"")
            }
            guard let name = try textOf(b, namePos), !name.isEmpty else {
                return bad("its name is empty, not text, or not UTF-8")
            }
            let at = try readHead(b, atPos)
            if at.kind != .int || at.overflow || at.int < 0 || at.int > maxAtMs {
                return bad("its at_ms is not an integer from 0 to 2^53 − 1")
            }
            return Marker(byHex: byHex, sync: Sync(op: op!, name: name, atMs: at.int), problem: nil)
        } catch {
            return bad("its fields cannot be read (\((error as? Malformed)?.message ?? "\(error)"))")
        }
    }

    // MARK: - §17.12 rule 5

    /// The last membership action this device made or applied for a channel.
    struct Record: Equatable, Sendable {
        let op: String
        let atMs: Int64
    }

    /// Rule 5: whether the action (`op` at `atMs`) replaces the one recorded
    /// for its channel (`recorded`, nil when none). A later time wins; at an
    /// equal time a leave replaces a join and a join never replaces a leave, so
    /// every device ends in the same state whatever order the messages arrive in.
    static func supersedes(op: String, atMs: Int64, recorded: Record?) -> Bool {
        guard let recorded else { return true }
        if atMs > recorded.atMs { return true }
        if atMs < recorded.atMs { return false }
        return op == opLeave && recorded.op == opJoin
    }

    struct StampError: Error, Equatable { let atMs: Int64 }

    /// The `at_ms` of the user's own join or leave on this device: the current
    /// time, or one more than the time already recorded for the channel when
    /// that is later. So an action made after this device took a sibling's
    /// record is newer than that record on every device, even with this
    /// device's clock behind the sibling's. (The guarantee needs the record to
    /// have arrived: actions two devices make before either has the other's are
    /// ordered by their clocks alone.) Throws when the result is outside
    /// 0...maxAtMs.
    static func stampLocal(recorded: Record?, nowMs: Int64) throws -> Int64 {
        let at = (recorded != nil && recorded!.atMs + 1 > nowMs) ? recorded!.atMs + 1 : nowMs
        guard at >= 0, at <= maxAtMs else { throw StampError(atMs: at) }
        return at
    }

    // MARK: - §17.12 receive rules 1-5

    /// What rules 1-5 decide for a received C.
    enum Disposition: Equatable, Sendable {
        /// Dropped with a log line (`rule` says which rule). Never recorded as seen.
        case drop(rule: Int, reason: String)
        /// This device's own message (rule 3): dropped silently, recorded as seen.
        case echo
        /// Older than the action recorded for its channel (rule 5): dropped, recorded as seen.
        case stale(op: String, name: String, atMs: Int64, channelHash: String, recorded: Record)
        /// Rule 6 next: apply it on this device.
        case apply(op: String, name: String, atMs: Int64, channelHash: String)
    }

    /// Rules 1-5 in order; the first that drops a message ends the check.
    /// `marker` is `read`'s result (not nil). The facts the rules need are
    /// given, computed by the caller:
    ///  - `fromDistro`: the unwrapped source is D (rule 1);
    ///  - `signedByDistro`: the LXMF signature is D's (rule 2: the source hash
    ///    is plaintext in the encrypted body and D's key is announced, so anyone
    ///    can claim source D; without the check a stranger could make the user's
    ///    devices join a channel of the stranger's choosing, or leave one and
    ///    delete its history);
    ///  - `ownDeviceHex`: this device's own `lxmf.delivery` address (rule 3);
    ///  - `joinNameAccepted`: whether a join's name is one this client's own
    ///    join accepts (rule 4; a leave's name is not held to it, so a channel
    ///    joined before the rules, such as `public.Test`, can still be left);
    ///  - `channelHashOf`: name -> the channel hash it gives, the key every
    ///    client stores its channels and the record under;
    ///  - `recordOf`: channel hash -> the action recorded for it, or nil.
    static func disposition(
        marker: Marker,
        fromDistro: Bool,
        signedByDistro: Bool,
        ownDeviceHex: String?,
        joinNameAccepted: (String) -> Bool,
        channelHashOf: (String) -> String,
        recordOf: (String) -> Record?
    ) -> Disposition {
        if !fromDistro { return .drop(rule: 1, reason: "its source is not this device's distro") }
        if !signedByDistro { return .drop(rule: 2, reason: "it fails the distro signature") }
        if let own = ownDeviceHex, !own.isEmpty, marker.byHex == own.lowercased() { return .echo }
        guard let sync = marker.sync else {
            return .drop(rule: 4, reason: marker.problem ?? "its 0xFC is unusable")
        }
        if sync.op == opJoin && !joinNameAccepted(sync.name) {
            return .drop(rule: 4, reason: "its name is one this client's own join refuses")
        }
        let channelHash = channelHashOf(sync.name)
        let recorded = recordOf(channelHash)
        if !supersedes(op: sync.op, atMs: sync.atMs, recorded: recorded) {
            return .stale(op: sync.op, name: sync.name, atMs: sync.atMs, channelHash: channelHash, recorded: recorded!)
        }
        return .apply(op: sync.op, name: sync.name, atMs: sync.atMs, channelHash: channelHash)
    }

    /// The key a received C is deduplicated under (RFed SPEC §17.12
    /// "Receiving"): the live fan-out and a pull, or two uploads of one C, are
    /// one message. The generic fan-out key (source and timestamp) is not
    /// enough: every C has source D and empty content, so two siblings' Cs made
    /// in the same millisecond would share it and one of the two actions would
    /// be lost, the devices ending in different states. The spec keys C by its
    /// LXMF message hash; the unwrap does not report it yet (a shared-crate
    /// change), so this key takes what tells two Cs apart, which is all the hash
    /// does: C's timestamp, the device that acted (0xFD), and the action,
    /// channel and time it carries. Two uploads of one C are one key, whatever
    /// bytes carried them. The same key as Retichat-android's.
    static func repeatKey(sourceHex: String, timestamp: Double, marker: Marker) -> String {
        let sync = marker.sync
        return "\(sourceHex):\(timestamp):chan:\(marker.byHex):\(sync?.op ?? "?"):\(sync?.name ?? "?"):\(sync.map { String($0.atMs) } ?? "-1")"
    }

    // MARK: - msgpack, read from the bytes

    private struct Malformed: Error { let message: String }

    private enum Kind: String {
        case `nil` = "nil", bool, int, float, str, bin, array, map, ext
    }

    /// A msgpack head: `end` is the offset after the head. `count` is the
    /// element count of an array or map, and the payload length in bytes of a
    /// str, bin or ext (an ext's type byte included). `int` is an integer's
    /// value; `overflow` marks a uint 64 of 2^63 or more, which no `at_ms` is.
    private struct Head {
        let kind: Kind
        let end: Int
        var count: Int = 0
        var int: Int64 = 0
        var overflow = false
    }

    private static let maxDepth = 64

    private static func need(_ b: [UInt8], _ pos: Int, _ n: Int64) throws {
        guard n >= 0, pos >= 0, Int64(pos) + n <= Int64(b.count) else {
            throw Malformed(message: "\(n) bytes wanted at \(pos), \(b.count - pos) left")
        }
    }

    private static func u8(_ b: [UInt8], _ pos: Int) throws -> Int { try need(b, pos, 1); return Int(b[pos]) }
    private static func u16(_ b: [UInt8], _ pos: Int) throws -> Int { (try u8(b, pos) << 8) | (try u8(b, pos + 1)) }
    private static func u32(_ b: [UInt8], _ pos: Int) throws -> Int64 {
        try need(b, pos, 4)
        return (Int64(try u16(b, pos)) << 16) | Int64(try u16(b, pos + 2))
    }
    private static func i64(_ b: [UInt8], _ pos: Int) throws -> Int64 {
        try need(b, pos, 8)
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[pos + i]) }
        return Int64(bitPattern: v)
    }

    /// A length or count that must fit an Int32 to be usable (no input is that large).
    private static func length(_ n: Int64) throws -> Int {
        guard n >= 0, n <= Int64(Int32.max) else { throw Malformed(message: "length \(n) is not usable") }
        return Int(n)
    }

    private static func readHead(_ b: [UInt8], _ pos: Int) throws -> Head {
        let t = try u8(b, pos)
        let p = pos + 1
        switch t {
        case 0x00...0x7f: return Head(kind: .int, end: p, int: Int64(t))
        case 0x80...0x8f: return Head(kind: .map, end: p, count: t & 0x0f)
        case 0x90...0x9f: return Head(kind: .array, end: p, count: t & 0x0f)
        case 0xa0...0xbf: return Head(kind: .str, end: p, count: t & 0x1f)
        case 0xe0...0xff: return Head(kind: .int, end: p, int: Int64(t) - 256)
        case 0xc0: return Head(kind: .nil, end: p)
        case 0xc2, 0xc3: return Head(kind: .bool, end: p)
        case 0xc4: return Head(kind: .bin, end: p + 1, count: try u8(b, p))
        case 0xc5: return Head(kind: .bin, end: p + 2, count: try u16(b, p))
        case 0xc6: return Head(kind: .bin, end: p + 4, count: try length(try u32(b, p)))
        case 0xc7: return Head(kind: .ext, end: p + 1, count: try u8(b, p) + 1)
        case 0xc8: return Head(kind: .ext, end: p + 2, count: try u16(b, p) + 1)
        case 0xc9: return Head(kind: .ext, end: p + 4, count: try length(try u32(b, p) + 1))
        case 0xca: try need(b, p, 4); return Head(kind: .float, end: p + 4)
        case 0xcb: try need(b, p, 8); return Head(kind: .float, end: p + 8)
        case 0xcc: return Head(kind: .int, end: p + 1, int: Int64(try u8(b, p)))
        case 0xcd: return Head(kind: .int, end: p + 2, int: Int64(try u16(b, p)))
        case 0xce: return Head(kind: .int, end: p + 4, int: try u32(b, p))
        case 0xcf:
            let v = try i64(b, p)
            return Head(kind: .int, end: p + 8, int: v, overflow: v < 0)
        case 0xd0: return Head(kind: .int, end: p + 1, int: Int64(Int8(truncatingIfNeeded: try u8(b, p))))
        case 209: return Head(kind: .int, end: p + 2, int: Int64(Int16(truncatingIfNeeded: try u16(b, p))))   // int 16 (written in decimal: the app's sources name the Retichat field's number only in LxmfFields.swift)
        case 0xd2: return Head(kind: .int, end: p + 4, int: Int64(Int32(truncatingIfNeeded: try u32(b, p))))
        case 0xd3: return Head(kind: .int, end: p + 8, int: try i64(b, p))
        case 0xd4...0xd8: return Head(kind: .ext, end: p, count: (1 << (t - 0xd4)) + 1)
        case 0xd9: return Head(kind: .str, end: p + 1, count: try u8(b, p))
        case 0xda: return Head(kind: .str, end: p + 2, count: try u16(b, p))
        case 0xdb: return Head(kind: .str, end: p + 4, count: try length(try u32(b, p)))
        case 0xdc: return Head(kind: .array, end: p + 2, count: try u16(b, p))
        case 0xdd: return Head(kind: .array, end: p + 4, count: try length(try u32(b, p)))
        case 0xde: return Head(kind: .map, end: p + 2, count: try u16(b, p))
        case 0xdf: return Head(kind: .map, end: p + 4, count: try length(try u32(b, p)))
        default: throw Malformed(message: String(format: "0x%02x is no msgpack type", t))
        }
    }

    /// The offset after the value at `pos`. Every length is checked against the bytes left.
    private static func skip(_ b: [UInt8], _ pos: Int, _ depth: Int) throws -> Int {
        guard depth <= maxDepth else { throw Malformed(message: "nested deeper than \(maxDepth)") }
        let h = try readHead(b, pos)
        switch h.kind {
        case .nil, .bool, .int, .float:
            return h.end
        case .str, .bin, .ext:
            try need(b, h.end, Int64(h.count))
            return h.end + h.count
        case .array:
            var p = h.end
            for _ in 0..<h.count { p = try skip(b, p, depth + 1) }
            return p
        case .map:
            var p = h.end
            for _ in 0..<h.count {
                p = try skip(b, p, depth + 1)
                p = try skip(b, p, depth + 1)
            }
            return p
        }
    }

    /// A str or bin value as text, strict UTF-8; nil for any other kind or invalid UTF-8.
    private static func textOf(_ b: [UInt8], _ pos: Int) throws -> String? {
        let h = try readHead(b, pos)
        guard h.kind == .str || h.kind == .bin else { return nil }
        try need(b, h.end, Int64(h.count))
        return String(bytes: b[h.end..<(h.end + h.count)], encoding: .utf8)
    }
}
