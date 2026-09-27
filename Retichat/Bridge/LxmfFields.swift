//
//  LxmfFields.swift
//  Retichat
//
//  Minimal msgpack decoder for LXMF fields.
//  Mirrors the Android LxmfFields.kt implementation.
//

import Foundation
import CryptoKit

// MARK: - LXMF field keys
//
// Key numbers are aligned with the Android implementation to ensure
// cross-platform interoperability.

enum LxmfFieldKey {
    static let fileAttachments: UInt8 = 0x05
    // 0x10 (FIELD_SENDER_NAME) is retired (DISPLAY_NAMES.md §2.1): never sent,
    // never read, skipped like any unknown field. MeshChatX and Columba put
    // dicts there. The sender's name is key 0 of the Retichat field 0xD1
    // (RetichatField below), which the Rust side decodes
    // (LxmfClient.decodeDisplayName, DisplayNames below).
    // The group fields 0xA0-0xA8 are GroupEntry.legacyField: group entries
    // are written only through LxmfClient.messageSetGroupEntry, which picks
    // the form (DISPLAY_NAMES.md §10).
    // Custom-type fields (LXMF FIELD_CUSTOM_TYPE / FIELD_CUSTOM_DATA). nonisolated
    // so the distro services, which run off the main actor, can read them.
    nonisolated static let customType: UInt8 = 0xFB  // string: application-defined message type
    nonisolated static let customData: UInt8 = 0xFC  // str or bin: payload for customType
    nonisolated static let customMeta: UInt8 = 0xFD  // str or bin: metadata for customType
}

// MARK: - The Retichat field 0xD1 (DISPLAY_NAMES.md §2.1, §10)
//
// Retichat owns one LXMF field number, 0xD1 (FIELD_RETICHAT). Its value is a
// msgpack map with small integer keys: 0 is the display name (written by the
// Rust router only, decoded by lxmf_display_name_decode), 1-9 the group
// entries. A 0xD1 that is not a map is ignored whole; unknown keys are
// ignored. Mirrors lxmf_rust::retichat_field.

nonisolated enum RetichatField {
    /// FIELD_RETICHAT.
    static let field: UInt8 = 0xD1
    /// RF_DISPLAY_NAME: the router's; apps never set it (§4.1).
    static let displayNameKey: UInt8 = 0
    /// RF_MAX_KEY: keys are positive fixints, one byte on the wire.
    static let maxKey: UInt8 = 127

    /// §10, GROUP_ENTRIES_IN_RETICHAT_FIELD in Rust, Kotlin and JS: where
    /// this client writes group entries. false until the switch (around
    /// 2026-10-26, with the proof re-enable): released apps read only the
    /// old top-level fields 0xA0-0xA8. At the switch this becomes true in
    /// every client; readers take both forms already.
    static let groupEntriesInRetichatField = false
}

/// The group entries (§10): Retichat field key 1-9, the old top-level field
/// 0xA0-0xA8 each replaces, and its type (all str but relayDone, a bool).
/// Group semantics: RFed Group.md.
nonisolated enum GroupEntry: UInt8, CaseIterable {
    case id = 1         // RF_GROUP_ID, 0xA0: 32-hex group identifier
    case members        // RF_GROUP_MEMBERS, 0xA1: comma-sep hex hashes of ALL members (invite only)
    case name           // RF_GROUP_NAME, 0xA2: human-readable group name
    case action         // RF_GROUP_ACTION, 0xA3: "invite"|"accept"|"leave"|"relay_req"|"relay_done"
    case sender         // RF_GROUP_SENDER, 0xA4: original sender hex (may differ from LXMF src)
    case relaySeen      // RF_GROUP_RELAY_SEEN, 0xA5: comma-sep hashes already delivered to
    case relayFor       // RF_GROUP_RELAY_FOR, 0xA6: hash of member being relayed for
    case relayDone      // RF_GROUP_RELAY_DONE, 0xA7: bool, relay-complete signal
    case memberKeys     // RF_GROUP_MEMBER_KEYS, 0xA8: one hash:base64-public-key pair per invite chunk

    /// The key inside the Retichat field.
    var key: UInt8 { rawValue }
    /// The old top-level field number (0xA0 + key - 1).
    var legacyField: UInt8 { 0x9F + rawValue }
    /// The entry holds a bool (only relayDone); the rest hold a str.
    var isBool: Bool { self == .relayDone }

    init?(legacyField: UInt8) {
        guard legacyField >= 0xA0 else { return nil }
        self.init(rawValue: legacyField - 0x9F)
    }
}

/// A group entry's value: each keeps exactly the type it had as a top-level
/// field (§10).
nonisolated enum GroupValue: Equatable {
    case str(String)
    case bool(Bool)

    var isBool: Bool { if case .bool = self { return true }; return false }
}

/// One group entry to write: the pure part of LxmfClient.messageSetGroupEntry.
nonisolated enum GroupFieldWrite: Equatable {
    /// The old form: top-level field 0xA0-0xA8 (lxmf_message_add_field[_bool]).
    case topLevel(field: UInt8, value: GroupValue)
    /// The new form: key 1-9 of the Retichat field (lxmf_message_set_retichat_*).
    case retichat(key: UInt8, value: GroupValue)

    /// Where `entry` = `value` goes, by `inRetichatField` (the constant
    /// unless a test asks for the other form); nil when the value has the
    /// wrong type for the entry.
    static func of(_ entry: GroupEntry, _ value: GroupValue,
                   inRetichatField: Bool = RetichatField.groupEntriesInRetichatField) -> GroupFieldWrite? {
        guard entry.isBool == value.isBool else { return nil }
        return inRetichatField ? .retichat(key: entry.key, value: value)
                               : .topLevel(field: entry.legacyField, value: value)
    }
}

// MARK: - Distro identity transfer
//
// RFed SPEC §17.9: a distro identity is handed to another device as an LXMF
// message signed as the SENDING DEVICE, with FIELD_CUSTOM_TYPE (0xFB) =
// "rfed.distro.transfer" and FIELD_CUSTOM_DATA (0xFC) = the 128-hex private
// key. Mirrors Android LxmfFields.kt:91-100. Field 0x0D is never used: until
// 2026-09-24 the transfer rode on it, but LXMF 1.1.1 defines 0x0D as FIELD_EVENT.

nonisolated enum DistroTransfer {
    static let customType = "rfed.distro.transfer"
}

// MARK: - Distro sent-message sync
//
// RFed SPEC §17.11: a message this device sends AS the distro is also sent,
// PROPAGATED, to the distro itself, so every sibling device files it as a
// message the user sent. The copy is signed as the distro and carries
// FIELD_CUSTOM_TYPE (0xFB) = "rfed.distro.sent", FIELD_CUSTOM_DATA (0xFC) =
// the recipient's address and FIELD_CUSTOM_META (0xFD) = the sending
// device's own address (both 32 lowercase hex). Mirrors lxmf_rust
// distro::DISTRO_SENT_TYPE, read for received copies by unwrap_blob.

nonisolated enum DistroSent {
    static let customType = "rfed.distro.sent"
}

// MARK: - Group action constants

enum GroupAction {
    /// Initial group invite — includes GROUP_MEMBERS with the full participant list.
    static let invite       = "invite"
    /// Acceptance of an invite — each accepting member sends this to all other members.
    static let accept       = "accept"
    /// Member leaving the group — sent to all currently accepted members.
    static let leave        = "leave"
    /// Request for another member to relay a message on our behalf.
    static let relayRequest = "relay_req"
    /// Confirmation that a relay was completed.
    static let relayDone    = "relay_done"
    // nil / absent = regular group message
}

// MARK: - Member invitation status constants

enum MemberStatus {
    static let invited  = "invited"   // Invite sent, no acceptance received yet
    static let accepted = "accepted"  // Member has accepted the invite
    static let left     = "left"      // Member voluntarily left
    static let declined = "declined"  // Member declined (local only, not transmitted)
}

// MARK: - Parsed fields

struct LxmfFields {
    var attachments: [(filename: String, data: Data)] = []
    /// The group entries as sent (§10): from the Retichat field 0xD1 when it
    /// holds the entry with its type, else from the old field 0xA0-0xA8.
    /// The group fields below are read from these.
    var groupEntries: [GroupEntry: GroupValue] = [:]
    // Group fields
    var groupId: String?
    var groupMembers: [String]?      // full member list (invite messages only)
    var groupName: String?
    var groupAction: String?         // nil = regular group message
    var groupSender: String?         // original sender's hex hash
    var groupRelaySeen: [String]?    // hashes that have already received this relay
    var groupRelayFor: String?       // hash of member requesting relay
    var groupRelayDone: Bool?        // relay-complete signal
    var groupMemberKeys: [String: String]?
    // Custom-type fields
    var customType: String?          // FIELD_CUSTOM_TYPE (0xFB)
    var customData: String?          // FIELD_CUSTOM_DATA (0xFC), decoded from msgpack str OR bin (UTF-8)
    var customMeta: String?          // FIELD_CUSTOM_META (0xFD), str OR bin, like customData

    /// The 128-hex distro private key when this message is an identity
    /// transfer (SPEC §17.9), else nil. Both fields must match: a 0xFC payload
    /// under any other custom type is someone else's data, not a key.
    var distroTransferKey: String? {
        customType == DistroTransfer.customType ? customData : nil
    }

    /// A distro sent-message copy (SPEC §17.11). Genuine copies only ever
    /// arrive as distro fan-out, which RfedDistroClient unwraps; one reaching
    /// the router or the NSE as an ordinary message is not the user's and
    /// must not become an incoming bubble.
    var isDistroSentCopy: Bool {
        customType == DistroSent.customType
    }
}

// MARK: - MsgPack decoder

final class LxmfFieldsDecoder {

    static func decode(_ data: Data) -> LxmfFields {
        var fields = LxmfFields()
        guard !data.isEmpty else { return fields }

        var offset = 0
        let bytes = [UInt8](data)

        // Expect a map at top level
        guard let mapCount = readMapLength(bytes, &offset) else { return fields }

        // §10: each group entry from the Retichat field when it holds it
        // with its type, else from its old top-level field. Both are kept
        // as first seen (as lxmf_rust::retichat_field reads them) and
        // resolved after the walk, since the forms may come in any order.
        var legacyGroup: [GroupEntry: Scalar] = [:]
        var retichatGroup: [GroupEntry: Scalar] = [:]
        var sawRetichatField = false

        for _ in 0..<mapCount {
            guard offset < bytes.count else { break }
            // Keys are integers of any msgpack width; a string or negative
            // key is no field of ours, and its value is skipped. Field keys
            // above 0xFF exist (LXMF reserves the range above 0xFF for
            // experimental fields) and none is ours either. A plain
            // UInt8(key) trapped here, so one such field in any received
            // message crashed the app.
            guard let key = readKey(bytes, &offset), key <= 0xFF else {
                skipValue(bytes, &offset)
                continue
            }
            let field = UInt8(key)

            if field == RetichatField.field {
                if sawRetichatField {
                    skipValue(bytes, &offset)
                } else {
                    sawRetichatField = true
                    retichatGroup = readRetichatGroupEntries(bytes, &offset)
                }
                continue
            }
            if let entry = GroupEntry(legacyField: field) {
                let value = readScalar(bytes, &offset)
                if legacyGroup[entry] == nil { legacyGroup[entry] = value }
                continue
            }

            switch field {
            case LxmfFieldKey.fileAttachments:
                if let arrLen = readArrayLength(bytes, &offset) {
                    var attachments: [(String, Data)] = []
                    for _ in 0..<arrLen {
                        guard offset < bytes.count else { break }
                        // Each attachment is [filename, data]
                        if let innerLen = readArrayLength(bytes, &offset), innerLen >= 2 {
                            let filename = readString(bytes, &offset) ?? ""
                            let fileData = readBin(bytes, &offset) ?? Data()
                            attachments.append((filename, fileData))
                            // Skip extra elements
                            for _ in 2..<innerLen { skipValue(bytes, &offset) }
                        }
                    }
                    fields.attachments = attachments
                } else {
                    skipValue(bytes, &offset)
                }

            case LxmfFieldKey.customType:
                fields.customType = readStringOrBin(bytes, &offset)

            case LxmfFieldKey.customData:
                // The web client may send 0xFC as bin rather than str
                // (Retichat-js), so both decode to the same UTF-8 string.
                fields.customData = readStringOrBin(bytes, &offset)

            case LxmfFieldKey.customMeta:
                fields.customMeta = readStringOrBin(bytes, &offset)

            default:
                skipValue(bytes, &offset)
            }
        }

        fields.groupEntries = resolveGroupEntries(retichat: retichatGroup, legacy: legacyGroup)
        applyGroupEntries(&fields)
        return fields
    }

    // MARK: - Group entries (§10)

    /// One msgpack value as far as a group entry cares: a str (nil when it
    /// is not UTF-8), a bool, or anything else.
    enum Scalar: Equatable {
        case str(String?)
        case bool(Bool)
        case other
    }

    /// §10's reader rule, entry by entry: the Retichat field's value when it
    /// has the entry's type (an empty str or false included), else the old
    /// field's when it has the type, else none. A str is a msgpack str (bin
    /// is not), relayDone a msgpack bool.
    static func resolveGroupEntries(retichat: [GroupEntry: Scalar],
                                    legacy: [GroupEntry: Scalar]) -> [GroupEntry: GroupValue] {
        func typed(_ scalar: Scalar?, _ entry: GroupEntry) -> GroupValue? {
            switch (scalar, entry.isBool) {
            case (.str(let s?)?, false): return .str(s)
            case (.bool(let b)?, true):  return .bool(b)
            default:                     return nil
            }
        }
        var out: [GroupEntry: GroupValue] = [:]
        for entry in GroupEntry.allCases {
            if let value = typed(retichat[entry], entry) ?? typed(legacy[entry], entry) {
                out[entry] = value
            }
        }
        return out
    }

    /// The typed group fields of `fields`, from its resolved groupEntries.
    private static func applyGroupEntries(_ fields: inout LxmfFields) {
        let entries = fields.groupEntries
        func str(_ entry: GroupEntry) -> String? {
            if case .str(let s)? = entries[entry] { return s }
            return nil
        }
        func csv(_ raw: String) -> [String] {
            raw.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        fields.groupId = str(.id)
        // Comma-separated strings (Android-compatible).
        fields.groupMembers = str(.members).map(csv)
        fields.groupName = str(.name)
        fields.groupAction = str(.action)
        fields.groupSender = str(.sender)
        fields.groupRelaySeen = str(.relaySeen).map(csv)
        fields.groupRelayFor = str(.relayFor)
        if case .bool(let done)? = entries[.relayDone] { fields.groupRelayDone = done }
        if let raw = str(.memberKeys) {
            fields.groupMemberKeys = Dictionary(raw.split(separator: ",").compactMap { entry in
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].count == 32,
                    Data(base64Encoded: parts[1])?.count == 64 else { return nil }
                return (parts[0].lowercased(), parts[1])
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The Retichat field's value: its group entries (keys 1-9, first of
    /// each), consuming exactly the one value. A value that is not a map is
    /// ignored whole (§2.1); keys that are not integers 1-9 are ignored. Key
    /// 0, the name, is the Rust side's (lxmf_display_name_decode).
    private static func readRetichatGroupEntries(_ bytes: [UInt8], _ offset: inout Int) -> [GroupEntry: Scalar] {
        var entries: [GroupEntry: Scalar] = [:]
        guard let count = readMapLength(bytes, &offset) else {
            skipValue(bytes, &offset)
            return entries
        }
        for _ in 0..<count {
            guard offset < bytes.count else { break }
            let key = readKey(bytes, &offset)
            let value = readScalar(bytes, &offset)
            if let key, key <= UInt64(RetichatField.maxKey),
               let entry = GroupEntry(rawValue: UInt8(key)), entries[entry] == nil {
                entries[entry] = value
            }
        }
        return entries
    }

    /// One map key, consuming exactly one value: the integer when it is one
    /// of any msgpack width holding a non-negative value, else nil (a str,
    /// a negative int or anything else never matches a field or entry).
    static func readKey(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        if b <= 0x7F { offset += 1; return UInt64(b) }        // positive fixint
        let width: Int
        let signed: Bool
        switch b {
        case 0xCC: width = 1; signed = false
        case 0xCD: width = 2; signed = false
        case 0xCE: width = 4; signed = false
        case 0xCF: width = 8; signed = false
        case 0xD0: width = 1; signed = true
        case 0xD1: width = 2; signed = true
        case 0xD2: width = 4; signed = true
        case 0xD3: width = 8; signed = true
        default:
            skipValue(bytes, &offset)
            return nil
        }
        guard width < bytes.count - offset else {
            offset = bytes.count
            return nil
        }
        let value = bytes[(offset + 1)...(offset + width)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        offset += 1 + width
        // A signed int with its top bit set is negative.
        if signed && value >> (UInt64(width) * 8 - 1) & 1 == 1 { return nil }
        return value
    }

    /// One value as a Scalar, consuming exactly that value whatever it is.
    static func readScalar(_ bytes: [UInt8], _ offset: inout Int) -> Scalar {
        guard offset < bytes.count else { return .other }
        let b = bytes[offset]
        if b == 0xC2 || b == 0xC3 { offset += 1; return .bool(b == 0xC3) }
        let headerLen: Int
        let lenBytes: Int
        if b & 0xE0 == 0xA0 {          // fixstr
            headerLen = 1; lenBytes = 0
        } else if b == 0xD9 {          // str8
            headerLen = 2; lenBytes = 1
        } else if b == 0xDA {          // str16
            headerLen = 3; lenBytes = 2
        } else if b == 0xDB {          // str32
            headerLen = 5; lenBytes = 4
        } else {
            skipValue(bytes, &offset)
            return .other
        }
        guard headerLen <= bytes.count - offset else {
            offset = bytes.count
            return .other
        }
        var len = lenBytes == 0 ? Int(b & 0x1F) : 0
        if lenBytes > 0 {
            for i in 1...lenBytes { len = (len << 8) | Int(bytes[offset + i]) }
        }
        let start = offset + headerLen
        guard len <= bytes.count - start else {
            offset = bytes.count
            return .other
        }
        offset = start + len
        return .str(String(bytes: bytes[start..<(start + len)], encoding: .utf8))
    }

    // MARK: - MsgPack primitives

    private static func readMapLength(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        if b & 0xF0 == 0x80 { // fixmap
            offset += 1
            return Int(b & 0x0F)
        } else if b == 0xDE || b == 0xDF { // map16 / map32
            let n = b == 0xDE ? 2 : 4
            guard n < bytes.count - offset else { return nil }
            let len = bytes[(offset + 1)...(offset + n)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 1 + n
            return len
        }
        return nil
    }

    private static func readArrayLength(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        if b & 0xF0 == 0x90 { // fixarray
            offset += 1
            return Int(b & 0x0F)
        } else if b == 0xDC { // array16
            offset += 1
            guard offset + 2 <= bytes.count else { return nil }
            let len = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            return len
        }
        return nil
    }

    private static func readString(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        var len = 0

        if b & 0xE0 == 0xA0 { // fixstr
            len = Int(b & 0x1F)
            offset += 1
        } else if b == 0xD9 { // str8
            offset += 1
            guard offset < bytes.count else { return nil }
            len = Int(bytes[offset])
            offset += 1
        } else if b == 0xDA { // str16
            offset += 1
            guard offset + 2 <= bytes.count else { return nil }
            len = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else {
            return nil
        }

        guard offset + len <= bytes.count else { return nil }
        let data = Data(bytes[offset..<(offset + len)])
        offset += len
        return String(data: data, encoding: .utf8)
    }

    private static func readBin(_ bytes: [UInt8], _ offset: inout Int) -> Data? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        var len = 0

        if b == 0xC4 { // bin8
            offset += 1
            guard offset < bytes.count else { return nil }
            len = Int(bytes[offset])
            offset += 1
        } else if b == 0xC5 { // bin16
            offset += 1
            guard offset + 2 <= bytes.count else { return nil }
            len = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else if b == 0xC6 { // bin32
            offset += 1
            guard offset + 4 <= bytes.count else { return nil }
            len = (Int(bytes[offset]) << 24) | (Int(bytes[offset+1]) << 16) |
                  (Int(bytes[offset+2]) << 8) | Int(bytes[offset+3])
            offset += 4
        } else {
            // Try reading as string (some implementations encode bin as str)
            return readString(bytes, &offset).map { Data($0.utf8) }
        }

        guard offset + len <= bytes.count else { return nil }
        let data = Data(bytes[offset..<(offset + len)])
        offset += len
        return data
    }

    /// Read one msgpack str (fixstr/str8/str16/str32) or bin (bin8/bin16/bin32)
    /// value as UTF-8. Unlike readString, this ALWAYS consumes exactly one value:
    /// a value of any other type is skipped and yields nil, so a malformed or
    /// unexpected field can never desynchronise the keys that follow it. A
    /// length running past the buffer ends the parse (offset = end) rather than
    /// reading the next key out of the middle of this value.
    private static func readStringOrBin(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        let headerLen: Int
        let lenBytes: Int

        if b & 0xE0 == 0xA0 {                 // fixstr
            headerLen = 1; lenBytes = 0
        } else if b == 0xD9 || b == 0xC4 {    // str8 / bin8
            headerLen = 2; lenBytes = 1
        } else if b == 0xDA || b == 0xC5 {    // str16 / bin16
            headerLen = 3; lenBytes = 2
        } else if b == 0xDB || b == 0xC6 {    // str32 / bin32
            headerLen = 5; lenBytes = 4
        } else {
            skipValue(bytes, &offset)
            return nil
        }

        guard offset + headerLen <= bytes.count else {
            offset = bytes.count
            return nil
        }
        var len = 0
        if lenBytes == 0 {
            len = Int(b & 0x1F)
        } else {
            for i in 1...lenBytes { len = (len << 8) | Int(bytes[offset + i]) }
        }
        let start = offset + headerLen
        guard len <= bytes.count - start else {
            offset = bytes.count
            return nil
        }
        offset = start + len
        return String(data: Data(bytes[start..<(start + len)]), encoding: .utf8)
    }

    /// Skip exactly one msgpack value of any type, containers included,
    /// without recursion (a deeply nested value cannot exhaust the stack). A
    /// length running past the buffer ends the parse (offset = end).
    static func skipValue(_ bytes: [UInt8], _ offset: inout Int) {
        var pending = 1
        while pending > 0 {
            guard offset < bytes.count else { offset = bytes.count; return }
            pending -= 1
            let b = bytes[offset]
            /// A big-endian length of `n` bytes after the type byte, or nil
            /// when it runs past the buffer.
            func length(_ n: Int) -> Int? {
                guard n < bytes.count - offset else { return nil }
                return bytes[(offset + 1)...(offset + n)].reduce(0) { ($0 << 8) | Int($1) }
            }
            var advance: Int
            switch b {
            case 0x00...0x7F, 0xE0...0xFF, 0xC0, 0xC1, 0xC2, 0xC3:
                advance = 1                                  // fixints, nil, bools
            case 0x80...0x8F:                                // fixmap
                advance = 1; pending += 2 * Int(b & 0x0F)
            case 0x90...0x9F:                                // fixarray
                advance = 1; pending += Int(b & 0x0F)
            case 0xA0...0xBF:                                // fixstr
                advance = 1 + Int(b & 0x1F)
            case 0xC4, 0xD9:                                 // bin8, str8
                guard let n = length(1) else { offset = bytes.count; return }
                advance = 2 + n
            case 0xC5, 0xDA:                                 // bin16, str16
                guard let n = length(2) else { offset = bytes.count; return }
                advance = 3 + n
            case 0xC6, 0xDB:                                 // bin32, str32
                guard let n = length(4) else { offset = bytes.count; return }
                advance = 5 + n
            case 0xC7:                                       // ext8
                guard let n = length(1) else { offset = bytes.count; return }
                advance = 3 + n
            case 0xC8:                                       // ext16
                guard let n = length(2) else { offset = bytes.count; return }
                advance = 4 + n
            case 0xC9:                                       // ext32
                guard let n = length(4) else { offset = bytes.count; return }
                advance = 6 + n
            case 0xCA: advance = 5                           // float32
            case 0xCB: advance = 9                           // float64
            case 0xCC, 0xD0: advance = 2                     // uint8, int8
            case 0xCD, 0xD1: advance = 3                     // uint16, int16
            case 0xCE, 0xD2: advance = 5                     // uint32, int32
            case 0xCF, 0xD3: advance = 9                     // uint64, int64
            case 0xD4: advance = 3                           // fixext1
            case 0xD5: advance = 4                           // fixext2
            case 0xD6: advance = 6                           // fixext4
            case 0xD7: advance = 10                          // fixext8
            case 0xD8: advance = 18                          // fixext16
            case 0xDC, 0xDD:                                 // array16, array32
                guard let n = length(b == 0xDC ? 2 : 4) else { offset = bytes.count; return }
                advance = b == 0xDC ? 3 : 5; pending += n
            case 0xDE, 0xDF:                                 // map16, map32
                guard let n = length(b == 0xDE ? 2 : 4) else { offset = bytes.count; return }
                advance = b == 0xDE ? 3 : 5; pending += 2 * n
            default:
                advance = 1
            }
            guard advance <= bytes.count - offset else { offset = bytes.count; return }
            offset += advance
        }
    }
}

// MARK: - Display names (LXMF-rust/DISPLAY_NAMES.md)
//
// The rules the app applies to names; cleaning a name and decoding field
// 0xD1 happen once, in Rust (lxmf_display_name_clean, lxmf_display_name_decode
// and the channel unpack trailer, wrapped by LxmfClient). Foundation and
// CryptoKit only, and compiled into both the app and the Notification Service
// Extension: tests/DisplayNamesTests.swift runs it on its own.

nonisolated enum DisplayNames {

    /// A decoded 0xD1 (§3): no field, "I have no name now", or a cleaned name.
    enum NameField: Equatable {
        case absent
        case clear
        case name(String)

        /// The FFI's name_state: 0 absent, 1 clear, 2 name.
        var stateByte: UInt8 {
            switch self {
            case .absent: return 0
            case .clear:  return 1
            case .name:   return 2
            }
        }
    }

    /// `name_state u8 | name_len u16 BE | name` — the buffer of
    /// lxmf_display_name_decode and the trailer of retichat_channel_lxm_unpack.
    /// nil when malformed (a short buffer, an unknown state, a name that is
    /// empty or not UTF-8).
    static func parseNameState(_ data: Data) -> NameField? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return nil }
        let len = (Int(bytes[1]) << 8) | Int(bytes[2])
        switch bytes[0] {
        case 0: return .absent
        case 1: return .clear
        case 2:
            guard len > 0, bytes.count >= 3 + len,
                  let name = String(bytes: bytes[3..<(3 + len)], encoding: .utf8) else { return nil }
            return .name(name)
        default: return nil
        }
    }

    /// What a message's 0xD1 does to the messageName held for its LXMF source.
    enum Change: Equatable {
        /// Ignored: nothing is written, the timestamp included.
        case keep
        /// Accepted: the name becomes this (nil clears it) and messageNameAt
        /// becomes the message's timestamp, also when the name is the one
        /// already held (§5.2: a repeat advances the timestamp).
        case set(String?)
        /// Taken from a source whose key is not known yet (§5.2's weak
        /// fill): the name is written but messageNameAt is not. The
        /// timestamp is the sender's claim and nothing vouches for the
        /// sender, so recording it would let a forged message dated far
        /// ahead block every later validated name and clear from the real
        /// source until that date (review ios-order-1). The source's first
        /// validated 0xD1 newer than the last recorded one replaces it.
        case fill(String)
    }

    /// §5.2's ordering rule: a 0xD1 counts only from a message whose LXMF
    /// timestamp is newer than the one that last set or cleared the slot
    /// (`heldAt`; nil when nothing has, e.g. a name from before this rule).
    /// A timestamp that is not a finite number cannot be ordered and never
    /// counts (as on Android and the web); held, it would refuse every
    /// later message for good.
    static func isNewer(_ messageTime: Double, than heldAt: Double?) -> Bool {
        guard messageTime.isFinite else { return false }
        guard let heldAt, heldAt.isFinite else { return true }
        return messageTime > heldAt
    }

    /// §5.2. `unverifiedReason`: 0 signature validated, 1 source unknown (no
    /// key yet), anything else invalid. A validated name replaces, a
    /// validated clear clears; from an unknown source a name is only taken
    /// when none is held, and a clear is ignored; an invalid signature
    /// changes nothing. Only a message newer than `currentAt` (messageNameAt)
    /// counts: a propagated copy landing after a later direct message must
    /// not bring back the old name, which the sender's ledger never resends.
    /// A name from an unknown source is a `.fill`: it does not record its
    /// timestamp, so it cannot hold off the validated names that follow.
    static func acceptMessageName(_ field: NameField, unverifiedReason: Int, current: String?,
                                  currentAt: Double?, messageTime: Double) -> Change {
        guard isNewer(messageTime, than: currentAt) else { return .keep }
        switch (field, unverifiedReason) {
        case (.name(let s), 0):
            return .set(s)
        case (.clear, 0):
            return .set(nil)
        case (.name(let s), 1):
            return current == nil ? .fill(s) : .keep
        default:
            return .keep
        }
    }

    /// The first 8 hex characters and an ellipsis, on every client (§5.3).
    static func shortHash(_ hex: String) -> String {
        String(hex.lowercased().prefix(8)) + "\u{2026}"
    }

    /// localName ?? messageName ?? announceName, empty slots skipped; nil
    /// when the contact has no name at all.
    static func contactName(local: String?, message: String?, announce: String?) -> String? {
        contactNameAndSlot(local: local, message: message, announce: announce)?.name
    }

    /// Which slot (§5.1) a contact's resolved name came from. `legacy` is a
    /// name of unknown origin: the single name of builds before the three
    /// slots, shown until the §5.4 migration has run, or a chat_names.json
    /// entry written by such a build.
    enum NameSlot: String, Codable, Equatable {
        case local, message, announce, legacy
    }

    /// contactName, and the slot it came from.
    static func contactNameAndSlot(local: String?, message: String?,
                                   announce: String?) -> (name: String, slot: NameSlot)? {
        for (name, slot) in [(local, NameSlot.local), (message, .message), (announce, .announce)] {
            if let name, !name.isEmpty { return (name, slot) }
        }
        return nil
    }

    /// The contact resolver (§5.3): localName ?? messageName ?? announceName ?? shortHash.
    static func contactLabel(hash: String, local: String?, message: String?, announce: String?) -> String {
        contactName(local: local, message: message, announce: announce) ?? shortHash(hash)
    }

    /// A channel poster's label and, when it came from the channel name,
    /// the short hash shown beside it (channel names are public and anyone
    /// can pick any name).
    struct ChannelLabel: Equatable {
        let label: String
        let secondary: String?
    }

    /// The channel resolver (§5.3): channelName ?? (localName ?? messageName
    /// ?? announceName) ?? shortHash. `contactName` is the contact's own
    /// resolution without the hash fallback (contactName(local:message:announce:)).
    /// The secondary text is the standard shortHash ("1a2b3c4d…"), as on
    /// Android and the web.
    static func channelLabel(hash: String, channelName: String?, contactName: String?) -> ChannelLabel {
        if let channelName, !channelName.isEmpty {
            return ChannelLabel(label: channelName, secondary: shortHash(hash))
        }
        if let contactName, !contactName.isEmpty {
            return ChannelLabel(label: contactName, secondary: nil)
        }
        return ChannelLabel(label: shortHash(hash), secondary: nil)
    }

    /// The title of a channel message notification, in the app and the NSE.
    static func channelNotificationTitle(channelName: String, label: ChannelLabel) -> String {
        if let secondary = label.secondary {
            return "#\(channelName) (\(label.label) \u{00B7} \(secondary))"
        }
        return "#\(channelName) (\(label.label))"
    }

    /// First 16 bytes of SHA-256 of the cleaned name's UTF-8; no name hashes
    /// the empty string (§4.1, used by the channel rule §4.2).
    static func digest(_ name: String?) -> Data {
        Data(SHA256.hash(data: Data((name ?? "").utf8)).prefix(16))
    }

    /// CHANNEL_NAME_REFRESH_SECS (§4.2).
    static let channelNameRefreshSecs: Double = 24 * 60 * 60

    /// §4.2: whether a channel post carries the Channel Display Name.
    /// `current` is the cleaned Channel Display Name (nil when unset);
    /// `lastDigest`/`lastIncludedAt` the persisted state of the channel;
    /// `newSenderSinceIncluded` whether a sender not seen before has posted
    /// in the channel since the name was last included. Times in seconds.
    static func channelPostName(current: String?, lastDigest: Data?, lastIncludedAt: Double?,
                                newSenderSinceIncluded: Bool, now: Double) -> NameField {
        guard let current, !current.isEmpty else {
            // Unset: clear once, only if a real name went out last.
            if let lastDigest, lastDigest != digest(nil) { return .clear }
            return .absent
        }
        if lastDigest != digest(current) { return .name(current) }
        if newSenderSinceIncluded { return .name(current) }
        guard let lastIncludedAt else { return .name(current) }
        return now - lastIncludedAt > channelNameRefreshSecs ? .name(current) : .absent
    }

    /// Where a name from before the three slots goes (§5.4, iOS).
    enum LegacyName: Equatable {
        case drop
        case announceName(String)
        case localName(String)
    }

    /// §5.4: a placeholder is dropped; a value equal to the contact's
    /// recalled announce name becomes announceName; anything else is a
    /// name the user typed (iOS had no rename flag) and becomes localName.
    /// iOS has no legacyName slot: its mapping is the spec's iOS rule.
    static func migrateLegacyName(_ value: String, hash: String, recalledAnnounceName: String?) -> LegacyName {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPlaceholder(trimmed, ownHash: hash) { return .drop }
        if let recalled = recalledAnnounceName, !recalled.isEmpty, recalled == trimmed {
            return .announceName(recalled)
        }
        return .localName(trimmed)
    }

    /// The placeholder names of §5.4, all case-insensitive: "Retichat",
    /// "Retichat Web" (what unnamed Android and web senders used to send),
    /// "Anonymous Peer" (MeshChatX's, Columba's and lxmd's announce).
    static let placeholderNames: Set<String> = ["retichat", "retichat web", "anonymous peer"]

    /// §5.4's placeholder test: a hash form of the contact's OWN hash (8 to
    /// 32 hex digits that prefix `ownHash`, with or without a leading "?" or a
    /// trailing "…") or one of `placeholderNames`, case-insensitive,
    /// surrounding white space ignored. Empty is no name at all, so it is
    /// dropped too. iOS cannot tell a typed name from a received one, so other
    /// hex ("deadbeef", "20260927") may have been typed and is kept, as the
    /// Android and web migrations keep hex a user typed.
    static func isPlaceholder(_ value: String, ownHash: String) -> Bool {
        var v = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if v.isEmpty { return true }
        if placeholderNames.contains(String(v)) { return true }
        if v.hasPrefix("?") { v = v.dropFirst() }
        if v.hasSuffix("\u{2026}") { v = v.dropLast() }
        guard (8...32).contains(v.count), v.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
        return ownHash.lowercased().hasPrefix(String(v))
    }

    // MARK: Notification Service Extension

    /// One contact's entry in chat_names.json, the app's names shared with
    /// the NSE: the resolved name, the slot it came from, and the contact's
    /// messageNameAt (§5.2), so the NSE can apply the accept rules to a
    /// message the app has not imported yet.
    ///
    /// Written as {"name": …, "slot": "local"|"message"|"announce"|"legacy",
    /// "messageNameAt": …}. Files from builds before the slot kind hold a
    /// bare string per contact; it still reads, as a `legacy` name.
    struct SharedName: Equatable, Codable {
        let name: String
        let slot: NameSlot
        var messageNameAt: Double? = nil

        init(name: String, slot: NameSlot, messageNameAt: Double? = nil) {
            self.name = name
            self.slot = slot
            self.messageNameAt = messageNameAt
        }

        private enum CodingKeys: String, CodingKey { case name, slot, messageNameAt }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let old = try? single.decode(String.self) {
                self.init(name: old, slot: .legacy)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      slot: (try? c.decode(NameSlot.self, forKey: .slot)) ?? .legacy,
                      messageNameAt: try c.decodeIfPresent(Double.self, forKey: .messageNameAt))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(slot, forKey: .slot)
            try c.encodeIfPresent(messageNameAt, forKey: .messageNameAt)
        }
    }

    /// The NSE's title for a message from `hash`, sent at `messageTime`
    /// (its LXMF timestamp). It has no store, only what the app shares:
    /// `appName` is the app's entry for the contact (chat_names.json; nil
    /// when the contact has no name). The resolver's order, with the
    /// message's own 0xD1 applied as the app will apply it on import:
    /// - the user's localName (or a legacy name of unknown origin) wins;
    /// - otherwise the §5.2 rules run against the app's messageName (known
    ///   only when that is the name shown) and messageNameAt: a validated
    ///   name, or a first name from an unknown source, beats the app's
    ///   message or announce name; a validated clear drops the app's
    ///   message name;
    /// - then the announce name (the app's, else the recalled one);
    /// - then shortHash.
    static func notificationName(hash: String, appName: SharedName?, messageName: NameField,
                                 unverifiedReason: Int, messageTime: Double, announceName: String?) -> String {
        if let appName, appName.slot == .local || appName.slot == .legacy, !appName.name.isEmpty {
            return appName.name
        }
        let heldMessage = appName?.slot == .message ? appName?.name : nil
        var message = heldMessage
        switch acceptMessageName(messageName, unverifiedReason: unverifiedReason,
                                 current: heldMessage, currentAt: appName?.messageNameAt,
                                 messageTime: messageTime) {
        case .set(let accepted): message = accepted
        case .fill(let accepted): message = accepted
        case .keep: break
        }
        if let message, !message.isEmpty { return message }
        let appAnnounce = appName?.slot == .announce ? appName?.name : nil
        for name in [appAnnounce, announceName] {
            if let name, !name.isEmpty { return name }
        }
        return shortHash(hash)
    }

    /// What a lookup in the announce cache does to a contact's announceName
    /// (§5.1). The cache is the Rust side's record of the last validated
    /// announce, written before the announce callback runs, so a hit that
    /// differs is a newer announce the app missed (one heard before the
    /// callbacks were wired) and replaces the stored name. A miss is not an
    /// announce without a name (the recall cannot tell the two apart), so it
    /// changes nothing. Neither does a hit when an announce from the contact
    /// was handled after the lookup began: that announce is at least as new.
    static func announceNameFromCache(recalled: String?, stored: String?, announcedSinceLookup: Bool) -> Change {
        guard !announcedSinceLookup, let recalled, !recalled.isEmpty, recalled != stored else { return .keep }
        return .set(recalled)
    }

    /// One sender's channelName in one channel as the app shares it with
    /// the NSE (channel_sender_names.json): the name (nil once cleared)
    /// and `atMs`, the post time that last set or cleared it (the app's
    /// ChannelSenderEntity.channelNameAtMs), so the NSE applies §5.2's
    /// ordering as the app does. Written as {"name": …, "atMs": …}; files
    /// from builds before the time hold a bare name, which still reads,
    /// with no time.
    struct SharedChannelName: Equatable, Codable {
        let name: String?
        var atMs: Double? = nil

        init(name: String?, atMs: Double? = nil) {
            self.name = name
            self.atMs = atMs
        }

        private enum CodingKeys: String, CodingKey { case name, atMs }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let old = try? single.decode(String.self) {
                self.init(name: old)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decodeIfPresent(String.self, forKey: .name),
                      atMs: try c.decodeIfPresent(Double.self, forKey: .atMs))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(atMs, forKey: .atMs)
        }
    }

    /// A sender's channelName once a post from `postMs` is seen (the NSE's
    /// title; the app's own rule is RfedChannelClient.noteSender): a post
    /// newer than the one that set or cleared the stored name (§5.2, per
    /// channel and sender) replaces it with its own name or clear; an older
    /// post, or one without 0xD1, leaves the stored name.
    static func channelName(afterPost post: NameField, postMs: Double, stored: SharedChannelName?) -> String? {
        guard post != .absent, isNewer(postMs, than: stored?.atMs) else { return stored?.name }
        switch post {
        case .name(let name): return name
        case .clear, .absent: return nil
        }
    }

    // MARK: Distro unwrap

    /// retichat_distro_unwrap's display_name_state / display_name (0 absent,
    /// 1 clear, 2 name; the name null unless 2). Missing keys (an older FFI
    /// build) and anything malformed read as absent.
    static func distroNameField(state: Int?, name: String?) -> NameField {
        switch state {
        case 1: return .clear
        case 2:
            if let name, !name.isEmpty { return .name(name) }
            return .absent
        default: return .absent
        }
    }

    /// The unwrap's signature result as a §5.2 reason: 0 when validated,
    /// else its unverified_reason; a message not validated without one is
    /// invalid (2), which never lets a name through.
    static func distroReason(validated: Bool?, unverifiedReason: Int?) -> Int {
        if validated == true { return 0 }
        if let reason = unverifiedReason, reason == 1 || reason == 2 { return reason }
        return 2
    }

    // MARK: System messages

    /// Stands for the message's senderHash in a stored system message
    /// ("… joined the group"): the name is resolved when the message is
    /// shown, never frozen into the stored text (§5.3).
    static let subjectToken = "\u{FFFC}"

    /// Id prefixes of the system messages that hold a subjectToken: the
    /// group invite, accept and leave notices. Only these are named when
    /// shown. A received message can contain U+FFFC itself (iOS leaves one
    /// where an attachment was in text copied from Notes or Mail), and a
    /// message id is its hex hash, which never has one of these prefixes.
    static let systemMessageIdPrefixes = ["inv_", "acc_", "left_"]

    static func isSystemMessageId(_ id: String) -> Bool {
        systemMessageIdPrefixes.contains { id.hasPrefix($0) }
    }

    /// A system message's text with its subject in place of the token: the
    /// first one only, the subject's place in every template (an invite's
    /// group name, which the inviter chose, follows it). Any other message
    /// is returned as stored.
    static func systemText(_ template: String, messageId: String, subject: String) -> String {
        guard isSystemMessageId(messageId),
              let range = template.range(of: subjectToken) else { return template }
        return template.replacingCharacters(in: range, with: subject)
    }
}

// MARK: - Channel unpack output

/// The output of retichat_channel_lxm_unpack (CRetichatFFI.h), read by the
/// app (RetichatBridge.channelLxmUnpack) and the NSE (NSEChannelUnpackDecoder):
/// source(16) | timestamp_ms u64 BE | sig_ok u8 | reason u8 | title_len u16 BE |
/// content_len u32 BE | title | content | name_state u8 | name_len u16 BE | name.
/// The trailer is the post's Channel Display Name (DISPLAY_NAMES.md §2.3),
/// reported by the Rust side only when the signature validated.
nonisolated enum ChannelUnpackLayout {
    struct Message: Equatable {
        let sourceHash: Data
        let timestampMs: UInt64
        let signatureValidated: Bool
        /// 0 = ok, 1 = SOURCE_UNKNOWN, 2 = SIGNATURE_INVALID.
        let unverifiedReason: UInt8
        let title: Data
        let content: Data
        let displayName: DisplayNames.NameField
    }

    static func decode(_ raw: Data) -> Message? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 32 else { return nil }
        func uint(_ from: Int, _ count: Int) -> Int {
            bytes[from..<(from + count)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let titleLen = uint(26, 2)
        let contentLen = uint(28, 4)
        let end = 32 + titleLen + contentLen
        guard bytes.count >= end else { return nil }
        let timestamp = bytes[16..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let validated = bytes[24] == 1
        // A name is taken only from a validated post, whatever the trailer says.
        let name = validated ? (DisplayNames.parseNameState(Data(bytes[end...])) ?? .absent) : .absent
        return Message(
            sourceHash: Data(bytes[0..<16]),
            timestampMs: timestamp,
            signatureValidated: validated,
            unverifiedReason: bytes[25],
            title: Data(bytes[32..<(32 + titleLen)]),
            content: Data(bytes[(32 + titleLen)..<end]),
            displayName: name)
    }
}
