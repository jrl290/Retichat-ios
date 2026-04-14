//
//  LxmfFields.swift
//  Retichat
//
//  Minimal msgpack decoder for LXMF fields.
//  Mirrors the Android LxmfFields.kt implementation.
//

import Foundation

// MARK: - LXMF field keys
//
// Key numbers are aligned with the Android implementation to ensure
// cross-platform interoperability.

enum LxmfFieldKey {
    static let fileAttachments: UInt8 = 0x05
    // Group chat fields
    static let groupId:        UInt8 = 0xA0  // string: 32-char hex group identifier
    static let groupMembers:   UInt8 = 0xA1  // string: comma-sep hex hashes of ALL members (invite only)
    static let groupName:      UInt8 = 0xA2  // string: human-readable group name
    static let groupAction:    UInt8 = 0xA3  // string: "invite"|"accept"|"leave"|"relay_req"|"relay_done"
    static let groupSender:    UInt8 = 0xA4  // string: original sender hex (may differ from LXMF src)
    static let groupRelaySeen: UInt8 = 0xA5  // string: comma-sep hashes already delivered to
    static let groupRelayFor:  UInt8 = 0xA6  // string: hash of member being relayed for (relay request)
    static let groupRelayDone: UInt8 = 0xA7  // bool:   relay-complete confirmation signal
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
    // Group fields
    var groupId: String?
    var groupMembers: [String]?      // full member list (invite messages only)
    var groupName: String?
    var groupAction: String?         // nil = regular group message
    var groupSender: String?         // original sender's hex hash
    var groupRelaySeen: [String]?    // hashes that have already received this relay
    var groupRelayFor: String?       // hash of member requesting relay
    var groupRelayDone: Bool?        // relay-complete signal
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

        for _ in 0..<mapCount {
            guard let key = readUInt(bytes, &offset) else { break }

            switch UInt8(key) {
            case LxmfFieldKey.fileAttachments:
                if let arrLen = readArrayLength(bytes, &offset) {
                    var attachments: [(String, Data)] = []
                    for _ in 0..<arrLen {
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
                }

            case LxmfFieldKey.groupId:
                fields.groupId = readString(bytes, &offset)

            case LxmfFieldKey.groupMembers:
                // Encoded as a comma-separated string (Android-compatible)
                if let raw = readString(bytes, &offset) {
                    fields.groupMembers = raw.split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }

            case LxmfFieldKey.groupName:
                fields.groupName = readString(bytes, &offset)

            case LxmfFieldKey.groupAction:
                fields.groupAction = readString(bytes, &offset)

            case LxmfFieldKey.groupSender:
                fields.groupSender = readString(bytes, &offset)

            case LxmfFieldKey.groupRelaySeen:
                // Comma-separated list of hashes already delivered to
                if let raw = readString(bytes, &offset) {
                    fields.groupRelaySeen = raw.split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }

            case LxmfFieldKey.groupRelayFor:
                fields.groupRelayFor = readString(bytes, &offset)

            case LxmfFieldKey.groupRelayDone:
                fields.groupRelayDone = readBool(bytes, &offset)

            default:
                skipValue(bytes, &offset)
            }
        }

        return fields
    }

    // MARK: - MsgPack primitives

    private static func readMapLength(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        if b & 0x80 == 0x80 && b & 0xF0 == 0x80 { // fixmap
            offset += 1
            return Int(b & 0x0F)
        } else if b == 0xDE { // map16
            offset += 1
            guard offset + 2 <= bytes.count else { return nil }
            let len = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
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

    private static func readUInt(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        if b & 0x80 == 0 { // positive fixint
            offset += 1
            return UInt64(b)
        } else if b == 0xCC { // uint8
            offset += 1
            guard offset < bytes.count else { return nil }
            let v = UInt64(bytes[offset])
            offset += 1
            return v
        } else if b == 0xCD { // uint16
            offset += 1
            guard offset + 2 <= bytes.count else { return nil }
            let v = (UInt64(bytes[offset]) << 8) | UInt64(bytes[offset + 1])
            offset += 2
            return v
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

    private static func readBool(_ bytes: [UInt8], _ offset: inout Int) -> Bool? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        offset += 1
        if b == 0xC3 { return true }
        if b == 0xC2 { return false }
        return nil
    }

    private static func skipValue(_ bytes: [UInt8], _ offset: inout Int) {
        guard offset < bytes.count else { return }
        let b = bytes[offset]

        // nil
        if b == 0xC0 { offset += 1; return }
        // bool
        if b == 0xC2 || b == 0xC3 { offset += 1; return }
        // positive fixint
        if b & 0x80 == 0 { offset += 1; return }
        // negative fixint
        if b & 0xE0 == 0xE0 { offset += 1; return }
        // fixstr
        if b & 0xE0 == 0xA0 {
            let len = Int(b & 0x1F)
            offset += 1 + len; return
        }
        // fixmap
        if b & 0xF0 == 0x80 {
            let count = Int(b & 0x0F)
            offset += 1
            for _ in 0..<(count * 2) { skipValue(bytes, &offset) }
            return
        }
        // fixarray
        if b & 0xF0 == 0x90 {
            let count = Int(b & 0x0F)
            offset += 1
            for _ in 0..<count { skipValue(bytes, &offset) }
            return
        }

        switch b {
        case 0xCC: offset += 2  // uint8
        case 0xCD: offset += 3  // uint16
        case 0xCE: offset += 5  // uint32
        case 0xCF: offset += 9  // uint64
        case 0xD0: offset += 2  // int8
        case 0xD1: offset += 3  // int16
        case 0xD2: offset += 5  // int32
        case 0xD3: offset += 9  // int64
        case 0xCA: offset += 5  // float32
        case 0xCB: offset += 9  // float64
        case 0xD9: // str8
            offset += 1
            guard offset < bytes.count else { return }
            offset += 1 + Int(bytes[offset])
        case 0xDA: // str16
            offset += 1
            guard offset + 2 <= bytes.count else { return }
            let len = (Int(bytes[offset]) << 8) | Int(bytes[offset+1])
            offset += 2 + len
        case 0xC4: // bin8
            offset += 1
            guard offset < bytes.count else { return }
            offset += 1 + Int(bytes[offset])
        case 0xC5: // bin16
            offset += 1
            guard offset + 2 <= bytes.count else { return }
            let len = (Int(bytes[offset]) << 8) | Int(bytes[offset+1])
            offset += 2 + len
        default:
            offset += 1 // skip unknown
        }
    }
}
