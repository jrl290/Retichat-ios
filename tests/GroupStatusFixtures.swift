// GroupStatusFixtures.swift
//
// What tests/GroupStatusesTests.swift and tests/GroupStatusVectorsTests.swift stand on
// (Retichat-android's GroupStatusFixtures.kt): the shared vectors (LXMF-rust
// tests/group_status_vectors.json, copied to rust/retichat-ffi/tests/data/, where a
// cargo test holds the copy to LXMF-rust's own), a native layer that checks REAL
// Ed25519 signatures over REAL packed messages as the glue crate does
// (rust/retichat-ffi/src/group_status.rs: the router's check under a key held for the
// source, then the key an accept or leave carries for its own sender), a store in
// memory, a builder for LXMF messages signed by the vectors' identities (whoever signs a
// message may be someone else than its source: that is how a forgery is made), and a
// rig that hands a packed message through the group rule and the engine as
// ChatRepository does.
//
// The builder is held to the vectors: it reproduces their packed bytes exactly.

import CryptoKit
import Foundation

// The app's Data hex helper (PropagationNodeManager.swift needs the whole app).
extension Data {
    nonisolated var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Checks

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

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

func unhex(_ s: String) -> Data {
    Data((0..<s.count / 2).map { i in
        let at = s.index(s.startIndex, offsetBy: 2 * i)
        return UInt8(s[at..<s.index(at, offsetBy: 2)], radix: 16)!
    })
}

// MARK: - The vectors

struct VIdentity {
    let name: String
    let displayName: String
    let hash: Data
    let hashHex: String
    let publicKey: Data
    let seed: Data
    let keyEntry: String
}

struct VMessage {
    let name: String
    let action: String
    let source: String
    let destination: String
    let signedBy: String
    let keyEntryHashOf: String?
    let form: String
    let packed: Data
    let fieldsRaw: Data
    let messageHash: Data
    let timestamp: Double
    let carriesKeyOf: String?
    let verdict: [String: String]
    let before: [String: String]
    let from: [String: String]
    let creatorAnswers: Bool
}

struct VStatus {
    let name: String
    let form: String
    let timestamp: Double
    let source: String
    let destination: String
    let packed: Data
    let fieldsRaw: Data
    let groupEntries: [String: String]
    let members: [(member: String, message: String)]
}

struct VOutcome {
    let status: String
    let receiver: String
    let holds: [String]
    let switchName: String
    let elements: [(member: String, message: String, verdict: String, outcome: String)]
    let after: [String: String]
    let held: [(member: String, action: String)]
}

struct Vectors {
    let identities: [String: VIdentity]
    let groupId: String
    let creator: String
    let members: [String]
    let messages: [VMessage]
    let statuses: [VStatus]
    let outcomes: [VOutcome]
    let raw: Data

    func hashOf(_ name: String) -> String { identities[name]!.hashHex }
    func nameOf(_ hex: String) -> String { identities.values.first { $0.hashHex == hex }?.name ?? String(hex.prefix(8)) }
    func message(_ name: String) -> VMessage { messages.first { $0.name == name }! }
    func status(_ name: String) -> VStatus { statuses.first { $0.name == name }! }

    static func load() -> Vectors {
        let url = root.appendingPathComponent("rust/retichat-ffi/tests/data/group_status_vectors.json")
        guard let raw = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            fatalError("the vectors are not readable at \(url.path)")
        }
        var identities: [String: VIdentity] = [:]
        for spec in json["identities"] as! [[String: Any]] {
            let name = spec["name"] as! String
            let privateKey = unhex(spec["private_key_hex"] as! String)
            identities[name] = VIdentity(
                name: name, displayName: spec["display_name"] as! String,
                hash: unhex(spec["lxmf_delivery_hash_hex"] as! String),
                hashHex: spec["lxmf_delivery_hash_hex"] as! String,
                publicKey: unhex(spec["public_key_hex"] as! String),
                seed: privateKey.suffix(32), keyEntry: spec["key_entry"] as! String)
        }
        let group = json["group"] as! [String: Any]
        func dict(_ any: Any?) -> [String: String] { (any as? [String: String]) ?? [:] }
        let messages = (json["messages"] as! [[String: Any]]).map { m in
            VMessage(name: m["name"] as! String, action: m["action"] as! String, source: m["source"] as! String,
                     destination: m["destination"] as! String, signedBy: m["signed_by"] as! String,
                     keyEntryHashOf: m["key_entry_hash_of"] as? String, form: m["form"] as! String, packed: unhex(m["packed_hex"] as! String),
                     fieldsRaw: unhex(m["fields_msgpack_hex"] as! String),
                     messageHash: unhex(m["message_hash_hex"] as! String), timestamp: m["timestamp"] as! Double,
                     carriesKeyOf: m["carries_key_of"] as? String, verdict: dict(m["verdict"]),
                     before: dict(m["outcome_before_switch"]), from: dict(m["outcome_from_switch"]),
                     creatorAnswers: m["creator_answers"] as! Bool)
        }
        let statuses = (json["statuses"] as! [[String: Any]]).map { s in
            VStatus(name: s["name"] as! String, form: s["form"] as! String, timestamp: s["timestamp"] as! Double,
                    source: s["source"] as! String,
                    destination: s["destination"] as! String, packed: unhex(s["packed_hex"] as! String),
                    fieldsRaw: unhex(s["fields_msgpack_hex"] as! String),
                    groupEntries: dict(s["group_entries"]),
                    members: (s["statuses"] as! [[String: String]]).map { ($0["member"]!, $0["message"]!) })
        }
        let outcomes = (json["receiver_outcomes"] as! [[String: Any]]).map { o in
            VOutcome(status: o["status"] as! String, receiver: o["receiver"] as! String,
                     holds: o["holds_keys_of"] as! [String], switchName: o["switch"] as! String,
                     elements: (o["elements"] as! [[String: String]]).map { ($0["member"]!, $0["message"]!, $0["verdict"]!, $0["outcome"]!) },
                     after: o["member_status_after"] as! [String: String],
                     held: (o["held_after"] as! [[String: String]]).map { ($0["member"]!, $0["action"]!) })
        }
        return Vectors(identities: identities, groupId: group["group_id"] as! String, creator: group["creator"] as! String,
                       members: group["members"] as! [String], messages: messages, statuses: statuses,
                       outcomes: outcomes, raw: raw)
    }
}

// MARK: - msgpack, as much as an LXMF message needs

enum MP {
    static func str(_ s: String) -> Data {
        let b = Data(s.utf8)
        if b.count < 32 { return Data([0xA0 | UInt8(b.count)]) + b }
        if b.count < 256 { return Data([0xD9, UInt8(b.count)]) + b }
        return Data([0xDA, UInt8(b.count >> 8), UInt8(b.count & 0xFF)]) + b
    }

    static func bin(_ d: Data) -> Data {
        if d.count < 256 { return Data([0xC4, UInt8(d.count)]) + d }
        return Data([0xC5, UInt8(d.count >> 8), UInt8(d.count & 0xFF)]) + d
    }

    static func uint(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        return Data([0xCC, UInt8(n)])
    }

    static func f64(_ x: Double) -> Data {
        var out = Data([0xCB])
        var bits = x.bitPattern
        var bytes: [UInt8] = []
        for _ in 0..<8 { bytes.insert(UInt8(bits & 0xFF), at: 0); bits >>= 8 }
        out.append(contentsOf: bytes)
        return out
    }

    static func array(_ items: [Data]) -> Data {
        let head: Data = items.count < 16 ? Data([0x90 | UInt8(items.count)])
            : Data([0xDC, UInt8(items.count >> 8), UInt8(items.count & 0xFF)])
        return items.reduce(head) { $0 + $1 }
    }

    static func map(_ entries: [(Data, Data)]) -> Data {
        let head = Data([0x80 | UInt8(entries.count)])
        return entries.reduce(head) { $0 + $1.0 + $1.1 }
    }

    /// The length of the msgpack value at the start of `bytes[at...]`, no deeper than the shapes an LXMF message has.
    static func length(_ b: [UInt8], at: Int) -> Int {
        var pending = 1
        var i = at
        while pending > 0 {
            let t = b[i]
            pending -= 1
            func len(_ n: Int) -> Int { b[(i + 1)...(i + n)].reduce(0) { ($0 << 8) | Int($1) } }
            switch t {
            case 0x00...0x7F, 0xE0...0xFF, 0xC0, 0xC2, 0xC3: i += 1
            case 0xCC, 0xD0: i += 2
            case 0xCD, 0xD1: i += 3
            case 0xCE, 0xD2, 0xCA: i += 5
            case 0xCF, 0xD3, 0xCB: i += 9
            case 0xA0...0xBF: i += 1 + Int(t & 0x1F)
            case 0xD9, 0xC4: i += 2 + len(1)
            case 0xDA, 0xC5: i += 3 + len(2)
            case 0x80...0x8F: i += 1; pending += 2 * Int(t & 0x0F)
            case 0x90...0x9F: i += 1; pending += Int(t & 0x0F)
            case 0xDC: let n = len(2); i += 3; pending += n
            case 0xDE: let n = len(2); i += 3; pending += 2 * n
            default: fatalError("msgpack type \(t) is not one a message here has")
            }
        }
        return i - at
    }
}

// MARK: - LXMF messages, as the glue reads them

enum TestLxmf {
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    /// The `lxmf.delivery` destination hash of a 64-byte public key.
    static func deliveryHash(_ publicKey: Data) -> Data {
        let identityHash = sha256(publicKey).prefix(16)
        let nameHash = sha256(Data("lxmf.delivery".utf8)).prefix(10)
        return sha256(nameHash + identityHash).prefix(16)
    }

    /// The group entries of an accept, leave or status, in the old fields or in the Retichat field, and the sender's name.
    static func groupFields(retichat: Bool, groupId: String, action: String, sender: String, keyEntry: String?,
                            displayName: String, elements: [Data]? = nil) -> Data {
        let name = MP.bin(Data(displayName.utf8))
        if retichat {
            var entries: [(Data, Data)] = [(MP.uint(0), name), (MP.uint(1), MP.str(groupId)),
                                           (MP.uint(4), MP.str(action)), (MP.uint(5), MP.str(sender))]
            if let keyEntry { entries.append((MP.uint(9), MP.str(keyEntry))) }
            if let elements { entries.append((MP.uint(10), MP.array(elements.map { MP.bin($0) }))) }
            return MP.map([(MP.uint(0xD1), MP.map(entries))])
        }
        var entries: [(Data, Data)] = [(MP.uint(0xA0), MP.str(groupId)), (MP.uint(0xA3), MP.str(action)),
                                       (MP.uint(0xA4), MP.str(sender))]
        if let keyEntry { entries.append((MP.uint(0xA8), MP.str(keyEntry))) }
        entries.append((MP.uint(0xD1), MP.map([(MP.uint(0), name)])))
        if let elements {
            // Key 10 has no old field: it goes in the Retichat field in both forms.
            entries.removeLast()
            entries.append((MP.uint(0xD1), MP.map([(MP.uint(0), name), (MP.uint(10), MP.array(elements.map { MP.bin($0) }))])))
        }
        return MP.map(entries)
    }

    /// `destination | source | signature | payload`, signed by `signer` as LXMessage.py signs it. A stamp (a
    /// fifth element) is not signed.
    static func pack(signer: VIdentity, from: VIdentity, to: VIdentity, fields: Data, at: Double,
                     content: Data = Data(), stamp: Bool = false) -> Data {
        let core = MP.array([MP.f64(at), MP.bin(Data()), MP.bin(content)]).dropFirst() + fields
        let fourElements = Data([0x94]) + core
        let signed = to.hash + from.hash + fourElements
        let signature = try! Curve25519.Signing.PrivateKey(rawRepresentation: signer.seed)
            .signature(for: signed + sha256(signed))
        let payload = stamp ? Data([0x95]) + core + MP.bin(Data(repeating: 0x5a, count: 32)) : fourElements
        return to.hash + from.hash + signature + payload
    }
}

// MARK: - The native layer, with real signatures

/// The glue crate's checks (`group_status::unpack_element_with` and `receipt`) over real Ed25519, for a receiver
/// holding the keys of `know`n identities (and of every key remembered through `rememberKey`).
@MainActor
final class FakeGroupNative: GroupNative {
    private var keys: [String: Data] = [:]      // lxmf.delivery hash (hex) -> public key
    private(set) var remembered: [String] = []
    private(set) var unpacked = 0

    func know(_ identity: VIdentity) { keys[identity.hashHex] = identity.publicKey }
    func holds(_ hex: String) -> Bool { keys[hex] != nil }

    func valid(_ packed: Data, under key: Data) -> Bool? {
        let b = [UInt8](packed)
        guard b.count > GroupStatuses.packedHeaderLength else { return nil }
        let payloadAt = GroupStatuses.packedHeaderLength
        guard b[payloadAt] & 0xF0 == 0x90 || b[payloadAt] == 0xDC else { return nil }
        let header = b[payloadAt] == 0xDC ? 3 : 1
        var at = payloadAt + header
        for _ in 0..<4 { at += MP.length(b, at: at) }
        let core = Data(b[(payloadAt + header)..<at])
        let signed = Data(b[0..<32]) + Data([0x94]) + core
        guard let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: key.suffix(32)) else { return false }
        return verifier.isValidSignature(Data(b[32..<96]), for: signed + TestLxmf.sha256(signed))
    }

    /// An element of a status, or an entry held, as the glue unpacks it. Nil for what is no LXMF message of an accept's size.
    func unpack(_ packed: Data) -> UnpackedGroupMessage? {
        unpacked += 1
        guard packed.count > GroupStatuses.packedHeaderLength, packed.count <= GroupStatuses.statusPackedLimit else { return nil }
        return receipt(packed)
    }

    /// What the delivery callback reports of a message the router has delivered (`group_status::receipt`): the same checks, of
    /// a message of any size (the router took it whole; only the copy a creator keeps is limited).
    func receipt(_ packed: Data) -> UnpackedGroupMessage? {
        guard packed.count > GroupStatuses.packedHeaderLength else { return nil }
        let b = [UInt8](packed)
        let src = Data(b[16..<32])
        let payloadAt = GroupStatuses.packedHeaderLength
        guard b[payloadAt] & 0xF0 == 0x90 || b[payloadAt] == 0xDC else { return nil }
        let header = b[payloadAt] == 0xDC ? 3 : 1
        var at = payloadAt + header
        let timestampAt = at
        for _ in 0..<3 { at += MP.length(b, at: at) }
        let fieldsAt = at
        at += MP.length(b, at: at)
        let core = Data(b[(payloadAt + header)..<at])
        guard b[timestampAt] == 0xCB else { return nil }
        var bits: UInt64 = 0
        for byte in b[(timestampAt + 1)...(timestampAt + 8)] { bits = (bits << 8) | UInt64(byte) }
        let fieldsRaw = Data(b[fieldsAt..<at])
        let signed = Data(b[0..<32]) + Data([0x94]) + core
        let hash = TestLxmf.sha256(signed)

        var signature = DeliveryPolicy.Signature.sourceUnknown
        if let key = keys[src.hexString] {
            signature = (valid(packed, under: key) ?? false) ? DeliveryPolicy.Signature.validated : DeliveryPolicy.Signature.invalid
        }
        // The key an accept or leave carries for its own sender, when it binds; a source nobody held a key for
        // is then checked under it.
        let fields = LxmfFieldsDecoder.decode(fieldsRaw)
        var senderKey: Data?
        if fields.groupId != nil, fields.groupAction == GroupAction.accept || fields.groupAction == GroupAction.leave,
           let entry = fields.groupMemberKeys?[src.hexString], let key = Data(base64Encoded: entry), key.count == 64,
           TestLxmf.deliveryHash(key) == src {
            senderKey = key
            if signature == DeliveryPolicy.Signature.sourceUnknown {
                signature = (valid(packed, under: key) ?? false) ? DeliveryPolicy.Signature.validated : DeliveryPolicy.Signature.invalid
            }
        }
        return UnpackedGroupMessage(signature: signature, destination: Data(b[0..<16]), source: src, hash: hash,
                                    timestamp: Double(bitPattern: bits), senderKey: senderKey, fieldsRaw: fieldsRaw)
    }

    func rememberKey(memberHex: String, publicKey: Data) -> Bool {
        guard publicKey.count == 64, TestLxmf.deliveryHash(publicKey).hexString == memberHex else { return false }
        keys[memberHex] = publicKey
        remembered.append(memberHex)
        return true
    }
}

// MARK: - The store, in memory

@MainActor
final class MemoryGroupStatusStore: GroupStatusStore {
    var chats: [String: GroupChatInfo] = [:]
    var memberRows: [String: [GroupMemberStatuses.Row]] = [:]
    var lines: [(chat: String, member: String, joined: Bool, id: String, timestamp: Double)] = []
    var allowed: [String] = []
    var copyRows: [String: [String: StatusCopy]] = [:]
    var heldRows: [HeldEntry] = []
    var watched: [(member: String, watch: Bool)] = []

    func chat(id groupId: String) -> GroupChatInfo? { chats[groupId] }
    func members(chatId: String) -> [GroupMemberStatuses.Row] { memberRows[chatId] ?? [] }

    func setMemberStatus(chatId: String, memberHex: String, status: String) {
        memberRows[chatId] = members(chatId: chatId).map { $0.hash == memberHex ? (hash: $0.hash, status: status) : $0 }
        watched.append((memberHex, status == MemberStatus.accepted))
    }

    func memberLine(chatId: String, memberHex: String, joined: Bool, id: String, timestamp: Double) {
        lines.append((chatId, memberHex, joined, id, timestamp))
    }

    func allow(memberHex: String) { allowed.append(memberHex) }
    func statusOf(_ chat: String, _ hex: String) -> String? { GroupMemberStatuses.statusOf(members(chatId: chat), hex) }
    func copy(chatId: String, memberHex: String) -> StatusCopy? { copyRows[chatId]?[memberHex] }

    func putCopy(chatId: String, memberHex: String, action: String, packed: Data) {
        copyRows[chatId, default: [:]][memberHex] = StatusCopy(memberHex: memberHex, action: action, packed: packed)
    }

    func copies(chatId: String) -> [StatusCopy] { (copyRows[chatId] ?? [:]).values.sorted { $0.memberHex < $1.memberHex } }
    func held() -> [HeldEntry] { heldRows }
    func heldCount() -> Int { heldRows.count }
    func heldCount(chatId: String, srcHex: String) -> Int { heldRows.filter { $0.chatId == chatId && $0.srcHex == srcHex }.count }
    func heldCount(srcHex: String) -> Int { heldRows.filter { $0.srcHex == srcHex }.count }
    func isHeld(msgHash: String) -> Bool { heldRows.contains { $0.msgHash == msgHash } }
    func hold(_ entry: HeldEntry) { heldRows.append(entry) }
    func release(_ entry: HeldEntry) { heldRows.removeAll { $0.msgHash == entry.msgHash } }
}

// MARK: - The rig

struct Answer {
    let chat: String
    let to: String
    let statuses: [Data]
}

/// A device, `me`, that holds the vectors' group, and what reaches it: a packed message through the group rule and the
/// engine, as ChatRepository does.
@MainActor
final class GroupRig {
    let v: Vectors
    let me: String
    let native = FakeGroupNative()
    let store = MemoryGroupStatusStore()
    var answers: [Answer] = []
    var logs: [String] = []
    let selfHex: String
    var engine: GroupStatusEngine!
    /// What the rule dropped: the action and the source's name.
    var dropped: [String] = []
    /// The tally of the last `status` the rule let through.
    var lastTally: StatusTally?

    init(_ v: Vectors, me: String, switched: Bool = false, holds: [String] = []) {
        self.v = v
        self.me = me
        self.selfHex = v.hashOf(me)
        let hex = selfHex
        engine = GroupStatusEngine(
            store: store, native: native, selfHex: { hex },
            answer: { [unowned self] chat, member, statuses in self.answers.append(Answer(chat: chat.id, to: member, statuses: statuses)) },
            switched: switched, log: { [unowned self] in self.logs.append($0) })
        for name in holds { native.know(v.identities[name]!) }
    }

    /// On iOS a group's chat id is its group id.
    var chatId: String { v.groupId }

    /// The group of the vectors, as this device holds it: `creator` listed and accepted, this device `accepted` or only
    /// invited (pending), every other member invited.
    @discardableResult
    func hold(creator: String? = nil, accepted: Bool = true, groupId: String? = nil, members: [String]? = nil,
              creatorRecorded: Bool = true) -> GroupChatInfo {
        let creator = creator ?? v.creator
        let gid = groupId ?? v.groupId
        let id = gid
        let names = members ?? v.members
        let info = GroupChatInfo(id: id, creatorHex: creatorRecorded ? v.hashOf(creator) : nil,
                                 groupStatus: accepted ? "active" : "pending")
        store.chats[id] = info
        store.memberRows[id] = names.map { name in
            let h = v.hashOf(name)
            let status = h == selfHex ? (accepted ? MemberStatus.accepted : MemberStatus.invited)
                : (name == creator ? MemberStatus.accepted : MemberStatus.invited)
            return (hash: h, status: status)
        }
        return info
    }

    func status(_ name: String, chat: String? = nil) -> String? { store.statusOf(chat ?? chatId, v.hashOf(name)) }
    func statuses() -> [String: String] {
        Dictionary(uniqueKeysWithValues: v.members.map { ($0, status($0) ?? "nil") })
    }

    /// A packed message as the router would hand it over, through the group rule and the engine. Returns whether it counted
    /// (an accept or leave), nil when the rule dropped it or it is not one.
    @discardableResult
    func receive(_ packed: Data) -> Bool? {
        guard let u = native.receipt(packed) else { return nil }
        let fields = LxmfFieldsDecoder.decode(u.fieldsRaw)
        guard let groupId = fields.groupId else { return nil }
        let action = fields.groupAction
        let src = u.source.hexString
        let chat = store.chat(id: groupId)
        let rows = chat.map { store.members(chatId: $0.id) } ?? []
        let allowed = DeliveryPolicy.shouldProcess(
            action: action, sourceAllowed: true,
            held: GroupMemberStatuses.held(groupExists: chat != nil, groupStatus: chat?.groupStatus),
            sourceStatus: GroupMemberStatuses.statusOf(rows, src),
            namesOther: DeliveryPolicy.namesOther(groupSender: fields.groupSender, source: src),
            closed: false, signature: u.signature,
            sourceIsCreator: chat?.creatorHex != nil && chat?.creatorHex == src)
        if !allowed {
            dropped.append("\(action ?? "message") from \(v.nameOf(src))")
            return nil
        }
        engine.onKept(src: src, action: action, signature: u.signature, senderKey: u.senderKey)
        let whole: Data? = packed.count <= GroupStatuses.statusPackedLimit ? packed : nil
        switch action {
        case GroupAction.accept?, GroupAction.leave?:
            return engine.takeDirect(GroupArrival(msgId: u.hash.hexString, src: src, chat: chat!, action: action!,
                                                  timestamp: u.timestamp, signature: u.signature,
                                                  senderKey: u.senderKey, packed: whole))
        case GroupAction.status?:
            lastTally = engine.takeStatuses(chat: chat!, elements: fields.groupStatuses)
            return nil
        default:
            return nil
        }
    }

    func answeredNames() -> [String] { answers.map { v.nameOf($0.to) } }
}

// MARK: - Making messages

@MainActor
final class MessageMaker {
    let v: Vectors
    var clock = 1_790_100_000.0

    init(_ v: Vectors) { self.v = v }

    func id(_ name: String) -> VIdentity { v.identities[name]! }
    func at() -> Double { defer { clock += 1 }; return clock }

    /// An accept or leave from `from` to the creator: carrying `from`'s own key unless `key` is false, in the form
    /// `retichat` says, signed by `signer` (default `from`); `keyOf` and `keyEntryHash` make a key that does not bind
    /// (whose key, under whose hash); `sender` is GROUP_SENDER.
    func msg(_ from: String, action: String = GroupAction.accept, key: Bool = true, signer: String? = nil,
             retichat: Bool = true, to: String? = nil, sender: String? = nil, keyOf: String? = nil,
             keyEntryHash: String? = nil, groupId: String? = nil, content: Data = Data(), stamp: Bool = false) -> Data {
        let entry = key ? "\(id(keyEntryHash ?? from).hashHex):\(id(keyOf ?? from).publicKey.base64EncodedString())" : nil
        let fields = TestLxmf.groupFields(retichat: retichat, groupId: groupId ?? v.groupId, action: action,
                                          sender: id(sender ?? from).hashHex, keyEntry: entry,
                                          displayName: id(from).displayName)
        return TestLxmf.pack(signer: id(signer ?? from), from: id(from), to: id(to ?? v.creator), fields: fields, at: at(),
                             content: content, stamp: stamp)
    }

    /// The creator's `status` to `to` holding `elements` (nil: no key 10).
    func status(to: String, elements: [Data]?, from: String? = nil, signer: String? = nil, retichat: Bool = true,
                groupId: String? = nil) -> Data {
        let sourceName = from ?? v.creator
        let fields = TestLxmf.groupFields(retichat: retichat, groupId: groupId ?? v.groupId, action: GroupAction.status,
                                          sender: id(sourceName).hashHex, keyEntry: nil,
                                          displayName: id(sourceName).displayName, elements: elements)
        return TestLxmf.pack(signer: id(signer ?? sourceName), from: id(sourceName), to: id(to), fields: fields, at: at())
    }
}
