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
// (rust/retichat-ffi/tests/data/distro_group_sync_vectors.json, LXMF-rust 1a1ed8b); the engine's
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
    check(note.contains("guard !isAllowlisted(destHash: sourceHex), !standing.closed,")
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
            && !local.contains("oweGroupSync(") && !local.contains("closedGroupIds"),
          "removed here only: no leave, no G, not recorded closed")
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
    check(body(repo, "func isOwnAddress(").contains("knownSiblings(of:"), "a sibling is one of the user's own addresses")
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
    check(body(repo, "func groupMemberDisplayName(").contains("if isGroupSelf(chatId: groupId, hex: hash) { return \"You\" }\n        return contactDisplayName(for: hash)"),
          "resolved as any contact's name")
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
