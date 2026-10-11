// DistroGroupsTests.swift
//
// Groups for distro holders (GROUPS-DISTRO-DESIGN.md, approved by James 2026-10-10), the iOS
// rows of §19.2. What runs for real: the distro path's routing of the unwrap JSON
// (DistroUnwrapped.groupRoute, the DistroInbound block of RfedDistroClient.swift), the rules of
// DistroGroupSync.swift (the group sync's §11 rules and table, who "me" is in a group, the
// signer, §6.3's first rules, the filtered-invite set, the known siblings, the held arrivals and
// their bounds), the group rule (DeliveryPolicy), the group engine (GroupStatuses.swift) with a
// creator that is the distro on two devices, and the NSE's decision (PendingNotification.swift,
// NSEGroupShow). The group sync readings are the shared vectors
// (rust/retichat-ffi/tests/data/distro_group_sync_vectors.json, LXMF-rust 16a9902); the engine's
// messages are the member-status vectors' (tests/GroupStatusFixtures.swift, real Ed25519).
// ChatRepository, GroupChatManager, the NSE and the views need SwiftData, UIKit and the FFI, so
// their wiring is asserted on the source, in the same tests. The bridge itself (the unwrap of a
// sealed G and the writer) runs in tests/DistroGroupsFFITests.swift; the SwiftData migration in
// tests/DistroGroupsMigrationTests.swift.
//
// Run from the workspace root with:
//
//   { echo 'import Foundation'; \
//     sed -n '/^\/\/ BEGIN DistroInbound/,/^\/\/ END DistroInbound/p' \
//     Retichat-ios/Retichat/Services/RfedDistroClient.swift; } \
//     > /private/tmp/claude-501/DistroInbound.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-groups \
//     /private/tmp/claude-501/DistroInbound.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/GroupStatuses.swift \
//     Retichat-ios/Retichat/Services/GroupEnvelopes.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/tests/GroupStatusFixtures.swift \
//     Retichat-ios/tests/DistroGroupsTests.swift && \
//     /private/tmp/claude-501/distro-groups

import CryptoKit
import Foundation

// MARK: - The vectors and the addresses

/// The member-status vectors (the engine's messages).
let V = Vectors.load()

/// distro_group_sync_vectors.json, as JSON.
let GV: [String: Any] = {
    let url = root.appendingPathComponent("rust/retichat-ffi/tests/data/distro_group_sync_vectors.json")
    guard let raw = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        fatalError("the group sync vectors are not readable at \(url.path)")
    }
    return json
}()

func gv(_ key: String) -> [String: Any] { GV[key] as! [String: Any] }
func gvList(_ key: String) -> [[String: Any]] { GV[key] as! [[String: Any]] }

/// D, the user's distro; M, a member; X, a key that is not M's.
let D = gv("distro")["lxmf_delivery_hash_hex"] as! String
let M = gv("member")["lxmf_delivery_hash_hex"] as! String
let X = gv("forger")["lxmf_delivery_hash_hex"] as! String
/// The sibling device that wrote the vectors' G (its 0xFD).
let SIB = GV["device_hex"] as! String
/// This device: not the sibling.
let THIS = String(repeating: "11", count: 16)
let GID = gv("group")["group_id"] as! String
let GROUP_NAME = gv("group")["name"] as! String
let OTHER = String(repeating: "e1", count: 16)

/// A JSON object as the bridge would hand it over, decoded the way the app decodes it.
func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

/// The unwrap JSON of a group message to D (retichat_distro_unwrap, LXMF-rust to_json_with_receipt).
func unwrapJSON(source: String = M, timestamp: Double = 1_790_000_000.5, hash: String?, hasGroupId: Bool?,
                groupId: Any?, action: String? = nil, groupSync: Any? = nil, validated: Bool = true,
                reason: Int = 0) -> [String: Any] {
    var o: [String: Any] = [
        "source_hash": source, "timestamp": timestamp, "title": "", "content": "hello",
        "is_delivery_notification": false, "signature_validated": validated, "unverified_reason": reason,
    ]
    if let hash { o["hash"] = hash }
    if let hasGroupId { o["has_group_id"] = hasGroupId }
    o["group_id"] = groupId ?? NSNull()
    o["group_action"] = action ?? NSNull()
    o["group_sync"] = groupSync ?? NSNull()
    return o
}

func hash64(_ n: Int) -> String { String(format: "%064x", n) }
func id32(_ n: Int) -> String { String(format: "%032x", n) }

// MARK: - Source helpers

/// The body of `func name` in `text`, up to the next "\n    func " or "\n    private func " (or a
/// MARK) at the same depth.
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    // MARK", "\n    @discardableResult", "\n    nonisolated private static func",
                "\n    nonisolated static func", "\n    private static func", "\n    static func"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(text[start.lowerBound..<(ends.min() ?? text.endIndex)])
}

/// The text from `start` up to the first `end` after it.
func span(_ text: String, from start: String, to end: String) -> String {
    guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return "" }
    return String(text[a.lowerBound..<b.upperBound])
}

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

func count(_ text: String, _ what: String) -> Int { text.components(separatedBy: what).count - 1 }

let repo = source("Retichat/Services/ChatRepository.swift")
let distroClient = source("Retichat/Services/RfedDistroClient.swift")
let manager = source("Retichat/Services/GroupChatManager.swift")
let conversation = source("Retichat/Views/Conversation/ConversationView.swift")
let chatList = source("Retichat/Views/ChatList/ChatListView.swift")

// MARK: - §6.1-§6.2: the distro path routes group traffic, never to the DMs

func anInviteToDIsRoutedToTheGroupBranchAndNeverBecomesADirectMessage() {
    let sealed = gvList("sealed").first { $0["name"] as? String == "member_invite_retichat_field" }!
    let expected = sealed["expected"] as! [String: Any]
    let hash = sealed["hash_hex"] as! String
    var json = unwrapJSON(hash: hash, hasGroupId: expected["has_group_id"] as? Bool, groupId: expected["group_id"],
                          action: expected["group_action"] as? String, validated: false, reason: 1)
    json["group_name"] = expected["group_name"]
    json["fields"] = unhex(sealed["fields_hex"] as! String).base64EncodedString()
    guard let parsed = decode(DistroUnwrapped.self, json) else { check(false, "the unwrap JSON decodes"); return }
    checkEqual(parsed.groupRoute, .group(hash: hash, groupId: GID), "an invite to D goes to the group branch, on its LXMF hash")
    checkEqual(parsed.group_name, GROUP_NAME, "with its group name")
    // An older bridge (no group keys) keeps today's path.
    let old = decode(DistroUnwrapped.self, unwrapJSON(hash: nil, hasGroupId: nil, groupId: nil))
    checkEqual(old?.groupRoute, .other, "an unwrap without the group keys takes the path it took before")

    // The invite makes a pending group whose own address is D (§8.1), never a contact or a DM.
    checkEqual(GroupSelf.ownMemberForInvite(listed: [D, M, OTHER], device: THIS, heldDistro: D), D,
               "an invite listing D is the user's as D")
    let unwrap = body(distroClient, "nonisolated private static func unwrapAndDeliver(")
    check(before(unwrap, "switch parsed.groupRoute {", "let key = DistroCodec.seenKey(sourceHex: srcHex, timestamp: parsed.timestamp)")
            && before(unwrap, "switch parsed.groupRoute {", "inbound = .message(DistroMessage(unwrapped: parsed,"),
          "the group branch comes before the generic seen key and the DM path")
    let group = span(unwrap, from: "case .group(let hash, let groupId):", to: "case .dropped(let why):")
    check(group.contains("RfedDistroClient.shared.deliver(.group(arrival))") && group.contains("            return\n"),
          "a group message is delivered to the group sink and goes no further")
    check(repo.contains("RfedDistroClient.shared.onGroup = { [weak self] arrival in\n            self?.handleDistroGroupArrival(arrival) ?? false"),
          "the app routes it to handleDistroGroupArrival")
    let arrival = body(repo, "private func handleDistroGroupArrival(")
    check(!arrival.isEmpty && !arrival.contains("ensureContact") && !arrival.contains("storeIncomingDirect(")
            && !arrival.contains("handleDistroMessage(") && !arrival.contains("ensureAllowlistedContact("),
          "which never makes a contact or a DM (§6.4)")
    check(before(arrival, "admitGroupMessage(groupId: groupId, sourceHex: srcHex, fields: fields, signature: signature)", "handleGroupMessage("),
          "it is admitted by the same rule as the direct path, then handled by the same group handler")
    let invite = body(repo, "private func handleGroupInvite(")
    check(invite.contains("GroupSelf.ownMemberForInvite(listed: listed, device: ownHashHex, heldDistro: heldDistroHex)")
            && invite.contains("ownMember: ownMember == ownHashHex ? nil : ownMember,")
            && invite.contains("groupStatus: \"pending\""),
          "the pending group records D as its own address")
}

func nInviteChunksWithOneSourceAndTimestampEachReachTheGroupHandler() {
    // A web sender's chunks: one `src:ts`, one LXMF hash each.
    let chunks = (1...3).map { n in
        decode(DistroUnwrapped.self, unwrapJSON(hash: hash64(n), hasGroupId: true, groupId: GID, action: "invite"))!
    }
    let keys = chunks.compactMap { u -> String? in
        guard case .group(let h, _) = u.groupRoute else { return nil }
        return DistroGroupSync.groupSeenKey(hashHex: h)
    }
    checkEqual(keys.count, 3, "every chunk is a group message")
    checkEqual(Set(keys).count, 3, "each on its own seen key")
    checkEqual(keys.first, "grp:" + hash64(1), "grp:<hash>")
    // The generic key would have taken them as one (DistroCodec.seenKey is source:timestamp).
    check(Set(chunks.map { "\($0.source_hash):\($0.timestamp)" }).count == 1, "they share one src:ts")
    let unwrap = body(distroClient, "nonisolated private static func unwrapAndDeliver(")
    let group = span(unwrap, from: "case .group(let hash, let groupId):", to: "case .dropped(let why):")
    check(group.contains("let key = DistroGroupSync.groupSeenKey(hashHex: hash)")
            && group.contains("if kept { blobQueue.async { seen.record(key) } }"),
          "the key is the hash's, recorded only when the message is kept")
    // Every chunk's key is remembered: the invite handler binds each chunk's GROUP_MEMBER_KEYS entry.
    check(body(repo, "private func handleGroupInvite(").contains("for (memberHash, keyBase64) in fields.groupMemberKeys ?? [:] {"),
          "every chunk's member key is remembered")
}

func aGroupIdThatIsNot32HexIsDroppedInTheGroupBranchNeverADirectMessage() {
    // GROUP_ID as an int: the unwrap says has_group_id with a null group_id.
    let int = decode(DistroUnwrapped.self, unwrapJSON(hash: hash64(7), hasGroupId: true, groupId: nil))
    if case .dropped? = int?.groupRoute {} else { check(false, "an int GROUP_ID is dropped in the group branch") }
    let short = decode(DistroUnwrapped.self, unwrapJSON(hash: hash64(7), hasGroupId: true, groupId: "abc"))
    if case .dropped? = short?.groupRoute {} else { check(false, "a GROUP_ID that is not 32 hex is dropped") }
    let noHash = decode(DistroUnwrapped.self, unwrapJSON(hash: nil, hasGroupId: true, groupId: GID))
    if case .dropped? = noHash?.groupRoute {} else { check(false, "a group message without its LXMF hash is dropped") }
    let upper = decode(DistroUnwrapped.self, unwrapJSON(hash: hash64(9).uppercased(), hasGroupId: true, groupId: GID.uppercased()))
    checkEqual(upper?.groupRoute, .group(hash: hash64(9), groupId: GID), "ids are lowercased")
    let unwrap = body(distroClient, "nonisolated private static func unwrapAndDeliver(")
    let dropped = span(unwrap, from: "case .dropped(let why):", to: "case .other:")
    check(dropped.contains("(never a direct message)") && dropped.contains("return"), "dropped with a log line, never a DM")
}

func anInviteTheFilterDropsIsIgnoredAndItsIdEntersTheFilteredInviteSet() {
    var ids: [String] = []
    for n in 0..<70 { ids = FilteredInvites.record(ids, id32(n)) }
    checkEqual(ids.count, FilteredInvites.limit, "the set holds 64 ids")
    checkEqual(ids.first, id32(6), "the oldest forgotten first")
    checkEqual(FilteredInvites.record(ids, id32(10)).last, id32(10), "a repeat moves to the end, once")
    check(!FilteredInvites.remove(ids, id32(10)).contains(id32(10)), "and a group held from G leaves it")
    // The filter on: an invite from a non-allowlisted inviter is dropped by the rule.
    check(!DeliveryPolicy.shouldProcess(action: GroupAction.invite, sourceAllowed: false, held: .none, sourceStatus: nil,
                                        namesOther: false, closed: false, signature: DeliveryPolicy.Signature.validated),
          "an invite from an inviter the filter does not allow is not processed")
    check(!HeldArrivals.holdable(isPostSync: false, action: nil, held: .none, closed: false, filtered: true,
                                 signature: DeliveryPolicy.Signature.validated, sourceIsSelf: false, keptIfJoined: true)
            && !HeldArrivals.holdable(isPostSync: true, action: nil, held: .none, closed: false, filtered: true,
                                      signature: DeliveryPolicy.Signature.validated, sourceIsSelf: false, keptIfJoined: true),
          "a filtered group's traffic is never held")
    let arrival = body(repo, "private func handleDistroGroupArrival(")
    check(arrival.contains("if action == GroupAction.invite {\n                noteFilteredInvite("), "a dropped invite is noted")
    let note = body(repo, "private func noteFilteredInvite(")
    check(note.contains("guard FilteredInvites.records(sourceAllowlisted: isAllowlisted(destHash: sourceHex), closed: standing.closed,")
            && note.contains("prefs.filteredInviteIds = FilteredInvites.record(prefs.filteredInviteIds, groupId)"),
          "the filter's drop records the id")
}

// MARK: - §9: who "me" is; §8.1: the signer

func inADGroupNoSendTargetsDOrAKnownSiblingAndTheOwnEntryIsDOnly() {
    let listed = [D, M, OTHER, SIB]
    let me = GroupSelf.addresses(ownMember: D, device: THIS, listed: listed, heldDistro: D, siblings: { $0 == D ? [SIB] : [] })
    checkEqual(me, Set([D, THIS, SIB]), "self in a D-group: D, the device and D's known siblings")
    let rows: [GroupMemberStatuses.Row] = listed.map { (hash: $0, status: MemberStatus.accepted) }
    checkEqual(GroupMemberStatuses.acceptedMembers(rows, selfAddresses: me), [M, OTHER], "a post goes to the others only")
    checkEqual(GroupMemberStatuses.leaveTargets(rows, selfAddresses: me), [M, OTHER], "so does a leave")
    checkEqual(GroupMemberStatuses.conversationPeers(rows, selfAddresses: me, held: .joined), [M, OTHER], "and the links opened")
    // A device group: the device alone, as before; one listing both the device and the D held: D's group too.
    checkEqual(GroupSelf.addresses(ownMember: nil, device: THIS, listed: [THIS, M], heldDistro: D, siblings: { _ in [SIB] }),
               Set([THIS]), "self in a device group: the device")
    checkEqual(GroupSelf.addresses(ownMember: nil, device: THIS, listed: [THIS, D, M], heldDistro: D, siblings: { _ in [SIB] }),
               Set([THIS, D, SIB]), "a list naming the D held: D and its devices are self too")
    checkEqual(GroupSelf.ownMemberForInvite(listed: [THIS, D, M], device: THIS, heldDistro: D), D, "and the user acts as D")
    // The wiring.
    let accept = body(repo, "func acceptGroupInvite(")
    check(accept.contains("let own = signer.hex") && accept.contains("let targets = allHashes.filter { !selfAddresses.contains($0) }")
            && accept.contains("for hash in allHashes where !selfAddresses.contains(hash) {"),
          "the accept: the own row is the signer's, no self address is targeted or allowlisted")
    check(body(repo, "private func fanOutGroupMessage(").contains("GroupMemberStatuses.acceptedMembers(rows, selfAddresses: groupSelf(chat, rows: rows))"),
          "a post targets the accepted members that are not self")
    check(body(repo, "private func quitGroup(").contains("GroupMemberStatuses.leaveTargets(rows, selfAddresses: groupSelf(chat, rows: rows))"),
          "a leave targets the members that are not self")
    let create = body(repo, "func createGroupChat(")
    check(create.contains("var allMembers = memberHashes.filter { !userAddresses.contains($0) }\n        allMembers.append(own)"),
          "a group created as D lists D, never the device or a sibling")
}

func theAcceptGoesOutAsDSignedByDWithGroupSenderDAndDsOwnKey() {
    let key = Data((0..<64).map { UInt8($0) })
    let entries = GroupEnvelopes.accept(groupId: GID, selfHex: D, ownKey: GroupEnvelopes.ownKeyEntry(selfHex: D, publicKey: key))
    checkEqual(entries.first { $0.entry == .sender }?.value, D, "GROUP_SENDER D")
    checkEqual(entries.first { $0.entry == .memberKeys }?.value, "\(D):\(key.base64EncodedString())", "carrying D:<D's key>")
    // Each group message is made with the signer: source and signing identity the group's own address.
    check(manager.contains("RetichatBridge.shared.messageCreate(destHash: dest, sourceHash: signer.hash, content: content, title: \"\",\n                                            method: LxmfMethod.direct, identityHandle: signer.identityHandle)"),
          "made through retichat_message_create, source and key the signer's")
    let accept = body(manager, "func sendAccept(")
    check(accept.contains("let ownKey = ownKeyEntry(signer)") && accept.contains("create(to: destData, content: \"\", as: signer)")
            && accept.contains("GroupEnvelopes.accept(groupId: groupId, selfHex: signer.hex, ownKey: ownKey)")
            && !accept.contains("createMessage("),
          "the accept is the signer's: source, GROUP_SENDER and key")
    check(body(manager, "private func ownKeyEntry(").contains("GroupEnvelopes.ownKeyEntry(selfHex: signer.hex, publicKey: publicKey)"),
          "the key entry is the signer's own")
    for f in ["func sendInvites(", "func sendStatus(", "func sendLeave(", "func fanoutMessage("] {
        let b = body(manager, f)
        check(b.contains("as signer: GroupSigner") && b.contains("as: signer)") && !b.contains("createMessage("), "\(f) goes as the signer")
    }
    let signer = body(repo, "private func groupSigner(_ chat: ChatEntity)")
    check(signer.contains("guard let signing, signing.info.deliveryHashHex == d, let hash = Data(hexString: d) else { return nil }")
            && signer.contains("identityHandle: signing.handle,")
            && signer.contains("publicKey: Data(hexString: signing.info.publicKeyHex), isDistro: true)"),
          "D signs only when DistroManager.signing() names the group's own D, with D's handle and key")
    check(!repo.contains("Group sends stay device-signed"), "\"Group sends stay device-signed\" is gone")
}

func theSignerRefusesWhenDIsNotLoadedOrReplacedAndTheConversationSaysWhy() {
    let D2 = String(repeating: "d2", count: 16)
    checkEqual(GroupSelf.signer(ownMember: D, device: THIS, loadedDistro: D, distroSettled: true), .distro(D), "D held: D signs")
    checkEqual(GroupSelf.signer(ownMember: nil, device: THIS, loadedDistro: D, distroSettled: true), .device, "a device group: the device")
    checkEqual(GroupSelf.signer(ownMember: THIS, device: THIS, loadedDistro: nil, distroSettled: false), .device, "the device named: the device")
    checkEqual(GroupSelf.signer(ownMember: D, device: THIS, loadedDistro: nil, distroSettled: false), .distroNotLoaded(D),
               "D not loaded yet: nobody signs")
    checkEqual(GroupSelf.signer(ownMember: D, device: THIS, loadedDistro: D2, distroSettled: true), .formerDistro(D),
               "D replaced by D': nobody signs, never D'")
    checkEqual(GroupSelf.signer(ownMember: D, device: THIS, loadedDistro: nil, distroSettled: true), .formerDistro(D),
               "D given up: nobody signs, never the device")
    checkEqual(GroupSelf.cannotSignText(.formerDistro(D)),
               "This group uses your distro address \(D.prefix(8)), which this device no longer holds. You can read it here, but cannot post or change your membership from this device.",
               "§8.7's text")
    check(GroupSelf.cannotSignText(.distro(D)) == nil && GroupSelf.cannotSignText(.device) == nil, "no text when it can act")
    check(GroupSelf.cannotSignText(.distroNotLoaded(D)) != nil, "a text while D loads")

    let signer = body(repo, "private func groupSigner(_ chat: ChatEntity)")
    check(signer.contains("case .distroNotLoaded, .formerDistro:\n            return nil"), "groupSigner gives nothing then")
    let post = body(repo, "private func sendGroupMessage(")
    check(before(post, "if let why = cannotActText(chat) {", "insertMessage(msgEntity, into: ctx)"),
          "a post is refused before anything is stored or sent")
    check(body(repo, "private func fanOutGroupMessage(").contains("let signer = groupSigner(chat) else {"),
          "and a held post is sent only with a signer")
    let accept = body(repo, "func acceptGroupInvite(")
    check(before(accept, "guard let signer = groupSigner(chat) else {", "chat.groupStatus = \"active\""), "an accept changes nothing without a signer")
    let quit = body(repo, "private func quitGroup(")
    check(before(quit, "if let why = cannotActText(chat) {", "prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, chatId)")
            && before(quit, "if let why = cannotActText(chat) {", "GroupChatManager.shared.sendLeave("),
          "a decline, leave or delete is refused before anything is recorded or sent")
    check(conversation.contains("if viewModel.isGroup, let why = cannotActText {\n                    // §8.7: the composer, accept and decline are disabled, with the reason.\n                    cannotActBar(why)"),
          "the conversation shows the text in place of the composer and the invite's buttons")
    check(conversation.contains("} else if isGroupPending && cannotActText == nil {"), "and no Accept or Decline in its menu")
    check(body(repo, "func createGroupChat(").contains("guard let signer = creationSigner() else {"), "no group is created while D loads")
}

func deleteFromThisDeviceSendsNoLeaveAndOwesNoGroupSync() {
    let local = body(repo, "func deleteGroupFromThisDevice(")
    check(local.contains("deleteChatLocal(chatId: chatId)") && !local.contains("quitGroup(") && !local.contains("sendLeave(")
            && !local.contains("oweGroupSync(") && !local.contains("recordLeft("),
          "removed here only: no leave, no G, nothing in D's left list")
    // Recorded closed on this device (decided 2026-10-11, the same on every client), before the
    // chat goes: a later invite or group sync for the id does not bring it back here.
    check(before(local, "prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, chatId)", "deleteChatLocal(chatId: chatId)"),
          "the id is recorded closed here, then the chat goes")
    check(body(repo, "private func groupStanding(").contains("ClosedGroups.contains(prefs.closedGroupIds, groupId)"),
          "a closed id stands closed")
    for op in [DistroGroupSync.Op.create, .accept, .post, .leave] {
        if case .nothing = DistroGroupSync.step(op, standing: .closed, ownMemberIsD: true, pendingMatches: false) {} else {
            check(false, "a \(op.rawValue) group sync for the id brings nothing back")
        }
    }
    check(!DeliveryPolicy.shouldProcess(action: GroupAction.invite, sourceAllowed: true, held: .none, sourceStatus: nil,
                                        namesOther: false, closed: true, signature: DeliveryPolicy.Signature.validated),
          "nor does an invite for it")
    check(conversation.contains("onDeleteFromThisDevice: {\n                        repository.deleteGroupFromThisDevice(chatId: chatId)"),
          "the chat info's Delete from this device calls it")
    check(conversation.contains("Label(GroupSelf.deleteLocalTitle, systemImage: \"trash\")")
            && conversation.contains("Text(GroupSelf.deleteLocalMessage)"),
          "with §8.7's words")
    checkEqual(GroupSelf.deleteLocalMessage,
               "This removes the group from this device only. You stay in the group on your other devices and for the other members.",
               "§8.7's words")
}

func aDGroupPostOwesOnePostSyncAndNoSentCopyAndAFailedSendOwesNeither() {
    let fan = body(repo, "private func fanOutGroupMessage(")
    check(fan.contains("guard submitted > 0 else {") && before(fan, "guard submitted > 0 else {", "self?.owePostSync(groupId: chatId, text: content, atMs: atMs, signer: signer)"),
          "the post G is owed only once an envelope was submitted")
    check(fan.contains("if owesSync && targets.isEmpty {\n            owePostSync("), "and at once when there is no member to send to")
    check(count(fan, "owePostSync(") == 2 && fan.contains("let owesSync = signer.isDistro"), "once, and only in a D-group")
    check(!fan.contains("oweDistroSentCopy") && !body(repo, "private func sendGroupMessage(").contains("oweDistroSentCopy"),
          "a group post owes no §17.11 copy")
    let fanout = body(manager, "func fanoutMessage(")
    check(fanout.contains("if client.sendMessageViaAppLinks(handle) {\n                submitted += 1") && fanout.contains("return submitted"),
          "submitted counts only the envelopes the router accepted")
    check(body(repo, "private func owePostSync(").contains("oweGroupSync(.post, groupId: groupId, signer: signer, atMs: atMs, text: text)"),
          "a post G carries the text at the post's time")
}

func deleteChatInADGroupSendsOneLeaveAsDAndOwesOneLeaveSync() {
    check(body(repo, "func deleteChat(").contains("quitGroup(chatId: chatId, how: \"deleted\")"), "deleting a group leaves it")
    let quit = body(repo, "private func quitGroup(")
    checkEqual(count(quit, "GroupChatManager.shared.sendLeave("), 1, "one leave")
    check(quit.contains("GroupChatManager.shared.sendLeave(groupId: chatId, to: targets, as: signer, via: client)"), "as the signer")
    check(quit.contains("if let signer, signer.isDistro {\n            recordLeft([chatId], distro: signer.hex)\n            oweGroupSync(.leave,"),
          "in a D-group, the id goes in the left list and one leave G is owed")
    checkEqual(count(quit, "oweGroupSync("), 1, "one G")
    let owe = body(repo, "private func oweGroupSync(")
    check(owe.contains("guard signer.isDistro else { return }")
            && owe.contains("left: prefs.distroLeftIds[d] ?? []")
            && owe.contains("DistroOutboxRuntime.shared.oweGroupSync(groupD: d, syncJson: json, deviceHex: device, label: label)"),
          "only D owes a G, carrying its left list, through the outbox")
}

// MARK: - §6.3: the first rules, on both paths

func aPostNamingASelfAddressFromAnotherSourceIsDroppedOnBothPaths() {
    let me: Set<String> = [D, THIS, SIB]
    checkEqual(GroupFirstRules.check(signature: DeliveryPolicy.Signature.validated, sourceHex: M, groupSender: D,
                                     selfAddresses: me, distros: [D], siblings: [SIB]), .selfSenderFromOther,
               "to D, from M, naming D: dropped")
    checkEqual(GroupFirstRules.check(signature: DeliveryPolicy.Signature.validated, sourceHex: M, groupSender: THIS,
                                     selfAddresses: [THIS], distros: [D], siblings: []), .selfSenderFromOther,
               "on the direct path, naming the device: dropped")
    checkEqual(GroupFirstRules.check(signature: DeliveryPolicy.Signature.validated, sourceHex: D, groupSender: D,
                                     selfAddresses: me, distros: [D], siblings: [SIB]), .ownEcho, "from D: the user's own echo")
    checkEqual(GroupFirstRules.check(signature: DeliveryPolicy.Signature.validated, sourceHex: SIB, groupSender: SIB,
                                     selfAddresses: me, distros: [D], siblings: [SIB]), .pass(ownAct: true),
               "from a known sibling: the user's own act")
    checkEqual(GroupFirstRules.check(signature: DeliveryPolicy.Signature.validated, sourceHex: M, groupSender: M,
                                     selfAddresses: me, distros: [D], siblings: [SIB]), .pass(ownAct: false), "M's own: the rule decides")
    let admit = body(repo, "private func admitGroupMessage(")
    check(before(admit, "GroupFirstRules.check(", "DeliveryPolicy.shouldProcess(")
            && span(admit, from: "case .selfSenderFromOther:", to: "case .pass(").contains("return .droppedFirst"),
          "the first rules come before the group rule, and drop for good")
    for (name, f) in [("the direct path", "private func handleIncomingMessage("), ("the NSE import", "func importNSEMessages()"),
                      ("the distro path", "private func handleDistroGroupArrival(")] {
        check(body(repo, f).contains("admitGroupMessage("), "\(name) admits through them")
    }
}

func aForgedPostIsNotStoredNotHeldAndNotNotifiedOnBothPaths() {
    checkEqual(GroupFirstRules.check(signature: DeliveryPolicy.Signature.invalid, sourceHex: M, groupSender: M,
                                     selfAddresses: [THIS], distros: [D], siblings: []), .forged, "a forged post is dropped")
    check(!HeldArrivals.holdable(isPostSync: false, action: nil, held: .pending, closed: false, filtered: false,
                                 signature: DeliveryPolicy.Signature.invalid, sourceIsSelf: false, keptIfJoined: true),
          "never held")
    let file = NSEGroups(filterOn: false, inviters: [], groups: [GID: .init(name: GROUP_NAME, state: "joined", accepted: [M])],
                         closed: [], selfAddresses: [THIS])
    checkEqual(NSEGroupShow.decide(isGroupSync: false, groupId: GID, action: nil, groupName: nil, members: [], source: M,
                                   groupSender: M, signatureValidated: false, unverifiedReason: 2, distro: D, file: file),
               .nothing, "never notified by the NSE")
    check(span(body(repo, "private func admitGroupMessage("), from: "case .forged:", to: "case .ownEcho:").contains("return .droppedFirst"),
          "dropped before the group rule")
}

// MARK: - §11: the group sync

func reading(_ object: Any) -> DistroGroupSync.Reading { decode(DistroGroupSync.Reading.self, object)! }

func theGroupSyncRules() {
    // Every op of the vectors passes rule 4 here as in the shared layer.
    for v in gvList("ops") + gvList("variants") {
        let name = v["name"] as! String
        let expected = v["expected"] as! [String: Any]
        let r = reading(expected)
        let form = DistroGroupSync.form(r, distroHex: D)
        if expected["problem"] is NSNull || expected["problem"] == nil {
            if case .success(let f) = form {
                checkEqual(f.op.rawValue, expected["op"] as? String, "\(name): the op")
                checkEqual(f.groupId, (expected["group_id"] as! String).lowercased(), "\(name): the group")
                if f.op == .create || f.op == .accept {
                    check(f.members.contains(D), "\(name): the members name D")
                    checkEqual(f.membersCsv, expected["members"] as? String, "\(name): the csv verbatim")
                }
            } else {
                check(false, "\(name): passes rule 4 as the shared layer says (\(form))")
            }
        } else if case .success = form {
            check(false, "\(name): fails rule 4 as the shared layer says")
        }
    }
    // Rule 4 again on the reading, whatever the bridge build.
    let good = reading(gvList("ops").first { $0["name"] as? String == "accept_empty_left" }!["expected"]!)
    func fails(_ change: (inout DistroGroupSync.Reading) -> Void, _ what: String) {
        var r = good
        change(&r)
        if case .success = DistroGroupSync.form(r, distroHex: D) { check(false, "rule 4: \(what)") }
    }
    fails({ $0.members = "\(M),\(OTHER)" }, "members that do not name D")
    fails({ $0.creator = D }, "creator D")
    fails({ $0.creator = X }, "a creator not listed")
    fails({ $0.left = (0..<33).map(id32) }, "33 ids in left")
    fails({ $0.left = ["xyz"] }, "an id in left that is not 32 hex")
    fails({ $0.atMs = 9_007_199_254_740_992 }, "at_ms past 2^53 - 1")
    fails({ $0.op = "rename" }, "an op that is not one of the four")
    fails({ $0.problem = "0xFC is absent" }, "the unwrap's problem")

    // Rules 1 to 3.
    checkEqual(DistroGroupSync.disposition(sourceHex: M, distroHex: D, signatureValidated: true, reading: good, deviceHex: THIS),
               .notFromDistro, "rule 1: a source that is not D is ignored")
    checkEqual(DistroGroupSync.disposition(sourceHex: D, distroHex: D, signatureValidated: false, reading: good, deviceHex: THIS),
               .forged, "rule 2: a signature that does not validate under D is dropped")
    checkEqual(DistroGroupSync.disposition(sourceHex: D, distroHex: D, signatureValidated: true, reading: good, deviceHex: SIB),
               .ownEcho, "rule 3: this device's own echo")
    if case .apply(let f, let sibling) = DistroGroupSync.disposition(sourceHex: D, distroHex: D, signatureValidated: true,
                                                                    reading: good, deviceHex: THIS) {
        checkEqual(sibling, SIB, "its 0xFD is a sibling")
        checkEqual(f.creator, M, "the accept names its creator")
    } else {
        check(false, "a sibling's accept is applied")
    }

    // §11.2's table.
    typealias S = DistroGroupSync
    checkEqual(S.step(.create, standing: .notHeld, ownMemberIsD: false, pendingMatches: false), .holdFromSync, "create, not held: held from G")
    checkEqual(S.step(.accept, standing: .notHeld, ownMemberIsD: false, pendingMatches: false), .holdFromSync, "accept, not held: held from G")
    checkEqual(S.step(.accept, standing: .closed, ownMemberIsD: false, pendingMatches: false),
               .nothing("the group was left here, for good"), "a later-stamped accept after a leave does not reopen")
    checkEqual(S.step(.leave, standing: .notHeld, ownMemberIsD: false, pendingMatches: false), .tombstone,
               "a leave for a group not held: recorded closed")
    check(!DeliveryPolicy.shouldProcess(action: GroupAction.invite, sourceAllowed: true, held: .none, sourceStatus: nil,
                                        namesOther: false, closed: ClosedGroups.contains(ClosedGroups.record([], GID), GID),
                                        signature: DeliveryPolicy.Signature.validated),
          "which blocks a later invite")
    if case .nothing = S.step(.accept, standing: .joined, ownMemberIsD: false, pendingMatches: false) {} else {
        check(false, "a G for a group held as the device is ignored")
    }
    if case .nothing = S.step(.leave, standing: .pending, ownMemberIsD: false, pendingMatches: false) {} else {
        check(false, "a leave G for a group held as the device is ignored")
    }
    checkEqual(S.step(.post, standing: .joined, ownMemberIsD: true, pendingMatches: false), .storeOwnPost, "post, joined: the user's own post")
    checkEqual(S.step(.post, standing: .pending, ownMemberIsD: true, pendingMatches: false), .holdArrival, "post, pending: held")
    checkEqual(S.step(.post, standing: .notHeld, ownMemberIsD: false, pendingMatches: false), .holdArrival, "post, not held: held")

    // The wiring: rule 0 silent; each G judged in order; nothing applied sends anything.
    let unwrap = body(distroClient, "nonisolated private static func unwrapAndDeliver(")
    let sync = span(unwrap, from: "case .groupSync(let hash):", to: "case .group(let hash, let groupId):")
    check(sync.contains("let key = DistroGroupSync.syncSeenKey(hashHex: hash)") && sync.contains("guard !seen.contains(key) else { return }")
            && sync.contains("if kept { blobQueue.async { seen.record(key) } }"),
          "rule 0: a repeat is dropped silently; a G is recorded only when kept")
    let handle = body(repo, "private func handleDistroGroupSync(")
    check(handle.contains("case .ownEcho:\n            return true") && handle.contains("case .forged:") && handle.contains("(§11.1 rule 2)")
            && handle.contains("(§11.1 rule 1)") && handle.contains("(§11.1 rule 4)"),
          "the receiver logs each drop and records its own echo")
    let applying = span(repo, from: "    // MARK: The group sync G (§11)", to: "    // MARK: Shown")
    check(!applying.isEmpty && !applying.contains("GroupChatManager") && !applying.contains("oweGroupSync(")
            && !applying.contains("quitGroup(") && !applying.contains("owePostSync("),
          "applying a G never sends anything and never owes a G")
}

func aPendingInviteFromMThenAnAcceptSyncFromCDiscardsTheInviteAndHoldsTheGroupFromTheSync() {
    typealias S = DistroGroupSync
    checkEqual(S.step(.accept, standing: .pending, ownMemberIsD: true, pendingMatches: false), .discardPendingThenHold,
               "another inviter's pending invite is discarded, the group held from G")
    checkEqual(S.step(.create, standing: .pending, ownMemberIsD: true, pendingMatches: false), .discardPendingThenHold,
               "so is one under a create G")
    checkEqual(S.step(.accept, standing: .pending, ownMemberIsD: true, pendingMatches: true), .joinPending,
               "a matching accept G joins the held invite")
    let apply = body(repo, "private func applyGroupSync(")
    let discard = span(apply, from: "case .discardPendingThenHold:", to: "case .joinPending:")
    check(before(discard, "deleteChatLocal(chatId: groupId, forgetHeld: false)", "holdGroupFromSync(form, distro: d, what: what)")
            && !discard.contains("quitGroup(") && !discard.contains("declineGroupInvite("),
          "discarded locally (keeping what was held for it), then held from G")
    check(apply.contains("return chat.creatorHash == form.creator && Set(groupRows(groupId).map(\\.hash)) == Set(form.members)"),
          "matching: the same creator and the same list")
    let hold = body(repo, "private func holdGroupFromSync(")
    check(hold.contains("let creator = form.op == .create ? d : (form.creator ?? d)")
            && hold.contains("creatorHash: creator, ownMember: d, membersCsv: form.membersCsv"),
          "the group from G: creator C (or D for create), own address D")
    check(hold.contains("let accepted = member == d || (form.op == .accept && member == creator)"), "D and the creator accepted")
}

func aCreateSyncAppliedLetsTheMembersPassTheFilterSelfExcluded() {
    let hold = body(repo, "private func holdGroupFromSync(")
    check(hold.contains("for member in form.members where !selfAddresses.contains(member) {\n            ensureAllowlistedContact(destHash: member)"),
          "the members pass the filter by association, no self address")
    check(hold.contains("bindSyncKeys(form.keys, listed: form.members, selfAddresses: selfAddresses)"), "their keys are bound as an invite's")
    check(hold.contains("prefs.filteredInviteIds = FilteredInvites.remove(prefs.filteredInviteIds, groupId)"), "the id leaves the filtered set")
    let me = GroupSelf.addresses(ownMember: D, device: THIS, listed: [D, M, OTHER], heldDistro: D, siblings: { _ in [SIB] })
    checkEqual([D, M, OTHER].filter { !me.contains($0) }, [M, OTHER], "never D")
}

func aLeaveSyncRemovesTheConversationAndRecordsTheIdClosedSendingNothing() {
    checkEqual(DistroGroupSync.step(.leave, standing: .joined, ownMemberIsD: true, pendingMatches: false), .close, "joined: closed")
    checkEqual(DistroGroupSync.step(.leave, standing: .pending, ownMemberIsD: true, pendingMatches: false), .close, "pending: closed")
    let close = body(repo, "private func closeGroupFromSync(")
    check(close.contains("prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, groupId)")
            && close.contains("deleteChatLocal(chatId: groupId)") && !close.contains("quitGroup(") && !close.contains("sendLeave("),
          "recorded closed and removed, with nothing sent")
}

func leftClosesAGroupASiblingStillHoldsAsD() {
    let v = gvList("ops").first { $0["name"] as? String == "post_full_left" }!
    guard case .success(let form) = DistroGroupSync.form(reading(v["expected"]!), distroHex: D) else {
        check(false, "the post G with a full left passes")
        return
    }
    let y = form.left[3]
    let ids = DistroGroupSync.leftIds(form)
    check(ids.contains(y) && !ids.contains(form.groupId) && Set(ids).count == ids.count, "each id other than G's own, once")
    checkEqual(DistroGroupSync.leftStep(standing: .joined, ownMemberIsD: true), .close, "Y still joined as D: closed")
    checkEqual(DistroGroupSync.leftStep(standing: .pending, ownMemberIsD: true), .close, "pending as D: closed")
    checkEqual(DistroGroupSync.leftStep(standing: .joined, ownMemberIsD: false), .ignore, "held as the device: ignored")
    checkEqual(DistroGroupSync.leftStep(standing: .notHeld, ownMemberIsD: false), .tombstone, "not held: recorded closed")
    checkEqual(DistroGroupSync.leftStep(standing: .closed, ownMemberIsD: false), .alreadyClosed, "closed already: kept in the list")
    let list = DistroGroupSync.recordLeft([id32(100)], into: (0..<32).map(id32))
    checkEqual(list.count, 32, "the left list holds 32")
    checkEqual(list.first, id32(100), "the newest first")
    check(!list.contains(id32(31)), "the oldest forgotten")
    checkEqual(DistroGroupSync.recordLeft([id32(5)], into: [id32(1), id32(5)]), [id32(5), id32(1)], "an id once")
    let handle = body(repo, "private func handleDistroGroupSync(")
    check(before(handle, "let kept = applyGroupSync(form, arrival: a)", "applyLeft(form, distro: a.distroHex, hash: a.hash)"),
          "left is applied after the op")
    let left = body(repo, "private func applyLeft(")
    check(left.contains("case .close:\n                closeGroupFromSync(id,"), "and closes such a group as a leave G would")
}

// MARK: - §6.5: held arrivals

func item(_ seq: Int, group: String, source: String, size: Int = 1000, validated: Bool = true,
          counts: Bool = true, hash: String? = nil) -> HeldArrivals.Item {
    HeldArrivals.Item(seq: seq, groupId: group, source: source, hash: hash ?? hash64(seq), signature: nil,
                      validated: validated, size: size, countsAgainstSource: counts)
}

/// `items` after `new` is decided.
func apply(_ new: HeldArrivals.Item, to items: [HeldArrivals.Item], pending: @escaping (String) -> Bool) -> [HeldArrivals.Item] {
    switch HeldArrivals.decide(new, existing: items, pending: pending) {
    case .duplicate, .refuse: return items
    case .hold(let evict):
        let gone = Set(evict.map(\.seq))
        return items.filter { !gone.contains($0.seq) } + [new]
    }
}

func aCreatorStatusAndAPostSyncHeldWhilePendingAreAppliedAfterTheAcceptSyncNotDroppedAsRepeats() {
    let C = String(repeating: "c3", count: 16)
    // A creator's status for a group held pending: kept were the group joined, so held.
    let keptIfJoined = DeliveryPolicy.shouldProcess(action: GroupAction.status, sourceAllowed: false, held: .joined,
                                                    sourceStatus: MemberStatus.accepted, namesOther: false, closed: false,
                                                    signature: DeliveryPolicy.Signature.validated, sourceIsCreator: true)
    check(keptIfJoined, "the status counts once joined")
    check(!DeliveryPolicy.shouldProcess(action: GroupAction.status, sourceAllowed: false, held: .pending,
                                        sourceStatus: MemberStatus.accepted, namesOther: false, closed: false,
                                        signature: DeliveryPolicy.Signature.validated, sourceIsCreator: true),
          "and is dropped while pending")
    check(HeldArrivals.holdable(isPostSync: false, action: GroupAction.status, held: .pending, closed: false, filtered: false,
                                signature: DeliveryPolicy.Signature.validated, sourceIsSelf: false, keptIfJoined: keptIfJoined),
          "so it is held instead")
    check(HeldArrivals.holdable(isPostSync: true, action: nil, held: .pending, closed: false, filtered: false,
                                signature: DeliveryPolicy.Signature.validated, sourceIsSelf: false, keptIfJoined: true),
          "a post G for it is held too")
    var items: [HeldArrivals.Item] = []
    items = apply(item(1, group: GID, source: C), to: items) { $0 == GID }
    items = apply(item(2, group: GID, source: D, counts: false), to: items) { $0 == GID }
    checkEqual(items.map(\.seq), [1, 2], "both held, in arrival order")

    // Held is never seen: the replay judges each as a new arrival, after the accept G joined the group.
    let apply = body(repo, "private func applyGroupSync(")
    check(span(apply, from: "case .holdArrival:", to: "case .nothing(let why):").contains("countsAgainstSource: false, distro: d, what: \"post sync\")\n            return false"),
          "a held post G is not recorded as seen")
    let arrival = body(repo, "private func handleDistroGroupArrival(")
    check(arrival.contains("holdIfOnlyNotJoined(a, fields: fields, standing: standing, signature: signature, distro: distro)\n            return false"),
          "nor a held group message")
    for f in ["private func joinPendingFromSync(", "private func holdGroupFromSync(", "func acceptGroupInvite("] {
        check(body(repo, f).contains("replayHeldArrivals(groupId: groupId)"), "\(f) replays what was held")
    }
    let replay = body(repo, "private func replayHeldArrivals(")
    check(replay.contains("sortBy: [SortDescriptor(\\.seq)]") && before(replay, "for row in rows { ctx.delete(row) }", "for blob in blobs { RfedDistroClient.ingestBlob(blob) }"),
          "in arrival order, through the distro path again, forgotten first")
}

func strangersCannotEvictAHeldCreatorStatusAndForgedSelfOrFilteredTrafficIsNeverHeld() {
    let C = String(repeating: "c3", count: 16)
    let pendingGroup = GID
    let isPending: (String) -> Bool = { $0 == pendingGroup }
    var items = apply(item(1, group: pendingGroup, source: C), to: []) { isPending($0) }
    // 64 proven group messages from strangers for random group ids.
    for n in 0..<64 {
        items = apply(item(10 + n, group: id32(1000 + n), source: id32(5000 + n)), to: items) { isPending($0) }
    }
    check(items.contains { $0.seq == 1 }, "the creator's status survives")
    check(items.filter { $0.groupId != pendingGroup }.count <= HeldArrivals.notHeldMax, "groups not held get 16 at most")
    // Strangers' large blobs reach the byte bound before the 16: what it evicts is still never a
    // pending group's (mutation: any blob evictable takes the creator's status, the oldest).
    var heavy = apply(item(1, group: pendingGroup, source: C, size: 60 * 1024), to: []) { isPending($0) }
    for n in 0..<16 {
        heavy = apply(item(700 + n, group: id32(2000 + n), source: id32(7000 + n), size: 60 * 1024), to: heavy) { isPending($0) }
    }
    check(heavy.contains { $0.seq == 1 }, "the byte bound evicts strangers' blobs, never the pending group's")
    check(heavy.reduce(0) { $0 + $1.size } <= HeldArrivals.maxBytes, "within 256 KiB")
    // A flood from one source for the pending group: 8 per source.
    var flood = [item(1, group: pendingGroup, source: C)]
    for n in 0..<20 { flood = apply(item(100 + n, group: pendingGroup, source: M), to: flood) { isPending($0) } }
    checkEqual(flood.filter { $0.source == M }.count, HeldArrivals.perSource, "8 per source")
    check(flood.contains { $0.seq == 1 }, "and the creator's status is not the one evicted")
    // 16 per group, oldest of the largest source first.
    var perGroup: [HeldArrivals.Item] = []
    for n in 0..<20 { perGroup = apply(item(200 + n, group: pendingGroup, source: id32(n % 4)), to: perGroup) { isPending($0) } }
    checkEqual(perGroup.count, HeldArrivals.perGroup, "16 per group")
    // The byte bounds.
    if case .refuse = HeldArrivals.decide(item(300, group: pendingGroup, source: M, size: 64 * 1024 + 1), existing: [], pending: isPending) {} else {
        check(false, "a blob over 64 KiB is never held")
    }
    var big: [HeldArrivals.Item] = []
    for n in 0..<8 { big = apply(item(400 + n, group: id32(n), source: id32(600 + n), size: 60 * 1024), to: big) { _ in true } }
    check(big.reduce(0) { $0 + $1.size } <= HeldArrivals.maxBytes, "256 KiB in all")
    // The same message twice is held once; a validated copy replaces an unverified one.
    let once = apply(item(500, group: pendingGroup, source: M, hash: hash64(42)), to: []) { isPending($0) }
    if case .duplicate = HeldArrivals.decide(item(501, group: pendingGroup, source: M, hash: hash64(42)), existing: once, pending: isPending) {} else {
        check(false, "a repeat is held once")
    }
    let unverified = apply(item(502, group: pendingGroup, source: M, validated: false, hash: hash64(43)), to: []) { isPending($0) }
    checkEqual(apply(item(503, group: pendingGroup, source: M, hash: hash64(43)), to: unverified) { isPending($0) }.map(\.seq), [503],
               "a validated copy replaces an unverified one")
    // Never held: forged, from a self address, for a filtered group, an invite, a relay request, a joined or closed group.
    func holdable(_ signature: Int = DeliveryPolicy.Signature.validated, action: String? = nil, held: DeliveryPolicy.Held = .pending,
                  closed: Bool = false, filtered: Bool = false, sourceIsSelf: Bool = false) -> Bool {
        HeldArrivals.holdable(isPostSync: false, action: action, held: held, closed: closed, filtered: filtered,
                              signature: signature, sourceIsSelf: sourceIsSelf, keptIfJoined: true)
    }
    check(!holdable(DeliveryPolicy.Signature.invalid), "a forged message is never held")
    check(!holdable(sourceIsSelf: true), "nor one from a self address")
    check(!holdable(filtered: true), "nor a filtered group's")
    check(!holdable(action: GroupAction.invite) && !holdable(action: GroupAction.relayRequest), "nor an invite or a relay request")
    check(!holdable(held: .joined) && !holdable(closed: true), "nor anything for a group joined or closed")
    check(!holdable(DeliveryPolicy.Signature.sourceUnknown, held: .none), "for a group not held, only a proven message")
    check(holdable(held: .none), "which is held")
    let hold = body(repo, "private func holdArrival(")
    check(hold.contains("evicted: \\(eviction.bound) (§6.5)") && hold.contains("not held: \\(why) (§6.5)"),
          "every eviction and refusal is logged with its bound")
}

// MARK: - §12.1: the creator is D on every device of D

@MainActor
func aCreatorThatIsDOnTwoDevicesBothAnswerAKeyedAcceptAndOneThatAppliedTheLeaveAnswersNothing() {
    let dHex = V.hashOf(V.creator)
    func device(_ own: String) -> GroupRig {
        let r = GroupRig(V, me: V.creator)
        r.engine = GroupStatusEngine(
            store: r.store, native: r.native, isSelf: { _, hex in hex == dHex || hex == own },
            answer: { [unowned r] chat, member, statuses in r.answers.append(Answer(chat: chat.id, to: member, statuses: statuses)) },
            switched: false, log: { [unowned r] in r.logs.append($0) })
        r.hold(accepted: true)
        return r
    }
    let first = device(THIS), second = device(SIB)
    let m = MessageMaker(V)
    let accept = m.msg("alice")
    first.receive(accept)
    second.receive(accept)
    checkEqual(first.answeredNames(), ["alice"], "the first device of D answers the keyed accept")
    checkEqual(second.answeredNames(), ["alice"], "and so does the second")
    // The second applied the user's leave G: the group is gone there.
    second.store.chats[V.groupId] = nil
    second.store.memberRows[V.groupId] = nil
    let bob = m.msg("bob")
    first.receive(bob)
    second.receive(bob)
    checkEqual(first.answeredNames(), ["alice", "bob"], "the device still holding it answers")
    checkEqual(second.answeredNames(), ["alice"], "the device that applied the leave answers nothing")
    // The app's engine asks the group's self.
    check(repo.contains("isSelf: { [weak self] chatId, hex in self?.isGroupSelf(chatId: chatId, hex: hex) ?? false }"),
          "ChatRepository's engine asks the group's self addresses")
}

// MARK: - §6.7: the NSE

func theNotificationServiceShowsGroupTrafficOnlyAsTheAppWouldAndTheAppDoesNotNotifyAgain() {
    let file = NSEGroups(filterOn: true, inviters: [M], groups: [GID: .init(name: GROUP_NAME, state: "joined", accepted: [M, D])],
                         closed: [id32(9)], selfAddresses: [THIS, SIB])
    func show(sync: Bool = false, group: String? = GID, action: String? = nil, members: [String] = [], source: String = M,
              sender: String? = nil, validated: Bool = true, reason: Int? = 0, file f: NSEGroups? = nil) -> NSEGroupShow.Outcome {
        NSEGroupShow.decide(isGroupSync: sync, groupId: group, action: action, groupName: GROUP_NAME, members: members,
                            source: source, groupSender: sender, signatureValidated: validated, unverifiedReason: reason,
                            distro: D, file: f ?? file)
    }
    let other = id32(77)
    checkEqual(show(sync: true), .nothing, "a group sync shows nothing")
    checkEqual(show(action: GroupAction.accept), .nothing, "a control shows nothing")
    checkEqual(show(action: GroupAction.status), .nothing, "nor a status")
    checkEqual(show(group: other, action: GroupAction.invite, members: [D, M]), .invite(groupId: other, groupName: GROUP_NAME),
               "an invite to D the filter admits shows \"Group invitation\"")
    checkEqual(show(group: other, action: GroupAction.invite, members: [D, M], source: X), .nothing, "from an inviter it does not, nothing")
    let off = NSEGroups(filterOn: false, inviters: [], groups: [:], closed: [], selfAddresses: [])
    checkEqual(show(group: other, action: GroupAction.invite, members: [D, M], source: X, file: off),
               .invite(groupId: other, groupName: GROUP_NAME), "with the filter off, from anyone")
    checkEqual(show(group: other, action: GroupAction.invite, members: [M]), .nothing, "an invite that does not list D, nothing")
    checkEqual(show(group: id32(9), action: GroupAction.invite, members: [D, M]), .nothing, "nor one for a closed group")
    checkEqual(show(action: GroupAction.invite, members: [D, M]), .nothing, "nor one for a group held already")
    checkEqual(show(), .post(groupId: GID, groupName: GROUP_NAME), "a joined group's validated post from an accepted member shows")
    checkEqual(show(source: X), .nothing, "a post from a non-member, nothing")
    checkEqual(show(validated: false, reason: 2), .nothing, "a forged one, nothing")
    checkEqual(show(validated: false, reason: 1), .nothing, "an unproven one, nothing")
    checkEqual(show(source: SIB), .nothing, "one from a self address, nothing")
    checkEqual(show(source: D), .nothing, "one from D, nothing")
    checkEqual(show(sender: THIS), .nothing, "one naming a self address, nothing")
    checkEqual(NSEGroupShow.decide(isGroupSync: false, groupId: GID, action: nil, groupName: nil, members: [], source: M,
                                   groupSender: nil, signatureValidated: true, unverifiedReason: 0, distro: D, file: nil),
               .nothing, "with no shared file yet, nothing")
    let pending = NSEGroups(filterOn: false, inviters: [], groups: [GID: .init(name: GROUP_NAME, state: "pending", accepted: [M])],
                            closed: [], selfAddresses: [])
    checkEqual(show(file: pending), .nothing, "a pending group's post, nothing")
    // The shared file: the app's keys, and a file without "self" still reads.
    let data = try! JSONEncoder().encode(file)
    let text = String(data: data, encoding: .utf8)!
    check(text.contains("\"filter_on\"") && text.contains("\"self\""), "the file's keys")
    checkEqual(try? JSONDecoder().decode(NSEGroups.self, from: data), file, "it reads back")
    let older = try? JSONDecoder().decode(NSEGroups.self, from: Data("{\"filter_on\":true,\"inviters\":[],\"groups\":{},\"closed\":[]}".utf8))
    checkEqual(older?.selfAddresses, [], "a file without self still reads")

    // The wiring: thread and chatId the group id, the hashes counted, and the app does not notify again.
    let service = source("NotificationService/NotificationService.swift")
    check(service.contains("group.groupId, group.isInvite ? title : \"\\(title) (\\(group.groupName))\")"),
          "the notification opens the group (thread and chatId = the group id)")
    check(before(service, "PendingNotification.recordNSECountedGroupHashes(", "finishWithContent(updated)"),
          "the hashes it counted are recorded before it shows")
    let pull = source("NotificationService/NSEDistroPull.swift")
    check(pull.contains("NSEGroupShow.decide(") && pull.contains("let groups = PendingNotification.readNSEGroups()"),
          "the NSE decides with the shared file")
    check(before(body(repo, "private func handleGroupChatMessage("), "PendingNotification.takeNSECountedGroupHash(msgHashHex)", "notifManager.postMessageNotification("),
          "the app's group post skips a hash the NSE counted")
    check(before(body(repo, "private func handleGroupInvite("), "PendingNotification.takeNSECountedGroupHash(hashHex)", "notifManager.postMessageNotification("),
          "so does its invite")
    check(repo.contains("PendingNotification.writeNSEGroups(groupsSnapshot)"), "the app writes the file on every refresh")
}

// MARK: - §9.1, §9.2, §9.3, §12.3, §6.4

func siblingsAreLearntFromEveryAcceptedDeviceAddressAndKeptWhileAGroupNeedsThem() {
    var known: [String: [String]] = [:]
    known = KnownSiblings.learn(known, by: SIB, distro: D, device: THIS)
    known = KnownSiblings.learn(known, by: SIB.uppercased(), distro: D, device: THIS)
    known = KnownSiblings.learn(known, by: THIS, distro: D, device: THIS)
    known = KnownSiblings.learn(known, by: D, distro: D, device: THIS)
    known = KnownSiblings.learn(known, by: "nope", distro: D, device: THIS)
    checkEqual(known, [D: [SIB]], "a sibling once; never the device, D or a non-address")
    let D2 = String(repeating: "d2", count: 16)
    let both = [D: [SIB], D2: [OTHER]]
    checkEqual(KnownSiblings.prune(both, heldDistro: D2, ownMembers: []), [D2: [OTHER]], "a distro given up drops its siblings")
    checkEqual(KnownSiblings.prune(both, heldDistro: D2, ownMembers: [D]), both, "unless a group here still has it as its own address")
    check(distroClient.contains("onSiblingSeen?(c.marker.byHex, d)") && distroClient.contains("if c.signedByDistro { onSiblingSeen?(c.sentBy, c.distroHex) }"),
          "the §17.12 and §17.11 receivers learn siblings too")
    let handle = body(repo, "private func handleDistroGroupSync(")
    check(handle.contains("case .apply(let form, let sibling):\n            if let sibling { learnSibling(sibling, of: a.distroHex) }"), "and the group sync")
    check(repo.contains("RfedDistroClient.shared.onSiblingSeen = { [weak self] by, distro in\n            self?.learnSibling(by, of: distro)"),
          "wired to the repository")
    check(body(repo, "private func groupSelf(_ chat: ChatEntity").contains("siblings: knownSiblings(of:)"),
          "a sibling is one of the user's own addresses in a group naming its distro (§9.1), not everywhere")
}

func anOlderSiblingsPostIsStoredAsTheUsersOwnOutgoingPost() {
    let chatMessage = body(repo, "private func handleGroupChatMessage(")
    check(chatMessage.contains("let own = ownAct || author == ownHashHex || selfAddresses.contains(author)")
            && chatMessage.contains("isOutgoing: own,") && chatMessage.contains("if own {\n            // The user's own post: no notification."),
          "a post by packet source from a self address is the user's own, outgoing, not notified")
    check(body(repo, "private func handleGroupMessage(").contains("selfAddresses: groupSelf(chat, rows: standing.members), ownAct: ownAct)"),
          "with the group's self addresses and the first rules' verdict")
}

func theInviteHandlerAddsTheUserOnlyIfListed() {
    check(GroupSelf.ownMemberForInvite(listed: [M, OTHER], device: THIS, heldDistro: D) == nil, "an invite listing neither is not for the user")
    checkEqual(GroupSelf.ownMemberForInvite(listed: [M, THIS], device: THIS, heldDistro: D), THIS, "the device when listed")
    checkEqual(GroupSelf.ownMemberForInvite(listed: [M, THIS], device: THIS, heldDistro: nil), THIS, "and with no distro")
    let invite = body(repo, "private func handleGroupInvite(")
    check(invite.contains("guard let ownMember else {") && invite.contains("not for this user, dropped (§9.3)")
            && !invite.contains("[srcHex, ownHashHex]"),
          "dropped with a log line; no self-add")
}

func relayRequestsOnTheDistroPathAndInADGroupAreNotActedOn() {
    let arrival = body(repo, "private func handleDistroGroupArrival(")
    check(before(arrival, "if action == GroupAction.relayRequest {", "admitGroupMessage(") && arrival.contains("(§12.3)"),
          "a relay request to D is dropped before anything")
    let handle = body(repo, "private func handleGroupMessage(")
    check(span(handle, from: "case GroupAction.relayRequest:", to: "handleGroupRelayRequest(").contains("GroupSelf.isDistroGroup(ownMember: chat.ownMember, device: ownHashHex)"),
          "nor acted on in a D-group on the direct path")
}

func aMembersAcceptToDCarryingANameShowsThatNameInTheMemberList() {
    let arrival = body(repo, "private func handleDistroGroupArrival(")
    check(before(arrival, "applyMessageName(a.displayName, unverifiedReason: a.unverifiedReason, sourceHex: srcHex,", "handleGroupMessage("),
          "the name row of the direct path is made for its source")
    check(conversation.contains("Text(repository.groupMemberDisplayName(for: member.memberHash, groupId: chatId))"),
          "the member list shows the member's name (and \"You\" for the user's addresses)")
    check(body(repo, "func groupMemberDisplayName(").contains("if isGroupSelf(chatId: groupId, hex: hash) { return \"You\" }\n        return resolvedContactName(for: hash) ?? DisplayNames.shortHash(hash)"),
          "resolved as any contact's name, \"You\" for exactly the group's self addresses")
}

// MARK: - §10.5: the writer's JSON; §13: the words

func theWriterJSONCarriesExactlyWhatTheOpCarries() {
    for v in gvList("ops") {
        let s = v["sync"] as! [String: Any]
        let op = DistroGroupSync.Op(rawValue: s["op"] as! String)!
        let json = DistroGroupSync.writerJSON(op: op, groupId: s["group_id"] as! String, atMs: (s["at_ms"] as! NSNumber).uint64Value,
                                              name: s["name"] as? String, membersCsv: s["members"] as? String,
                                              keys: s["keys"] as? [String], creator: s["creator"] as? String,
                                              text: s["text"] as? String, left: s["left"] as! [String])
        let back = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let want = s.filter { !($0.value is NSNull) }
        checkEqual(Set(back.keys), Set(want.keys), "\(v["name"]!): the keys of the op")
        checkEqual(back["at_ms"] as? NSNumber, want["at_ms"] as? NSNumber, "\(v["name"]!): at_ms as an integer")
        checkEqual(back["members"] as? String, want["members"] as? String, "\(v["name"]!): the csv verbatim")
        checkEqual(back["text"] as? String, want["text"] as? String, "\(v["name"]!): the text")
        checkEqual(back["left"] as? [String], want["left"] as? [String], "\(v["name"]!): left")
    }
    checkEqual(DistroGroupSync.atMs(1_790_000_000.125), 1_790_000_000_125, "at_ms from seconds")
    checkEqual(DistroGroupSync.entryId(hashHex: hash64(1)), "group:" + hash64(1), "owed under group:<hash>")
}

func theConfirmationsInADGroupSayOnAllYourDevices() {
    for (text, why) in [
        ("static let distroDeclineTitle = \"Decline this invitation?\"", "decline title"),
        ("static let distroDeclineMessage = \"This declines it on all your devices, and you cannot join this group later.\"", "decline"),
        ("static let distroMessage = \"You will leave it on all your devices, its messages are deleted from all of them, and you cannot rejoin.\"", "leave"),
        ("static let distroTitle = \"Delete this group?\"", "delete title"),
        ("static let distroMessage = \"This leaves it and deletes its messages on all your devices, and you cannot rejoin.\"", "delete"),
    ] {
        check(conversation.contains(text), "§13's words: \(why)")
    }
    check(conversation.contains("GroupLeaveText.title(distro: isDistroGroup)") && conversation.contains("Text(GroupLeaveText.message(distro: isDistroGroup))"),
          "the leave dialog")
    check(conversation.contains("GroupDeleteText.title(distro: isDistroGroup)") && conversation.contains("GroupInviteText.title(distro: isDistroGroup)"),
          "the delete and decline dialogs of the conversation")
    check(chatList.contains("GroupDeleteText.title(distro: leaving?.isDistroGroup ?? false)")
            && chatList.contains("GroupInviteText.title(distro: declining?.isDistroGroup ?? false)"),
          "and of the chat list")
    check(conversation.contains("static let declineTitle = \"Decline this group invite?\"")
            && conversation.contains("static let title = \"Delete and leave this group?\""),
          "a device group keeps its words")
}

// MARK: - The review of e89924e

/// §9.2, §12.1: a self address is never a send target, a status included. In a list naming D and
/// an older sibling's device entry (§14), the sibling's own keyed accept counts for its entry, and
/// no device of D answers it.
@MainActor
func aSiblingsOwnAcceptIsNeverAnsweredWithAStatus() {
    let dHex = V.hashOf(V.creator)
    let aliceHex = V.hashOf("alice")
    let r = GroupRig(V, me: V.creator)
    // alice is a known sibling of D here: an older device of the user, listed as its device entry.
    r.engine = GroupStatusEngine(
        store: r.store, native: r.native, isSelf: { _, hex in hex == dHex || hex == THIS || hex == aliceHex },
        answer: { [unowned r] chat, member, statuses in r.answers.append(Answer(chat: chat.id, to: member, statuses: statuses)) },
        switched: false, log: { [unowned r] in r.logs.append($0) })
    r.hold(accepted: true)
    let m = MessageMaker(V)
    r.receive(m.msg("alice"))
    checkEqual(r.answeredNames(), [], "a sibling's own accept is never answered with a status (self is never a send target)")
    check(r.logs.contains { $0.contains("no answer to the user's own accept") }, "with a log line")
    r.receive(m.msg("bob"))
    checkEqual(r.answeredNames(), ["bob"], "a member's keyed accept is still answered")
    let answer = span(repo, from: "answer: { [weak self] chat, member, statuses in", to: "log: { print(\"[GroupChat] \\($0)\") })")
    check(before(answer, "self.isGroupSelf(chatId: chat.id, hex: member)", "GroupChatManager.shared.sendStatus("),
          "the app's answer sends nothing to a self address either")
}

/// §6.5: the filtered-invite set is for groups the filter decided not to hold. A co-member's own
/// invite for a group held here (§11.2's squat) leaves the set alone, and an invite the filter
/// admits takes out an id it recorded earlier: that group's later traffic is still held.
func aFilteredInviteForAGroupHeldHereLeavesTheFilteredSetAlone() {
    let valid = DeliveryPolicy.Signature.validated
    check(FilteredInvites.records(sourceAllowlisted: false, closed: false, signature: valid, heldHere: false),
          "an invite to D the filter dropped, for a group not held here: its id is recorded")
    check(!FilteredInvites.records(sourceAllowlisted: false, closed: false, signature: valid, heldHere: true),
          "one for a group held here (pending from an allowlisted inviter): not recorded")
    check(!FilteredInvites.records(sourceAllowlisted: true, closed: false, signature: valid, heldHere: false),
          "an allowlisted inviter's: not recorded")
    check(!FilteredInvites.records(sourceAllowlisted: false, closed: true, signature: valid, heldHere: false),
          "a closed group's: not recorded")
    check(!FilteredInvites.records(sourceAllowlisted: false, closed: false, signature: DeliveryPolicy.Signature.invalid,
                                   heldHere: false),
          "a forged invite's: not recorded")
    // A pending group from C; then M's own invite for it, which the filter drops.
    var ids: [String] = []
    if FilteredInvites.records(sourceAllowlisted: false, closed: false, signature: valid, heldHere: true) {
        ids = FilteredInvites.record(ids, GID)
    }
    let filtered = ids.contains(GID)
    check(HeldArrivals.holdable(isPostSync: false, action: GroupAction.status, held: .pending, closed: false, filtered: filtered,
                                signature: valid, sourceIsSelf: false, keptIfJoined: true),
          "a creator status that comes before the accept G is still held")
    check(HeldArrivals.holdable(isPostSync: true, action: nil, held: .pending, closed: false, filtered: filtered,
                                signature: valid, sourceIsSelf: false, keptIfJoined: true),
          "and so is a post G, which gets no second copy")
    let note = body(repo, "private func noteFilteredInvite(")
    check(note.contains("FilteredInvites.records(sourceAllowlisted: isAllowlisted(destHash: sourceHex), closed: standing.closed,")
            && note.contains("heldHere: standing.chat != nil"),
          "the app records only a group it does not hold")
    check(note.contains("is held here: the filtered-invite set is left alone (§6.5)"), "and logs the one it leaves alone")
    let invite = body(repo, "private func handleGroupInvite(")
    check(before(invite, "print(\"[GroupChat] pending group \\(groupId.prefix(8)) from an invite by",
                 "prefs.filteredInviteIds = FilteredInvites.remove(prefs.filteredInviteIds, groupId)"),
          "an invite the filter admits takes the id out of the set")
}

/// §6.5: when the group is closed here its held blobs are forgotten, with one line giving the
/// count: also when a leave G, or a G's `left`, closes a group this device does not hold. Those
/// blobs can never be replayed (a closed group is never joined again).
func aLeaveSyncForAGroupNotHeldHereForgetsWhatWasHeldForIt() {
    typealias S = DistroGroupSync
    checkEqual(S.step(.post, standing: .notHeld, ownMemberIsD: false, pendingMatches: false), .holdArrival,
               "a post G for a group not held here is held")
    checkEqual(S.step(.leave, standing: .notHeld, ownMemberIsD: false, pendingMatches: false), .tombstone,
               "a leave G for it then records it closed")
    checkEqual(S.leftStep(standing: .notHeld, ownMemberIsD: false), .tombstone, "and so does a G's left")
    if case .nothing = S.step(.create, standing: .closed, ownMemberIsD: false, pendingMatches: false) {} else {
        check(false, "a closed group is never held again, so what was held for it can never be replayed")
    }
    let apply = body(repo, "private func applyGroupSync(")
    check(span(apply, from: "case .tombstone:", to: "case .storeOwnPost:").contains("forgetHeldArrivals(groupId: groupId, why:"),
          "the leave G forgets what was held for the group")
    let left = body(repo, "private func applyLeft(")
    check(span(left, from: "case .tombstone:", to: "case .alreadyClosed:").contains("forgetHeldArrivals(groupId: id, why:"),
          "and so does left")
    check(body(repo, "private func forgetHeldArrivals(").contains("print(\"[GroupChat] \\(rows.count) message(s) held for"),
          "with one line giving the count")
}

/// §9.1: self is decided per group. In a group that lists no distro this device holds or held, a
/// known sibling is a separate member, never "You". Outside groups (a DM, the new-chat and QR
/// checks) the user is the device and the distro held now. In a group whose own address is a
/// former D, that D is "You" (§8.7).
func youIsDecidedPerGroup() {
    let siblings: (String) -> [String] = { $0 == D ? [SIB] : [] }
    let deviceGroup = GroupSelf.addresses(ownMember: nil, device: THIS, listed: [THIS, M, SIB], heldDistro: D, siblings: siblings)
    checkEqual(deviceGroup, [THIS], "a device-listed group that lists no distro: self is the device")
    check(!GroupSelf.shownAsYou(SIB, groupSelf: deviceGroup, device: THIS, heldDistro: D),
          "a sibling listed there is a member, not \"You\"")
    check(GroupSelf.shownAsYou(THIS, groupSelf: deviceGroup, device: THIS, heldDistro: D), "the device is \"You\"")
    let dGroup = GroupSelf.addresses(ownMember: D, device: THIS, listed: [D, M, SIB], heldDistro: D, siblings: siblings)
    check(GroupSelf.shownAsYou(SIB, groupSelf: dGroup, device: THIS, heldDistro: D) && GroupSelf.shownAsYou(D, groupSelf: dGroup, device: THIS, heldDistro: D),
          "in a D-group, D and its known siblings are \"You\"")
    let OLD = String(repeating: "0d", count: 16)
    let former = GroupSelf.addresses(ownMember: OLD, device: THIS, listed: [OLD, M], heldDistro: D, siblings: siblings)
    check(GroupSelf.shownAsYou(OLD, groupSelf: former, device: THIS, heldDistro: D),
          "in a group whose own address is a former D, that D's own lines are \"You\"")
    check(!GroupSelf.shownAsYou(SIB, groupSelf: nil, device: THIS, heldDistro: D),
          "outside a group a sibling is not \"You\": a DM to one's other device is a DM")
    check(GroupSelf.shownAsYou(D, groupSelf: nil, device: THIS, heldDistro: D) && GroupSelf.shownAsYou(THIS, groupSelf: nil, device: THIS, heldDistro: D),
          "the device and the distro held now are")
    check(!GroupSelf.shownAsYou(OLD, groupSelf: nil, device: THIS, heldDistro: D), "a former D is not, outside its groups")
    // The wiring.
    check(!body(repo, "func isOwnAddress(").contains("knownSiblings("), "the DM, QR and new-chat checks do not take the siblings")
    check(body(repo, "func contactDisplayName(for destHash: String)").contains("GroupSelf.shownAsYou(destHash, groupSelf: nil,"),
          "a contact's label outside a group")
    check(body(repo, "private func label(for hash: String").contains("GroupSelf.shownAsYou(hash, groupSelf: groupSelf,"),
          "the shared label takes the group's self")
    let loader = body(repo, "func messages(forChatId chatId: String")
    check(loader.contains("let me = groupSelf(forChatId: chatId)") && loader.contains("label(for: entity.senderHash, in: names, groupSelf: me)"),
          "a group's message and system lines are labelled with that group's self")
    let refresh = body(repo, "func refreshChats(")
    check(refresh.contains("let selves = groupSelves(chatEntities)")
            && refresh.contains("shownText($0.content, id: $0.id, senderHash: $0.senderHash, names: names, groupSelf: selves[entity.id])"),
          "and so is a group's preview in the chat list")
    // The user's own act through a sibling (§9.2) makes no name row for it.
    for (name, f) in [("the direct path", "private func handleIncomingMessage("), ("the NSE import", "func importNSEMessages()"),
                      ("the distro path", "private func handleDistroGroupArrival(")] {
        check(body(repo, f).contains("if !ownAct {\n"), "\(name): no name row for a sibling acting as the user")
    }
}

/// §6.7: nse_groups.json is written whenever the filter or the allowlist changes, not only on a
/// refresh. Settings is a sheet, and the app may be suspended before its next refresh.
func theNSEFileIsWrittenWhenTheFilterOrTheAllowlistChanges() {
    let prefs = source("Retichat/Services/UserPreferences.swift")
    let setter = span(prefs, from: "var filterStrangers: Bool {", to: "\n    }\n")
    check(setter.contains("NotificationCenter.default.post(name: UserPreferences.filterStrangersChanged"),
          "the filter's setter says that it changed")
    check(repo.contains("filterWatch = NotificationCenter.default.publisher(for: UserPreferences.filterStrangersChanged)")
            && span(repo, from: "publisher(for: UserPreferences.filterStrangersChanged)", to: "}").contains("scheduleNSEGroupsWrite()"),
          "the repository writes the file when it does")
    for f in ["private func ensureAllowlistedContact(", "private func addContact(", "func removeContact("] {
        check(body(repo, f).contains("scheduleNSEGroupsWrite()"), "\(f) writes the file")
    }
    let write = body(repo, "private func writeNSEGroupsNow(")
    check(write.contains("let groupsSnapshot = nseGroupsSnapshot()") && write.contains("PendingNotification.writeNSEGroups(groupsSnapshot)"),
          "one writer builds the snapshot")
    check(body(repo, "func refreshChats(").contains("writeNSEGroupsNow()"), "a refresh writes it too")
}

/// §9.2, SPEC §17.14: only a validly signed group message from another device of D is the user's
/// own. One from a known sibling whose signature could not be checked (SOURCE_UNKNOWN) is neither
/// the user's own nor another member's: dropped with a log line, never stored as sent.
func aKnownSiblingsMessageThatIsNotValidatedIsNeverTheUsersOwn() {
    let me: Set<String> = [D, THIS, SIB]
    let unknown = DeliveryPolicy.Signature.sourceUnknown
    checkEqual(GroupFirstRules.check(signature: unknown, sourceHex: SIB, groupSender: nil, selfAddresses: me, distros: [D], siblings: [SIB]),
               .selfSourceUnproven, "SOURCE_UNKNOWN from a known sibling: dropped")
    checkEqual(GroupFirstRules.check(signature: unknown, sourceHex: SIB, groupSender: SIB, selfAddresses: me, distros: [D], siblings: [SIB]),
               .selfSourceUnproven, "naming itself as its sender too")
    checkEqual(GroupFirstRules.check(signature: DeliveryPolicy.Signature.validated, sourceHex: SIB, groupSender: nil, selfAddresses: me,
                                     distros: [D], siblings: [SIB]),
               .pass(ownAct: true), "validated: the user's own")
    checkEqual(GroupFirstRules.check(signature: unknown, sourceHex: SIB, groupSender: nil, selfAddresses: [THIS], distros: [D], siblings: []),
               .pass(ownAct: false), "in a device-listed group the sibling is a member: the group rule decides")
    checkEqual(GroupFirstRules.check(signature: unknown, sourceHex: M, groupSender: nil, selfAddresses: me, distros: [D], siblings: [SIB]),
               .pass(ownAct: false), "a member's SOURCE_UNKNOWN keeps today's rule")
    let admit = body(repo, "private func admitGroupMessage(")
    check(span(admit, from: "case .selfSourceUnproven:", to: "case .pass(").contains("return .droppedFirst"),
          "dropped before the group rule, never held")
}

/// GROUP_MEMBERS (and GROUP_MEMBER_KEYS) are split on the code point ',', as LXMF-rust's
/// invite_members and the web's inviteMembers split them, never on Swift's grapheme clusters: a
/// combining mark after a comma does not take the comma with it.
func theMemberCsvIsSplitOnCodePointsAsTheSharedParserSplitsIt() {
    checkEqual(DeliveryPolicy.members(LxmfFieldsDecoder.groupCsv("\(M),\(D),\u{301}")), [M, D],
               "a combining mark after the last comma: [M, D], as Rust and the web read it")
    checkEqual(DeliveryPolicy.members(LxmfFieldsDecoder.groupCsv("\(M),\u{301}\(D)")), [M],
               "a combining mark after a comma, before an entry: [M], as Rust and the web read it")
    checkEqual(DeliveryPolicy.members(LxmfFieldsDecoder.groupCsv(" \(M)\t,\u{3000}\(D)\u{a0}")), [M, D], "invite space is trimmed")
    var r = reading(gvList("ops").first { $0["name"] as? String == "accept_empty_left" }!["expected"]!)
    r.members = "\(M),\(D),\u{301}"
    if case .success(let f) = DistroGroupSync.form(r, distroHex: D) {
        checkEqual(f.members, [M, D], "the accept G's members")
    } else {
        check(false, "an accept G whose members csv has a combining mark after a comma names D, as the shared layer reads it")
    }
    let key = Data(repeating: 7, count: 64).base64EncodedString()
    checkEqual(LxmfFieldsDecoder.groupMemberKeys("\(M):\(key),\u{301}"), [M: key],
               "a member key followed by a comma and a combining mark is kept")
    checkEqual(LxmfFieldsDecoder.groupMemberKeys("\(M):\(key),\(D.uppercased()):\(key)"), [M: key, D: key],
               "otherwise read as before: each hash lowercased")
    checkEqual(LxmfFieldsDecoder.groupMemberKeys("\(M):\u{301}\(key)"), [:], "a combining mark after the colon spoils the key, as in Rust")
}

// MARK: - The texts the three clients share (decided 2026-10-11)

/// The group view while D is stored but not loaded, the create form's two refusals, and the
/// former-D text: the same words on iOS, Android and the web. A create is refused while the stack
/// is not running (no invite could be signed or sent: the group would be written with nobody
/// invited), then while D may be held but has not loaded; nothing is written, queued or retried.
func theGroupTextsAreTheOnesTheThreeClientsShare() {
    checkEqual(GroupSelf.cannotSignText(.distroNotLoaded(D)),
               "Your distro address hasn't loaded on this device yet. You can post and change your membership once it has.",
               "the group view while D has not loaded")
    checkEqual(GroupSelf.cannotSignText(.formerDistro(D)),
               "This group uses your distro address \(D.prefix(8)), which this device no longer holds. You can read it here, but cannot post or change your membership from this device.",
               "the former-D text stays")
    checkEqual(GroupSelf.createNotReadyText, "Your distro address hasn't loaded on this device yet. Create the group once it has.",
               "create while D has not loaded")
    checkEqual(GroupSelf.createNotRunningText, "Retichat isn't running on this device right now. Create the group once it is.",
               "create while the stack is not running")
    checkEqual(GroupSelf.CreateRefusal.distroNotLoaded.text, GroupSelf.createNotReadyText, "the refusal says its text")
    checkEqual(GroupSelf.CreateRefusal.notRunning.text, GroupSelf.createNotRunningText, "the refusal says its text")
    for (loaded, settled) in [(true, true), (false, true), (false, false)] {
        checkEqual(GroupSelf.createRefusal(stackRunning: false, distroLoaded: loaded, distroSettled: settled), .notRunning,
                   "the stack not running refuses first (D loaded \(loaded), settled \(settled))")
    }
    checkEqual(GroupSelf.createRefusal(stackRunning: true, distroLoaded: false, distroSettled: false), .distroNotLoaded,
               "running, D not read yet: refused")
    checkEqual(GroupSelf.createRefusal(stackRunning: true, distroLoaded: true, distroSettled: true), nil, "D loaded: created as D")
    checkEqual(GroupSelf.createRefusal(stackRunning: true, distroLoaded: false, distroSettled: true), nil,
               "no distro held: created as the device")
    // The wiring: refused before anything is written, and the form says which refusal.
    let create = body(repo, "func createGroupChat(")
    check(create.contains("-> Result<String, GroupSelf.CreateRefusal> {"), "createGroupChat says why it created nothing")
    check(create.contains("let client = heldSends.isOpen ? lxmfClient : nil")
            && create.contains("if let why = GroupSelf.createRefusal(stackRunning: client != nil,"),
          "running means what a send means: the start finished and the stack is held")
    check(before(create, "if let why = GroupSelf.createRefusal(", "ctx.insert(chat)")
            && before(create, "if let why = GroupSelf.createRefusal(", "guard let signer = creationSigner() else {"),
          "the refusal comes before the signer and before anything is written")
    check(!create.contains("if let client = lxmfClient {"), "the invites are never skipped for a stack that is not running")
    check(!body(repo, "private func creationSigner(").contains("identityHandle: 0"), "no signer without an identity")
    for path in ["Retichat/Views/NewChat/NewGroupView.swift", "Retichat/Views/NewChat/NewConversationView.swift"] {
        let view = source(path)
        check(view.contains("case .failure(let why):") && view.contains("errorMessage = why.text"), "\(path): the form says why")
        check(!view.contains("createNotReadyText") && !view.contains("chatId.isEmpty"), "\(path): no single text for both refusals")
    }
}

/// A known sibling device's own accept or leave, in a group that lists that device: "Your other
/// device joined the group" / "Your other device left the group", never "You ...", which reads as
/// if the user had joined or left (decided 2026-10-11, the same on every client).
func aKnownSiblingsOwnAcceptOrLeaveIsYourOtherDevice() {
    let me: Set<String> = [THIS, D, SIB]
    let joined = "\(DisplayNames.subjectToken) joined the group"
    let left = "\(DisplayNames.subjectToken) left the group"
    func subject(_ hex: String, _ id: String, _ groupSelf: Set<String>?) -> String? {
        GroupSelf.memberLineSubject(hex, messageId: id, groupSelf: groupSelf, device: THIS, siblings: [SIB])
    }
    checkEqual(subject(SIB, "acc_\(SIB.prefix(8))_\(GID.prefix(8))", me), "Your other device", "a sibling's accept")
    checkEqual(subject(SIB.uppercased(), "left_\(hash64(1))", me), "Your other device", "a sibling's leave")
    checkEqual(DisplayNames.systemText(joined, messageId: "acc_x", subject: subject(SIB, "acc_x", me)!),
               "Your other device joined the group", "the join line")
    checkEqual(DisplayNames.systemText(left, messageId: "left_x", subject: subject(SIB, "left_x", me)!),
               "Your other device left the group", "the leave line")
    checkEqual(subject(THIS, "acc_x", me), nil, "this device is not another device")
    checkEqual(subject(D, "acc_x", me), nil, "nor is D")
    checkEqual(subject(M, "acc_x", me), nil, "a member is named as before")
    checkEqual(subject(SIB, "acc_x", [THIS]), nil, "a sibling in a group that does not name the distro is a member there")
    checkEqual(subject(SIB, "acc_x", nil), nil, "outside a group")
    checkEqual(subject(SIB, "inv_x", me), nil, "only a join or leave line")
    checkEqual(subject(SIB, hash64(2), me), nil, "never a message's sender")
    // The wiring: both the conversation and the chat list's preview name the line so.
    let loader = body(repo, "func messages(forChatId chatId: String")
    check(loader.contains("let siblings = knownSiblingAddresses()")
            && loader.contains("let subject = GroupSelf.memberLineSubject(entity.senderHash, messageId: entity.id, groupSelf: me,")
            && loader.contains("device: ownHashHex, siblings: siblings) ?? senderName")
            && loader.contains("content: DisplayNames.systemText(entity.content, messageId: entity.id, subject: subject),"),
          "the conversation's line")
    check(body(repo, "private func shownText(").contains("GroupSelf.memberLineSubject(senderHash, messageId: id, groupSelf: groupSelf,"),
          "the chat list's preview")
}

// MARK: - The shared vectors (LXMF-rust b873c00, 400accb; RFed SPEC §17.14 "Repeated keys", "Unhashable keys", "Nesting")

/// The copy is LXMF-rust b873c00's (400accb's is the same file): a message that repeats a key,
/// has a key Python cannot hash or is nested past depth 493 is refused whole, as Python LXMF
/// refuses it (James, 2026-10-11: parity; decided 2026-10-11: one limit), and each `refused`
/// vector names the reference's reason. 16a9902's copy had 11 `refused` vectors (no reason),
/// 22 `key_equality` pairs and no `nesting` set; an older copy lacks all three.
func theGroupSyncVectorsAreLXMFRustB873c00sCopy() {
    checkEqual(gvList("variants").count, 15, "variants")
    checkEqual(gvList("rejects").count, 53, "rejects")
    checkEqual(gvList("group_entries").count, 21, "group_entries")
    checkEqual((GV["invite_members"] as? [[String: Any]])?.count, 2, "invite_members")
    checkEqual(gvList("refused").count, 22, "refused")
    checkEqual(gvList("refused").filter { $0["reason"] as? String == "repeated_key" }.count, 13, "refused for a repeated key")
    checkEqual(gvList("refused").filter { $0["reason"] as? String == "unhashable_key" }.count, 9, "refused for a key Python cannot hash")
    checkEqual(gvList("key_equality").count, 24, "key_equality")
    checkEqual(gvList("key_equality").filter { $0["refused"] as? Bool == true }.count, 15, "key_equality pairs refused")
    checkEqual(gvList("nesting").count, 11, "nesting")
    checkEqual(gvList("nesting").filter { $0["refused"] as? Bool == true && $0["reason"] as? String == "too_deep" }.count, 6,
               "nesting vectors refused, each past the limit")
    checkEqual(GV["nesting_max_depth"] as? Int, 493, "the one nesting limit")
}

/// invite_members: the csv split on the code point ',', never on grapheme clusters.
func theInviteParserListsEachInviteMembersVector() {
    for v in (GV["invite_members"] as? [[String: Any]]) ?? [] {
        checkEqual(DeliveryPolicy.members(LxmfFieldsDecoder.groupCsv(v["csv"] as! String)), v["members"] as! [String],
                   "\(v["name"]!): the members listed")
    }
    // The same csv in an accept G (variants accept_members_combining_mark_after_a_comma).
    let variant = gvList("variants").first { $0["name"] as? String == "accept_members_combining_mark_after_a_comma" }
    let csv = (GV["invite_members"] as? [[String: Any]])?.first { $0["name"] as? String == "combining_mark_after_a_comma" }
    if let variant, let csv, case .success(let f) = DistroGroupSync.form(reading(variant["expected"]!), distroHex: D) {
        checkEqual(f.members, csv["members"] as! [String], "the accept G lists D and its creator")
    } else {
        check(false, "the accept G whose csv has a combining mark after the last comma passes rule 4")
    }
}

/// Every group_entries vector through the direct path's reader (LxmfFieldsDecoder.decode on the
/// fields the router hands over), as LXMF-rust reads it: a GROUP_ID entry of any type in either
/// form is one (`hasGroupId`), the id read by Group.md's rule and kept only when it is 32 hex,
/// lowercased, as the app takes it, with no lowercasing of its own; an ext of an unknown type
/// skipped and the rest of the map read; a bin GROUP_ID no id. The action and the name only of a
/// message the group branch takes (the shared layer reports none without an id). A message whose
/// 0xFB is a distro marker is classified on the distro path by the shared unwrap
/// (tests/DistroGroupsFFITests.swift): here only its 0xFB is compared. No vector repeats a key:
/// those are `refused`, and the router never delivers one (tests/DistroGroupsFFITests.swift).
func theDirectPathReaderReadsEachGroupEntriesVectorAsLXMFRustDoes() {
    let markers: Set<String> = [DistroGroupSync.marker, "rfed.distro.channel", DistroTransfer.customType, DistroSent.customType]
    var compared = 0
    var refusedHere = 0
    for v in gvList("group_entries") {
        let name = v["name"] as! String
        let e = v["expected"] as! [String: Any]
        let f = LxmfFieldsDecoder.decode(unhex(v["fields_hex"] as! String))
        checkEqual(f.customType == DistroGroupSync.marker, e["group_sync"] as! Bool, "\(name): a G by its 0xFB")
        if let type = f.customType, markers.contains(type) { continue }
        checkEqual(f.hasGroupId, e["has_group_id"] as! Bool, "\(name): has a GROUP_ID")
        checkEqual(f.groupId, e["group_id"] as? String, "\(name): GROUP_ID, as the app takes it")
        checkEqual(f.groupIdRefused, (e["has_group_id"] as! Bool) && e["group_id"] is NSNull, "\(name): refused on the direct path")
        if f.groupIdRefused { refusedHere += 1 }
        guard f.groupId != nil else { continue }
        compared += 1
        checkEqual(f.groupAction, e["group_action"] as? String, "\(name): GROUP_ACTION")
        checkEqual(f.groupName, e["group_name"] as? String, "\(name): GROUP_NAME")
    }
    for name in ["group_id_uppercase", "group_id_int", "group_id_nil", "group_id_short", "retichat_field_wins", "ext_beside_group_id",
                 "ext_beside_group_id_in_retichat_field", "group_id_bin_in_both_forms", "group_id_bin_in_0xd1_str_in_0xa0"] {
        check(gvList("group_entries").contains { $0["name"] as? String == name }, "\(name) is in the vectors")
    }
    for name in ["group_id_twice", "retichat_field_twice", "group_action_and_name_twice", "custom_type_twice_marker_last"] {
        check(gvList("refused").contains { $0["name"] as? String == name }
                && !gvList("group_entries").contains { $0["name"] as? String == name }, "\(name) is refused, not read")
    }
    check(compared >= 10, "the entries of every vector the group branch takes are compared (\(compared))")
    check(refusedHere >= 6, "every vector with a GROUP_ID that is not one is refused (\(refusedHere))")
}

/// RFed SPEC §17.14, the direct path: a GROUP_ID is read as on the distro path, a str of 32 hex
/// characters compared and stored lowercased; any other GROUP_ID (another length, not hex, a
/// bin, an int, nil) is refused with a log line, never a direct message or a group; a distro
/// marker means nothing there. Each of the three direct readers (the router's delivery, the NSE's
/// hand-off, the app's import of it) refuses it first, before the transfer, the sent copy, the
/// group branch and the privacy filter's DM path. Until 2026-10-11 a bin or int id went on as a
/// DM, "xyz" made the group "xyz", and an uppercase id was stored as sent, so one group could
/// split by case across clients.
func theDirectPathRefusesAGroupIdThatIsNot32HexAndLowercasesOneThatIs() {
    let upper = "9F8E7D6C5B4A39281706F5E4D3C2B1A0"
    let lower = upper.lowercased()
    /// A fields map {0xA0: value} (0xA0, GROUP_ID's old field), with 0xFB first when given.
    func legacy(_ valueHex: String, marker: String? = nil) -> LxmfFields {
        var bytes: [UInt8] = [marker == nil ? 0x81 : 0x82]
        if let marker {
            bytes += [0xCC, 0xFB, 0xA0 | UInt8(marker.utf8.count)] + Array(marker.utf8)
        }
        bytes += [0xCC, 0xA0] + [UInt8](unhex(valueHex))
        return LxmfFieldsDecoder.decode(Data(bytes))
    }
    /// The same in the Retichat field: {0xD1: {1: value}}.
    func retichat(_ valueHex: String) -> LxmfFields {
        LxmfFieldsDecoder.decode(Data([0x81, 0xCC, 0xD1, 0x81, 0x01] + [UInt8](unhex(valueHex))))
    }
    /// A msgpack str: fixstr below 32 bytes, else str 8.
    func str(_ s: String) -> String {
        let n = s.utf8.count
        return (n < 32 ? String(format: "%02x", 0xA0 | n) : String(format: "d9%02x", n)) + s.utf8.map { String(format: "%02x", $0) }.joined()
    }
    for (what, f) in [("an uppercase id in 0xA0", legacy(str(upper))), ("an uppercase id in 0xD1", retichat(str(upper)))] {
        checkEqual(f.groupId, lower, "\(what): read lowercased")
        check(f.hasGroupId && !f.groupIdRefused, "\(what): a group message")
    }
    let malformed: [(String, LxmfFields)] = [
        ("\"xyz\" in 0xA0", legacy("a378797a")),
        ("\"xyz\" in 0xD1", retichat("a378797a")),
        ("a bin of the id's 16 bytes", legacy("c410" + lower)),
        ("a bin of the id's 32 hex characters", legacy("c420" + lower.utf8.map { String(format: "%02x", $0) }.joined())),
        ("an int", legacy("2a")),
        ("nil", legacy("c0")),
        ("a bool in 0xD1", retichat("c3")),
        ("31 hex characters", legacy(str(String(lower.dropLast())))),
        ("33 hex characters", legacy(str(lower + "0"))),
        ("32 characters, one not hex", legacy(str(String(lower.dropLast()) + "g"))),
        ("32 hex characters with a space before them", legacy(str(" " + String(lower.dropLast())))),
        ("\"xyz\" beside the group sync marker", legacy("a378797a", marker: DistroGroupSync.marker)),
        ("\"xyz\" beside the channel marker", legacy("a378797a", marker: "rfed.distro.channel")),
        ("\"xyz\" beside the transfer marker", legacy("a378797a", marker: DistroTransfer.customType)),
        ("\"xyz\" beside the sent-copy marker", legacy("a378797a", marker: DistroSent.customType)),
    ]
    for (what, f) in malformed {
        check(f.hasGroupId && f.groupId == nil && f.groupIdRefused, "\(what): refused, never a DM or a group")
    }
    check(!LxmfFieldsDecoder.decode(Data([0x80])).groupIdRefused, "no GROUP_ID: not refused (a DM)")

    // The wiring: each direct reader refuses it first, with a log line.
    let direct = body(repo, "private func handleIncomingMessage(")
    check(direct.contains("if fields.groupIdRefused {") && direct.contains("REFUSED") && direct.contains("(never a direct message, never a group)"),
          "the router's delivery refuses it with a log line")
    for later in ["if let key = fields.distroTransferKey {", "if fields.isDistroSentCopy {", "if let groupId = fields.groupId {",
                  "let allowlist = allowlistDecision(destHash: srcHex)", "storeIncomingDirect("] {
        check(before(direct, "if fields.groupIdRefused {", later), "the router's delivery refuses it before \(later)")
    }
    check(span(direct, from: "if fields.groupIdRefused {", to: "}").contains("return"), "and stops there")
    let upToGroup = span(direct, from: "if fields.groupIdRefused {", to: "if let groupId = fields.groupId {")
    check(!upToGroup.isEmpty && !upToGroup.contains("DistroGroupSync.marker") && !upToGroup.contains("rfed.distro.channel")
            && !upToGroup.contains("DistroChannelSync"),
          "a group sync or channel marker means nothing on the direct path: the message is classified by its group id")
    let imported = body(repo, "func importNSEMessages(")
    check(imported.contains("if fields.groupIdRefused {") && imported.contains("REFUSED"), "the app's import of the NSE's file refuses it")
    for later in ["if let key = fields.distroTransferKey {", "if fields.isDistroSentCopy {", "if let groupId = fields.groupId {"] {
        check(before(imported, "if fields.groupIdRefused {", later), "the import refuses it before \(later)")
    }
    check(span(imported, from: "if fields.groupIdRefused {", to: "}").contains("continue"), "and goes on to the next")
    let service = source("NotificationService/NotificationService.swift")
    let handOff = span(service, from: "private func nseHandOffForm(", to: "// MARK: - C callback trampoline")
    check(handOff.contains("if fields.groupIdRefused {") && handOff.contains("refused: its GROUP_ID is not 32 hex characters")
            && before(handOff, "if fields.groupIdRefused {", "if fields.isDistroSentCopy {")
            && before(handOff, "if fields.groupIdRefused {", "guard let key = fields.distroTransferKey"),
          "the NSE neither hands it over nor shows it, and logs it")
    check(span(handOff, from: "if fields.groupIdRefused {", to: "    }").contains("return nil"), "the NSE's hand-off form is nil")
}

/// RFed SPEC §17.14 "Repeated keys": LXMF-rust refuses such a message whole on the direct path
/// (the router, the channel unpack, the group receipt) and the distro path (the unwrap) and logs
/// the one line; its error starts with "refused whole:" (retichat-ffi's
/// `the_swift_refusal_prefix_is_lxmf_rusts` pins the prefix). The app's callers that log their
/// own FFI errors stay silent for it, so a refusal is logged once, and drop it; the NSE's
/// unwrap and channel unpack say nothing of any failure.
func aRefusalIsLoggedOnceByLXMFRustAndTheAppSaysNothingMore() {
    let unwrapText = "refused whole: a map at depth 1 repeats a key (160), as Python LXMF refuses it"
    check(RepeatedKeys.isRefusal(unwrapText), "the unwrap's error is a refusal")
    check(RepeatedKeys.isRefusal("LXMessage::unpack: " + unwrapText), "so is the channel unpack's, after its context")
    check(!RepeatedKeys.isRefusal("msgpack decode: unexpected end") && !RepeatedKeys.isRefusal(nil) && !RepeatedKeys.isRefusal("unknown"),
          "other errors are not")
    let unwrap = body(distroClient, "nonisolated private static func unwrapAndDeliver(")
    let failed = span(unwrap, from: "guard let ptr else {", to: "let json = Data(bytes: ptr, count: Int(outLen))")
    check(failed.contains("if !RepeatedKeys.isRefusal(error) {\n                print(\"[Distro] unwrap rejected blob: \\(error)\")")
            && failed.contains("return") && count(failed, "print(") == 1,
          "the distro unwrap's caller logs every other failure, and drops the blob")
    let channels = source("Retichat/Services/RfedChannelClient.swift")
    let unpackFailed = span(channels, from: "guard let result = bridge.channelLxmUnpack(", to: "guard result.signatureValidated else {")
    check(unpackFailed.contains("if !RepeatedKeys.isRefusal(error) {") && count(unpackFailed, "print(") == 1
            && unpackFailed.contains("return"),
          "the channel's caller logs every other failure, and drops the post")
    let pull = source("NotificationService/NSEDistroPull.swift")
    let toShow = span(pull, from: "private static func unwrapToShow(", to: "guard !json.isEmpty")
    check(toShow.contains("guard let ptr else { return nil }") && !toShow.contains("NSLog"), "the NSE's unwrap shows nothing and says nothing")
    let channelPull = source("NotificationService/NSEChannelPull.swift")
    let channelToShow = span(channelPull, from: "private static func unpackToShow(", to: "let raw = Data(bytes: ptr, count: Int(outLen))")
    check(channelToShow.contains("}) else { return nil }") && !channelToShow.contains("NSLog"), "the NSE's channel unpack shows nothing and says nothing")
}

/// RFed SPEC §17.14 rule 1: a G whose source is not D is ignored with a log line, before rule 2,
/// and before anything of it is learnt or applied: its 0xFD is no sibling and its `left` closes
/// nothing (the library's side: tests/DistroGroupsFFITests.swift).
func aGroupSyncWhoseSourceIsNotDIsIgnoredBeforeAnythingIsLearntOrApplied() {
    var r = DistroGroupSync.Reading()
    r.by = SIB; r.op = "leave"; r.groupId = GID; r.atMs = 1_790_000_000_000; r.left = [GID, OTHER]
    for source in [M, X, SIB, THIS] {
        for validated in [true, false] {
            checkEqual(DistroGroupSync.disposition(sourceHex: source, distroHex: D, signatureValidated: validated, reading: r, deviceHex: THIS),
                       .notFromDistro, "a leave G from \(source.prefix(8)) (validated \(validated)): ignored by rule 1")
        }
    }
    checkEqual(DistroGroupSync.disposition(sourceHex: D.uppercased(), distroHex: D, signatureValidated: true, reading: r, deviceHex: THIS),
               .apply(try! DistroGroupSync.form(r, distroHex: D).get(), sibling: SIB), "from D, whatever the case of its hex: applied")
    checkEqual(DistroGroupSync.disposition(sourceHex: M, distroHex: nil, signatureValidated: true, reading: r, deviceHex: THIS),
               .notFromDistro, "no distro held: ignored")
    let handle = body(repo, "private func handleDistroGroupSync(")
    let rule1 = span(handle, from: "case .notFromDistro:", to: "case .forged:")
    check(rule1.contains("(§11.1 rule 1)") && rule1.contains("return false") && !rule1.contains("learnSibling(")
            && !rule1.contains("applyLeft(") && !rule1.contains("applyGroupSync("),
          "logged, not recorded as seen, nothing learnt or applied")
}

// MARK: - Run

let allTests: [(String, @MainActor () -> Void)] = [
    ("an invite to D is routed to the group branch and never becomes a direct message", anInviteToDIsRoutedToTheGroupBranchAndNeverBecomesADirectMessage),
    ("N invite chunks with one src:ts each reach the group handler", nInviteChunksWithOneSourceAndTimestampEachReachTheGroupHandler),
    ("a GROUP_ID that is not 32 hex is dropped in the group branch, never a DM", aGroupIdThatIsNot32HexIsDroppedInTheGroupBranchNeverADirectMessage),
    ("an invite the filter drops is ignored and its id enters the filtered-invite set", anInviteTheFilterDropsIsIgnoredAndItsIdEntersTheFilteredInviteSet),
    ("in a D-group no send targets D or a known sibling, and the own entry is D only", inADGroupNoSendTargetsDOrAKnownSiblingAndTheOwnEntryIsDOnly),
    ("the accept goes out as D, signed by D, GROUP_SENDER D, with D's own key", theAcceptGoesOutAsDSignedByDWithGroupSenderDAndDsOwnKey),
    ("the signer refuses when D is not loaded or replaced, and the conversation says why", theSignerRefusesWhenDIsNotLoadedOrReplacedAndTheConversationSaysWhy),
    ("Delete from this device sends no leave and owes no group sync", deleteFromThisDeviceSendsNoLeaveAndOwesNoGroupSync),
    ("a D-group post owes one post sync and no sent copy; a failed send owes neither", aDGroupPostOwesOnePostSyncAndNoSentCopyAndAFailedSendOwesNeither),
    ("deleteChat in a D-group sends one leave as D and owes one leave sync", deleteChatInADGroupSendsOneLeaveAsDAndOwesOneLeaveSync),
    ("a post naming a self address from another source is dropped on both paths", aPostNamingASelfAddressFromAnotherSourceIsDroppedOnBothPaths),
    ("a forged post is not stored, held or notified on both paths", aForgedPostIsNotStoredNotHeldAndNotNotifiedOnBothPaths),
    ("the group sync rules", theGroupSyncRules),
    ("a pending invite from M, then an accept sync from C: discarded, held from the sync", aPendingInviteFromMThenAnAcceptSyncFromCDiscardsTheInviteAndHoldsTheGroupFromTheSync),
    ("a create sync lets the members pass the filter, self excluded", aCreateSyncAppliedLetsTheMembersPassTheFilterSelfExcluded),
    ("a leave sync removes the conversation and records the id closed, sending nothing", aLeaveSyncRemovesTheConversationAndRecordsTheIdClosedSendingNothing),
    ("left closes a group a sibling still holds as D", leftClosesAGroupASiblingStillHoldsAsD),
    ("a creator status and a post sync held while pending are applied after the accept sync", aCreatorStatusAndAPostSyncHeldWhilePendingAreAppliedAfterTheAcceptSyncNotDroppedAsRepeats),
    ("strangers cannot evict a held creator status; forged, self or filtered traffic is never held", strangersCannotEvictAHeldCreatorStatusAndForgedSelfOrFilteredTrafficIsNeverHeld),
    ("a creator that is D on two devices: both answer; one that applied the leave answers nothing", aCreatorThatIsDOnTwoDevicesBothAnswerAKeyedAcceptAndOneThatAppliedTheLeaveAnswersNothing),
    ("the NSE shows group traffic only as the app would, and the app does not notify again", theNotificationServiceShowsGroupTrafficOnlyAsTheAppWouldAndTheAppDoesNotNotifyAgain),
    ("siblings are learnt from every accepted 0xFD and kept while a group needs them", siblingsAreLearntFromEveryAcceptedDeviceAddressAndKeptWhileAGroupNeedsThem),
    ("an older sibling's post is stored as the user's own outgoing post", anOlderSiblingsPostIsStoredAsTheUsersOwnOutgoingPost),
    ("the invite handler adds the user only if listed", theInviteHandlerAddsTheUserOnlyIfListed),
    ("relay requests on the distro path and in a D-group are not acted on", relayRequestsOnTheDistroPathAndInADGroupAreNotActedOn),
    ("a member's accept to D carrying a name shows that name in the member list", aMembersAcceptToDCarryingANameShowsThatNameInTheMemberList),
    ("the writer's JSON carries exactly what the op carries", theWriterJSONCarriesExactlyWhatTheOpCarries),
    ("the confirmations in a D-group say \"on all your devices\"", theConfirmationsInADGroupSayOnAllYourDevices),
    ("a sibling's own accept is never answered with a status", aSiblingsOwnAcceptIsNeverAnsweredWithAStatus),
    ("a filtered invite for a group held here leaves the filtered set alone", aFilteredInviteForAGroupHeldHereLeavesTheFilteredSetAlone),
    ("a leave sync for a group not held here forgets what was held for it", aLeaveSyncForAGroupNotHeldHereForgetsWhatWasHeldForIt),
    ("\"You\" is decided per group", youIsDecidedPerGroup),
    ("the NSE file is written when the filter or the allowlist changes", theNSEFileIsWrittenWhenTheFilterOrTheAllowlistChanges),
    ("a known sibling's message that is not validated is never the user's own", aKnownSiblingsMessageThatIsNotValidatedIsNeverTheUsersOwn),
    ("the member csv is split on code points as the shared parser splits it", theMemberCsvIsSplitOnCodePointsAsTheSharedParserSplitsIt),
    ("the group texts are the ones the three clients share", theGroupTextsAreTheOnesTheThreeClientsShare),
    ("a known sibling's own accept or leave is \"Your other device\"", aKnownSiblingsOwnAcceptOrLeaveIsYourOtherDevice),
    ("the group sync vectors are LXMF-rust b873c00's copy", theGroupSyncVectorsAreLXMFRustB873c00sCopy),
    ("the invite parser lists each invite_members vector", theInviteParserListsEachInviteMembersVector),
    ("the direct path's reader reads each group_entries vector as LXMF-rust does", theDirectPathReaderReadsEachGroupEntriesVectorAsLXMFRustDoes),
    ("the direct path refuses a GROUP_ID that is not 32 hex and lowercases one that is", theDirectPathRefusesAGroupIdThatIsNot32HexAndLowercasesOneThatIs),
    ("a refusal is logged once, by LXMF-rust, and the app says nothing more", aRefusalIsLoggedOnceByLXMFRustAndTheAppSaysNothingMore),
    ("a group sync whose source is not D is ignored before anything is learnt or applied", aGroupSyncWhoseSourceIsNotDIsIgnoredBeforeAnythingIsLearntOrApplied),
]

@main
enum DistroGroupsTests {
    @MainActor
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
