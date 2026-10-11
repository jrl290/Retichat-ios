//
//  GroupStatuses.swift
//  Retichat
//
//  MEMBER STATUSES AND KEYS: RFed-spec Group.md, "Member statuses and keys
//  (2026-10-06)"; LXMF-rust/DISPLAY_NAMES.md §10 key 10; approved by James on
//  2026-10-06. The iOS port of Retichat-android's GroupStatusEngine
//  (data/repository/GroupStatuses.kt), which is the port of the web's
//  `lib/group_status.js` and of what its `app.js` does with it (Retichat-js,
//  branch `group-statuses`); checked against the shared vectors (LXMF-rust
//  `tests/group_status_vectors.json`).
//
//  Two problems are closed: a member who accepts late never learns of the
//  accepts that the privacy filter dropped before, and an accept or leave from
//  a sender whose key the receiver never got cannot be verified, yet a leave
//  counts as final. In short:
//
//   - Every accept and leave (a decline is a leave) carries exactly the
//     sender's own `hash:base64key` (GroupEnvelopes). The glue crate binds it
//     (the key's `lxmf.delivery` destination is the entry's hash, which is the
//     message's LXMF source) and, for a source nobody held a key for, checks the
//     signature under it, so the message arrives validated or invalid, never
//     unverifiable for want of a key (rust/retichat-ffi/src/group_status.rs).
//   - `verdict`: verified counts under the group rules; forged (invalid under a
//     held or a bound key) is ignored; unverifiable (no key held, none carried
//     that binds) counts until the switch (`GROUP_ENTRIES_IN_RETICHAT_FIELD`,
//     around 2026-10-26) and is held from it, decided when the key arrives.
//   - The creator (recorded per group: this device's own hash at creation, the
//     invite's source otherwise) keeps each member's newest counted accept or
//     leave as the packed message it received, and answers an accept that
//     counted and carried a binding key with one `status`: every other listed
//     member's copy, by member hash ascending. It never answers a keyless
//     accept or a leave, answers each accept once, and never again.
//   - A `status` counts only from the group's creator, in a group the user
//     accepted; each element is checked on its own as if it had arrived
//     directly, and one that fails is skipped, so the creator can only pass on
//     what the members signed. A group held before this change has no creator
//     recorded: it neither answers nor counts a status.
//
//  No timers and no retries (DESIGN_PRINCIPLES §1, §3): nothing here waits, and a
//  status that does not leave is not sent again.
//
//  The decisions are the engine's, the storage, the native checks and the status
//  send are ports. The engine runs on the main actor, as every group handler in
//  ChatRepository does, and never suspends: one event runs to completion before
//  the next, so a leave stays final however two messages race (the Kotlin engine
//  takes one lock for the same reason). Foundation only (with DeliveryPolicy,
//  GroupMemberStatuses and LxmfFields), so tests/GroupStatusesTests.swift runs it
//  for real, against the shared vectors.
//

import Foundation

nonisolated enum GroupStatuses {
    /// The longest payload of an accept or leave worth keeping or passing on
    /// (`STATUS_PAYLOAD_LIMIT` in the web).
    static let statusPayloadLimit = 2048

    /// destination (16) + source (16) + signature (64).
    static let packedHeaderLength = 96

    /// The longest packed accept or leave: an element over this is skipped, and a
    /// creator keeps no copy of one.
    static let statusPackedLimit = packedHeaderLength + statusPayloadLimit

    /// Entries held for a key, in all (`GroupStore.HELD_LIMIT` in the web).
    static let heldLimit = 128

    /// Entries held for one member of one group (`GroupStore.HELD_PER_MEMBER`).
    static let heldPerMember = 4

    /// What an accept or leave is worth.
    enum Verdict: Equatable { case count, ignore, hold }

    /// What an accept or leave that passed the group rule is worth, from its
    /// `signature` (DeliveryPolicy.Signature) and whether the switch has
    /// happened (`switched`: `GROUP_ENTRIES_IN_RETICHAT_FIELD`):
    ///
    /// | signature | before the switch | from the switch |
    /// |---|---|---|
    /// | validated | count | count |
    /// | invalid | ignore | ignore |
    /// | source unknown | count | hold |
    ///
    /// Anything else is not counted.
    static func verdict(signature: Int, switched: Bool) -> Verdict {
        switch signature {
        case DeliveryPolicy.Signature.validated: return .count
        case DeliveryPolicy.Signature.sourceUnknown: return switched ? .hold : .count
        default: return .ignore
        }
    }

    /// One GROUP_MEMBER_KEYS entry, `hash:base64-public-key`: the form an invite
    /// chunk uses.
    static func keyEntry(hashHex: String, publicKey: Data) -> String {
        "\(hashHex):\(publicKey.base64EncodedString())"
    }
}

/// The creator's copy of a member's newest counted accept or leave.
nonisolated struct StatusCopy: Equatable, Sendable {
    let memberHex: String
    let action: String
    let packed: Data
}

/// An accept or leave held until its source's key is here. `msgHash` (the LXMF
/// message hash, hex) is its identity.
nonisolated struct HeldEntry: Equatable, Sendable {
    let chatId: String
    let srcHex: String
    let action: String
    let msgHash: String
    let packed: Data
}

/// The group a message names, as the engine reads it: its id (a group's chat id
/// is its group id), the creator recorded for it (nil for a group held before
/// the creator was recorded) and where the user stands in it (ChatEntity
/// .groupStatus: "pending" until the user accepts, nil from older builds is joined).
nonisolated struct GroupChatInfo: Equatable, Sendable {
    let id: String
    let creatorHex: String?
    let groupStatus: String?

    var held: DeliveryPolicy.Held { GroupMemberStatuses.held(groupExists: true, groupStatus: groupStatus) }
}

/// What the engine keeps and changes (SwiftData in the app, memory in the tests).
@MainActor
protocol GroupStatusStore: AnyObject {
    /// The group held here with id `groupId`, or nil.
    func chat(id groupId: String) -> GroupChatInfo?

    /// The group's member rows.
    func members(chatId: String) -> [GroupMemberStatuses.Row]

    /// `memberHex` is now `status` in the group (and, on a device, its announces are
    /// watched or not as the status says).
    func setMemberStatus(chatId: String, memberHex: String, status: String)

    /// The system line about a member who joined or left: `id` is its row,
    /// `timestamp` the message's own time (seconds).
    func memberLine(chatId: String, memberHex: String, joined: Bool, id: String, timestamp: Double)

    /// `memberHex` passes the privacy filter from now on: a member of a joined group, by association.
    func allow(memberHex: String)

    func copy(chatId: String, memberHex: String) -> StatusCopy?
    func putCopy(chatId: String, memberHex: String, action: String, packed: Data)

    /// The group's copies.
    func copies(chatId: String) -> [StatusCopy]

    /// Every held entry, oldest first.
    func held() -> [HeldEntry]
    func heldCount() -> Int
    func heldCount(chatId: String, srcHex: String) -> Int
    func heldCount(srcHex: String) -> Int
    func isHeld(msgHash: String) -> Bool
    func hold(_ entry: HeldEntry)
    func release(_ entry: HeldEntry)
}

/// What an element of a `status`, or an entry held for its sender's key, is once
/// unpacked and checked as if it had arrived directly: what
/// `retichat_group_unpack_packed` returns, read from the buffer
/// `group_status::encode_element` (glue crate) writes. All numbers are big endian:
///
/// | bytes | |
/// |---|---|
/// | 0 | `signature`: 0 validated, 1 source unknown, 2 invalid (DeliveryPolicy.Signature) |
/// | 1 | 1 when a bound sender key follows, else 0 |
/// | 2..18 | `destination` |
/// | 18..34 | `source` |
/// | 34..66 | `hash`, the LXMF message hash |
/// | 66..74 | `timestamp`, f64 |
/// | 74..138 | `senderKey`, only when byte 1 is 1 |
/// | then 4 | the length of the fields, u32 |
/// | then n | `fieldsRaw`, the LXMF fields map, msgpack |
///
/// `signature` is what the signature is worth as the router reports any: validated
/// under the key held for `source`, or under the key the message carries for its own
/// sender when none is held and that key binds; invalid when it does not verify
/// under either; source unknown when no key is held and none that binds is carried.
/// `senderKey` is that carried key (64 bytes), bound or not held.
nonisolated struct UnpackedGroupMessage: Equatable, Sendable {
    let signature: Int
    let destination: Data
    let source: Data
    let hash: Data
    let timestamp: Double
    let senderKey: Data?
    let fieldsRaw: Data

    static let hashLength = 16
    static let messageHashLength = 32
    static let keyLength = 64
    /// The fixed bytes before the optional key: verdict, key flag, three hashes and the time.
    static let fixedLength = 2 + 2 * hashLength + messageHashLength + 8

    /// The unpacked message the native buffer `bytes` holds, or nil when it is not one the glue writes.
    static func parse(_ bytes: Data) -> UnpackedGroupMessage? {
        let b = [UInt8](bytes)
        guard b.count >= fixedLength + 4 else { return nil }
        var at = 0
        func take(_ n: Int) -> Data { defer { at += n }; return Data(b[at..<at + n]) }
        let signature = Int(b[at]); at += 1
        guard (0...2).contains(signature) else { return nil }
        let hasKey: Bool
        switch b[at] {
        case 0: hasKey = false
        case 1: hasKey = true
        default: return nil
        }
        at += 1
        let destination = take(hashLength)
        let source = take(hashLength)
        let hash = take(messageHashLength)
        var bits: UInt64 = 0
        for byte in b[at..<at + 8] { bits = (bits << 8) | UInt64(byte) }
        at += 8
        let timestamp = Double(bitPattern: bits)
        var key: Data?
        if hasKey {
            guard b.count - at >= keyLength + 4 else { return nil }
            key = take(keyLength)
        }
        guard b.count - at >= 4 else { return nil }
        var length = 0
        for byte in b[at..<at + 4] { length = (length << 8) | Int(byte) }
        at += 4
        guard length == b.count - at else { return nil }
        return UnpackedGroupMessage(signature: signature, destination: destination, source: source,
                                    hash: hash, timestamp: timestamp, senderKey: key,
                                    fieldsRaw: take(length))
    }
}

/// What the engine needs of the native layer: the app uses the glue crate
/// (FFIGroupNative), the tests a fake that checks real signatures.
@MainActor
protocol GroupNative: AnyObject {
    /// An element of a `status`, or an entry held for its sender's key (a member's own
    /// packed accept or leave, 97..=2144 bytes), unpacked and checked as if it had arrived
    /// directly: what its signature is worth under the key held for its source, else under
    /// the key it carries for its own sender when that binds. Nothing is remembered. Nil
    /// when it is not an LXMF message.
    func unpack(_ packed: Data) -> UnpackedGroupMessage?

    /// Remember `publicKey` as the key of the `lxmf.delivery` destination `memberHex`, as an
    /// invite chunk's key is remembered. False, and nothing remembered, when the key does not
    /// produce that destination.
    func rememberKey(memberHex: String, publicKey: Data) -> Bool
}

/// A member's own accept or leave as it reached this device directly, after the group rule kept it.
nonisolated struct GroupArrival {
    /// The LXMF message hash (hex).
    let msgId: String
    /// The LXMF source (hex): the member it speaks for.
    let src: String
    let chat: GroupChatInfo
    /// GroupAction.accept or GroupAction.leave.
    let action: String
    /// The message's own time, seconds.
    let timestamp: Double
    /// DeliveryPolicy.Signature, with the carried key already applied by the glue.
    let signature: Int
    /// The 64-byte key it carries for its own sender when that binds; a creator answers only an accept that has one.
    let senderKey: Data?
    /// The message exactly as received; nil for a message over `GroupStatuses.statusPackedLimit`.
    let packed: Data?
}

/// What a `status` did, element by element.
nonisolated struct StatusTally: Equatable, Sendable {
    let elements: Int
    let counted: Int
    let held: Int
    let skipped: Int
}

/// The decisions of the group follow-up (see the file's header), apart from SwiftData, the
/// glue crate and the UI, which are ports: `store`, `native` and `answer`. The one place that
/// decides what an accept or leave is worth and what it changes, for the message arriving
/// directly (`takeDirect`), for each element of a `status` (`takeStatuses`) and for an entry
/// held for a key (`decideHeld`), so the three cannot differ.
@MainActor
final class GroupStatusEngine {
    private let store: GroupStatusStore
    private let native: GroupNative
    /// Whether `hex` is the user in the group `chatId` (GROUPS-DISTRO-DESIGN.md §9.1): the device,
    /// and in a group whose list names the user's distro D, D and D's known siblings too. Every
    /// "me" the engine asks (an element about the user, the creator keeping copies and answering,
    /// a member let through, never remembering one's own key) is this, so a creator that is D
    /// answers from every device of D (§12.1).
    private let isSelf: (_ chatId: String, _ hex: String) -> Bool
    /// Send the creator's `status` `statuses` to `memberHex` (fire and forget; once per accept).
    private let answer: (_ chat: GroupChatInfo, _ memberHex: String, _ statuses: [Data]) -> Void
    /// `GROUP_ENTRIES_IN_RETICHAT_FIELD`: from the switch an unverifiable accept or leave is
    /// held, not counted.
    private let switched: Bool
    private let log: (String) -> Void

    private enum Taken { case counted, held, ignored }

    init(store: GroupStatusStore,
         native: GroupNative,
         isSelf: @escaping (_ chatId: String, _ hex: String) -> Bool,
         answer: @escaping (_ chat: GroupChatInfo, _ memberHex: String, _ statuses: [Data]) -> Void,
         switched: Bool = RetichatField.groupEntriesInRetichatField,
         log: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.native = native
        self.isSelf = isSelf
        self.answer = answer
        self.switched = switched
        self.log = log
    }

    /// The user as one address in every group (the device), as before groups for distro holders.
    convenience init(store: GroupStatusStore,
                     native: GroupNative,
                     selfHex: @escaping () -> String,
                     answer: @escaping (_ chat: GroupChatInfo, _ memberHex: String, _ statuses: [Data]) -> Void,
                     switched: Bool = RetichatField.groupEntriesInRetichatField,
                     log: @escaping (String) -> Void = { _ in }) {
        self.init(store: store, native: native, isSelf: { _, hex in hex == selfHex() }, answer: answer,
                  switched: switched, log: log)
    }

    // MARK: What any group message the rule kept brings

    /// Before a group message the rule kept (DeliveryPolicy.shouldProcess) is handled: the key
    /// an accept or leave carries for its sender (`senderKey`) is remembered as an invite
    /// chunk's key is, after the rule and never for a message the rule dropped, and when the
    /// message verified (`signature` validated) the accepts and leaves held for its source's
    /// key are decided now, before this message, so they count in the order they came.
    func onKept(src: String, action: String?, signature: Int, senderKey: Data?, chatId: String = "") {
        if (action == GroupAction.accept || action == GroupAction.leave), let senderKey {
            remember(chatId, src, senderKey)
        }
        if signature == DeliveryPolicy.Signature.validated, store.heldCount(srcHex: src) > 0 {
            decideHeldNow(src)
        }
    }

    /// A key may have arrived for `source` (an announce) or for any member (`source` nil: an
    /// invite brought keys, the user is accepting): decide the entries held for it. Cheap when
    /// none is held.
    func decideHeld(source: String? = nil) {
        if source == nil || store.heldCount(srcHex: source!) > 0 { decideHeldNow(source) }
    }

    // MARK: An accept or leave arriving directly

    /// A member's own accept or leave the group rule kept: it counts, is ignored or is held by
    /// its signature (`GroupStatuses.verdict`); what counts moves the member (a leave is
    /// final), keeps the creator's copy and lets an accepted member through the privacy
    /// filter. The creator answers an accept that counted and carries a binding key, and no
    /// other (RFed-spec Group.md, "The creator's answer"). Returns whether it counted.
    @discardableResult
    func takeDirect(_ arrival: GroupArrival) -> Bool {
        let taken = takeChange(arrival.chat, arrival.src, arrival.action, arrival.msgId, arrival.timestamp,
                               arrival.signature, arrival.packed)
        let counted = taken == .counted
        if counted, arrival.action == GroupAction.accept, arrival.senderKey != nil {
            answerAccept(arrival.chat, arrival.src)
        }
        return counted
    }

    // MARK: A status

    /// A `status` the group rule took (only from the group's creator, for a group the user
    /// joined, signed by it): the creator's answer to the user's accept, `elements` its
    /// GROUP_STATUSES as decoded, the members' own accepts and leaves as the creator received
    /// them. Each element is checked on its own as if it had arrived directly (`takeElement`);
    /// one that fails is skipped, so the creator can pass on only what the members signed; one
    /// that passes counts under the rules of the message arriving directly, so order does not
    /// matter and a leave stays final. An honest creator sends at most one element for each
    /// member but the two it leaves out, so no more than the member list's length are read:
    /// each costs a signature check.
    @discardableResult
    func takeStatuses(chat: GroupChatInfo, elements: [Data?]?) -> StatusTally {
        let groupId = chat.id
        let all = elements ?? []
        let rows = store.members(chatId: chat.id)
        let memberCount = Set(rows.map(\.hash)).count
        var counted = 0
        var held = 0
        var skipped = all.count - min(all.count, memberCount)
        let joined = chat.held == .joined
        for (index, element) in all.prefix(memberCount).enumerated() {
            let result = joined ? takeElement(chat, groupId, element) : "the user has not accepted the group"
            switch result {
            case Self.counted: counted += 1
            case Self.heldResult: held += 1
            default:
                skipped += 1
                log("Skipped element \(index) of the status for group \(groupId.prefix(8)): \(result)")
            }
        }
        log("Status for group \(groupId.prefix(8)): \(all.count) element(s), \(counted) counted, \(held) held, \(skipped) skipped")
        return StatusTally(elements: all.count, counted: counted, held: held, skipped: skipped)
    }

    /// One element of a `status`, checked as if it had arrived directly: it must be a packed LXMF
    /// message (97..=2144 bytes) that unpacks, about this group, an accept or a leave, from a
    /// source that is a member listed for the group and has not left, naming nobody else, and not
    /// about this device. Its signature is checked as any message's is (the glue: under the key
    /// held for its source, or the one it carries once bound), and the group rule and the verdict
    /// are those of the message arriving directly. Its destination is the creator, not this
    /// device: it is the member's own statement to the creator, and is not asked. Forwarded
    /// elements do not teach display names. Returns `counted`, `held` (unverifiable from the
    /// switch) or why it was skipped.
    private func takeElement(_ chat: GroupChatInfo, _ groupId: String, _ element: Data?) -> String {
        guard let element else { return "not a bin" }
        if element.count <= GroupStatuses.packedHeaderLength || element.count > GroupStatuses.statusPackedLimit {
            return "\(element.count) bytes is not the size of an accept or leave"
        }
        guard let unpacked = native.unpack(element) else { return "not an LXMF message" }
        let fields = LxmfFieldsDecoder.decode(unpacked.fieldsRaw)
        guard let about = fields.groupId else { return "no group id" }
        if about != groupId { return "about another group" }
        let action = fields.groupAction
        guard action == GroupAction.accept || action == GroupAction.leave, let action else {
            return "the action is \(fields.groupAction ?? "none"), not an accept or a leave"
        }
        let src = unpacked.source.hexString
        if isSelf(chat.id, src) { return "about the user (this device, or the distro and its devices)" }
        let rows = store.members(chatId: chat.id)
        let allowed = DeliveryPolicy.shouldProcess(
            action: action,
            sourceAllowed: false,
            held: chat.held,
            sourceStatus: GroupMemberStatuses.statusOf(rows, src),
            namesOther: DeliveryPolicy.namesOther(groupSender: fields.groupSender, source: src),
            closed: false,
            signature: unpacked.signature)
        if !allowed {
            return unpacked.signature == DeliveryPolicy.Signature.invalid
                ? "its signature does not verify: it is not its source's"
                : "its source is not a member listed for the group that has not left, or it names another"
        }
        // The key it carries is remembered as the one an accept arriving directly brings.
        if let key = unpacked.senderKey { remember(chat.id, src, key) }
        let taken = takeChange(chat, src, action, unpacked.hash.hexString, unpacked.timestamp,
                               unpacked.signature, element)
        return taken == .counted ? Self.counted : Self.heldResult
    }

    // MARK: The one place that decides

    /// An accept or leave of member `src` that passed the group rule (a listed member that has
    /// not left, about itself, not forged), decided by its signature (`GroupStatuses.verdict`).
    /// `packed` is the message as received.
    private func takeChange(_ chat: GroupChatInfo, _ src: String, _ action: String, _ msgId: String,
                            _ timestamp: Double, _ signature: Int, _ packed: Data?) -> Taken {
        switch GroupStatuses.verdict(signature: signature, switched: switched) {
        case .hold:
            hold(chat, src, action, msgId, packed)
            return .held
        case .ignore:
            return .ignored
        case .count:
            applyChange(chat, src, action, msgId, timestamp, packed)
            return .counted
        }
    }

    /// Every accept or leave that counts comes through here (arriving, held and decided later, or
    /// an element of a `status`), so this is where the creator keeps its copy, before the member's
    /// status moves: a repeated accept, which changes nothing, is the newest copy too.
    private func applyChange(_ chat: GroupChatInfo, _ src: String, _ action: String, _ msgId: String,
                             _ timestamp: Double, _ packed: Data?) {
        let rows = store.members(chatId: chat.id)
        if let packed, let creator = chat.creatorHex, isSelf(chat.id, creator) {
            if let why = keepCopy(chat, GroupMemberStatuses.statusOf(rows, src), src, action, packed) {
                log("No copy kept of the \(action) of \(src.prefix(12)) for group \(chat.id): \(why)")
            }
        }
        guard let next = GroupMemberStatuses.statusChange(current: GroupMemberStatuses.statusOf(rows, src),
                                                          action: action) else {
            log("group \(chat.id): \(action) from \(src.prefix(8)) changes nothing")
            return
        }
        store.setMemberStatus(chatId: chat.id, memberHex: src, status: next)
        let accepted = action == GroupAction.accept
        log("\(src.prefix(8)) \(accepted ? "accepted" : "left") group \(chat.id)")
        // In a group the user joined, a member's accept passes the privacy filter, as the user's own
        // accept made every member. A pending group lets nobody through: the members pass from the
        // user's accept (and the creator's answer to it brings back what the filter dropped).
        if accepted, !isSelf(chat.id, src), chat.held == .joined { store.allow(memberHex: src) }
        let groupId = chat.id
        store.memberLine(chatId: chat.id, memberHex: src, joined: accepted,
                         id: accepted ? "acc_\(src.prefix(8))_\(groupId.prefix(8))" : msgId,
                         timestamp: timestamp)
    }

    /// Keep `packed` as member `src`'s copy for the creator's answer: the newest accept or leave of
    /// that member that counted, one per member, replaced by the next that counts. A leave is final
    /// here as everywhere: nothing replaces it, and nothing is kept for a member that left. Returns
    /// nil when kept, else why not (the sender is on no list, it left, the copy is over
    /// `GroupStatuses.statusPackedLimit`).
    private func keepCopy(_ chat: GroupChatInfo, _ status: String?, _ src: String, _ action: String,
                          _ packed: Data) -> String? {
        if action != GroupAction.accept && action != GroupAction.leave { return "it is neither an accept nor a leave" }
        guard let status else { return "its sender is on no list" }
        if status == MemberStatus.left { return "its sender left, for good" }
        if packed.isEmpty { return "there is no packed message" }
        if packed.count > GroupStatuses.statusPackedLimit {
            return "it is over \(GroupStatuses.statusPackedLimit) bytes, which no accept or leave is"
        }
        if store.copy(chatId: chat.id, memberHex: src)?.action == GroupAction.leave {
            return "a leave is kept: nothing replaces it"
        }
        store.putCopy(chatId: chat.id, memberHex: src, action: action, packed: packed)
        return nil
    }

    // MARK: The creator's answer

    /// The creator's answer to an accept that counted and carried its sender's key: one `status` to
    /// member `memberHex` alone, holding the copy kept of each other listed member's newest counted
    /// accept or leave (neither the user's own nor the recipient's), by member hash ascending. A
    /// member that has not answered is absent: still invited. An empty list is a valid answer. Only
    /// the creator answers: any other device sends nothing. A creator that is the user's distro D
    /// answers from every device of D that holds the group joined (GROUPS-DISTRO-DESIGN.md §12.1);
    /// one that applied D's leave holds no group, so it answers nothing. An accept by one of the
    /// user's own addresses (an older device of D acting as its listed entry, §14) counts for its
    /// entry and is never answered: a self address is never a send target, a status included (§9.2).
    private func answerAccept(_ chat: GroupChatInfo, _ memberHex: String) {
        guard let creator = chat.creatorHex, isSelf(chat.id, creator) else { return }
        guard !isSelf(chat.id, memberHex) else {
            log("Group \(chat.id): no answer to the user's own accept (\(memberHex.prefix(12))): a self address is never a send target")
            return
        }
        let listed = Set(store.members(chatId: chat.id).map(\.hash))
        let statuses = store.copies(chatId: chat.id)
            .filter { !isSelf(chat.id, $0.memberHex) && $0.memberHex != memberHex && listed.contains($0.memberHex) }
            .sorted { $0.memberHex < $1.memberHex }
            .map(\.packed)
        answer(chat, memberHex, statuses)
        log("Status for group \(chat.id) with \(statuses.count) element(s) to \(memberHex.prefix(12))")
    }

    // MARK: Held until a key is here

    /// An accept or leave no key can verify, from the switch: held with what its signature covers
    /// (the packed message, as received), and decided once the key is here (`decideHeld`). Bounded,
    /// as anyone can send one for a member whose key is not here yet: a copy over the limit, one
    /// held already, past `GroupStatuses.heldPerMember` for the member or `GroupStatuses.heldLimit`
    /// in all is dropped, and those already held stay.
    private func hold(_ chat: GroupChatInfo, _ src: String, _ action: String, _ msgId: String, _ packed: Data?) {
        let refused: String?
        if packed == nil || packed!.isEmpty {
            refused = "what its signature covers was not kept"
        } else if store.isHeld(msgHash: msgId) {
            refused = "it is held already"
        } else if store.heldCount(chatId: chat.id, srcHex: src) >= GroupStatuses.heldPerMember {
            refused = "\(GroupStatuses.heldPerMember) are held for this member already"
        } else if store.heldCount() >= GroupStatuses.heldLimit {
            refused = "\(GroupStatuses.heldLimit) are held already"
        } else {
            refused = nil
        }
        if let refused {
            log("Dropped \(action) for group \(chat.id) from \(src.prefix(12)): no key for it here to check its signature, and it cannot be held (\(refused))")
            return
        }
        store.hold(HeldEntry(chatId: chat.id, srcHex: src, action: action, msgHash: msgId, packed: packed!))
        log("Holding \(action) for group \(chat.id) from \(src.prefix(12)) until its key is here to check its signature")
    }

    /// Decide every held accept or leave (of `source` only, when given) whose source's key is now
    /// here: counted when its signature verifies, dropped when it does not (it was not that
    /// member's). One whose key is still missing stays held; one whose group is gone was released
    /// with it. In the order they came.
    private func decideHeldNow(_ source: String?) {
        for entry in store.held() {
            if let source, entry.srcHex != source { continue }
            guard let unpacked = native.unpack(entry.packed) else {
                store.release(entry)
                log("Dropped held \(entry.action) for group \(entry.chatId) from \(entry.srcHex.prefix(12)): it no longer unpacks")
                continue
            }
            if unpacked.signature == DeliveryPolicy.Signature.sourceUnknown { continue }
            store.release(entry)
            guard let chat = store.chat(id: entry.chatId) else { continue }
            if unpacked.signature != DeliveryPolicy.Signature.validated {
                log("Dropped held \(entry.action) for group \(entry.chatId) from \(entry.srcHex.prefix(12)): its signature does not verify with that member's key, so it is not the member's")
                continue
            }
            log("Held \(entry.action) for group \(entry.chatId) from \(entry.srcHex.prefix(12)) verifies: counted")
            applyChange(chat, entry.srcHex, entry.action, entry.msgHash, unpacked.timestamp, entry.packed)
        }
    }

    // MARK: Keys

    /// Keep `key` as `src`'s: the glue remembers it only when it produces `src` as an
    /// `lxmf.delivery` destination. This device's own key is never kept.
    private func remember(_ chatId: String, _ src: String, _ key: Data) {
        if isSelf(chatId, src) { return }
        if !native.rememberKey(memberHex: src, publicKey: key) {
            log("Ignored mismatched member key for \(src.prefix(8))")
        }
    }

    private static let counted = "counted"
    private static let heldResult = "held"
}
