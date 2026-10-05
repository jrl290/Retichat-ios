// GroupModelTests.swift
//
// James's group model (LXMF-rust/DISPLAY_NAMES.md §7, "Group trust rule"
// and "Group model"; James, 2026-10-01): membership is the creator's
// invite list, fixed; accept, reject and leave are each listed member's
// own, from the packet's own source and never GROUP_SENDER, and reject and
// leave are final; relays only for an accepted member of a joined group; a
// stranger's post shows as its own. A decline is the user's leave (James,
// 2026-10-02), and deleting a group conversation is leaving it (James,
// 2026-10-05). For this release the filter keeps v0.1.8's behaviour: an
// invite from an allowed inviter allowlists its listed members at once, and
// an accept or leave from a member whose key is not here yet still counts.
// Android v0.1.9 (DeliveryPolicy, GroupMemberStatuses, GroupModelTest,
// DeclineIsLeaveTest) is the reference.
//
// Until 2026-10-05 iOS processed every non-invite message for a group held
// here from any source (groupMessagePolicy), took an accept or a leave for
// whichever member GROUP_SENDER named and added it to the list, let a
// member that left accept again, merged a later invite into a held group,
// relayed for anyone and for a pending group, showed any post as the member
// GROUP_SENDER named, never asked the signature, sent nothing on a decline,
// sent a leave to the accepted members only, and kept no record of a group
// declined or left, so a later invite brought it back.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/group-model \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/tests/GroupModelTests.swift && \
//     /private/tmp/claude-501/group-model
//
// DeliveryPolicy, GroupMemberStatuses and ClosedGroups run for real. The
// wiring in ChatRepository and the views needs SwiftData, SwiftUI and the
// FFI, so it is asserted on the source, like DisplayNamesTests.swift.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok    - \(what)")
    } else {
        failures.append(what)
        print("FAIL  - \(what)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

/// The body of the declaration starting at `signature`, up to the next
/// member declaration at the same depth (enough for these files).
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    nonisolated static func ",
                "\n    nonisolated private static func ", "\n    // MARK: -", "\n    /// ", "\n    private struct ",
                "\n    private var "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

typealias Held = DeliveryPolicy.Held
typealias Sig = DeliveryPolicy.Signature

let me = "0123456789abcdef0123456789abcdef"
let inviter = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let member = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
let other = "cccccccccccccccccccccccccccccccc"
let stranger = "dddddddddddddddddddddddddddddddd"

func rule(_ action: String?, held: Held = .joined, sourceStatus: String? = MemberStatus.accepted,
          sourceAllowed: Bool = true, namesOther: Bool = false, closed: Bool = false,
          signature: Int = Sig.validated) -> Bool {
    DeliveryPolicy.shouldProcess(action: action, sourceAllowed: sourceAllowed, held: held,
                                 sourceStatus: sourceStatus, namesOther: namesOther, closed: closed,
                                 signature: signature)
}

// MARK: - The rule (DeliveryPolicy)

func testInvites() {
    check(rule(GroupAction.invite, held: .none, sourceStatus: nil),
          "an invite from a source the privacy filter allows is processed")
    check(!rule(GroupAction.invite, held: .none, sourceStatus: nil, sourceAllowed: false),
          "an invite from a source the filter does not allow is ignored")
    check(!rule(GroupAction.invite, held: .none, sourceStatus: nil, closed: true),
          "an invite for a group the user declined or left is ignored, from anyone")
    check(!rule(GroupAction.invite, held: .none, sourceStatus: nil, signature: Sig.invalid),
          "a forged invite (signature invalid) is ignored")
    check(rule(GroupAction.invite, held: .none, sourceStatus: nil, signature: Sig.sourceUnknown),
          "an invite from a source whose key is not here yet is processed")
}

func testAcceptAndLeave() {
    for action in [GroupAction.accept, GroupAction.leave] {
        for held in [Held.pending, .joined] {
            check(rule(action, held: held, sourceStatus: MemberStatus.invited)
                    && rule(action, held: held, sourceStatus: MemberStatus.accepted),
                  "\(action) in a \(held) group from a current member of the list")
            check(!rule(action, held: held, sourceStatus: nil),
                  "\(action) in a \(held) group from a source not on the list is dropped")
            check(!rule(action, held: held, sourceStatus: MemberStatus.left),
                  "\(action) in a \(held) group from a member that left is dropped (final)")
            check(!rule(action, held: held, namesOther: true),
                  "\(action) in a \(held) group naming someone else (GROUP_SENDER) is dropped")
            check(!rule(action, held: held, signature: Sig.invalid),
                  "a forged \(action) in a \(held) group is dropped")
            check(rule(action, held: held, signature: Sig.sourceUnknown),
                  "\(action) from a member whose key is not here yet still counts (v0.1.8, James 2026-10-05)")
        }
        check(!rule(action, held: .none, sourceStatus: nil), "\(action) for a group not held here is dropped")
    }
    check(!DeliveryPolicy.namesOther(groupSender: nil, source: member)
            && !DeliveryPolicy.namesOther(groupSender: member, source: member)
            && !DeliveryPolicy.namesOther(groupSender: " \(member) ", source: member),
          "no GROUP_SENDER, or the source's own, names nobody else")
    check(DeliveryPolicy.namesOther(groupSender: stranger, source: member)
            && DeliveryPolicy.namesOther(groupSender: member.uppercased(), source: member)
            && DeliveryPolicy.namesOther(groupSender: String(member.prefix(31)), source: member),
          "another hash, or one that is no 32-lowercase-hex hash, names someone else")
}

func testStatusChanges() {
    typealias S = GroupMemberStatuses
    check(S.statusChange(current: MemberStatus.invited, action: GroupAction.accept) == MemberStatus.accepted,
          "an invited member's accept accepts it")
    check(S.statusChange(current: MemberStatus.accepted, action: GroupAction.accept) == nil,
          "an accept from a member already accepted is nothing new")
    check(S.statusChange(current: MemberStatus.invited, action: GroupAction.leave) == MemberStatus.left
            && S.statusChange(current: MemberStatus.accepted, action: GroupAction.leave) == MemberStatus.left,
          "a leave (a decline's included) from an invited or accepted member leaves it")
    check(S.statusChange(current: MemberStatus.left, action: GroupAction.accept) == nil
            && S.statusChange(current: MemberStatus.declined, action: GroupAction.accept) == nil,
          "a member that left stays left: its later accept changes nothing")
    check(S.statusChange(current: nil, action: GroupAction.accept) == nil
            && S.statusChange(current: nil, action: GroupAction.leave) == nil,
          "a hash not on the list never becomes a member")
    check(S.statusChange(current: MemberStatus.invited, action: GroupAction.relayRequest) == nil,
          "no other action changes a status")
}

func testRelaysAndOtherActions() {
    check(rule(GroupAction.relayRequest), "a relay request from an accepted member of a joined group, signed")
    check(!rule(GroupAction.relayRequest, held: .pending), "no relay for a pending group")
    check(!rule(GroupAction.relayRequest, sourceStatus: MemberStatus.invited)
            && !rule(GroupAction.relayRequest, sourceStatus: MemberStatus.left),
          "no relay for a member that has not accepted, or left")
    check(!rule(GroupAction.relayRequest, sourceStatus: nil, sourceAllowed: true),
          "no relay for an allowlisted source that is no member")
    check(!rule(GroupAction.relayRequest, signature: Sig.sourceUnknown),
          "no relay without a validated signature")
    check(rule(GroupAction.relayDone, sourceStatus: MemberStatus.invited)
            && !rule(GroupAction.relayDone, held: .pending)
            && !rule(GroupAction.relayDone, sourceStatus: nil)
            && !rule("something-new", sourceStatus: MemberStatus.accepted, signature: Sig.sourceUnknown),
          "any other action only from a current member of a joined group, signed")
}

func testPlainPostsAndTheirAuthor() {
    check(rule(nil, held: .joined, sourceStatus: nil, sourceAllowed: false)
            && rule(nil, held: .pending, sourceStatus: nil, sourceAllowed: false),
          "a plain post is kept for a group held here, whoever sent it")
    check(!rule(nil, held: .none, sourceStatus: nil), "but not for a group not held here")
    func author(_ src: String, _ held: Held, _ status: String?, listed: Bool = true, sig: Int = Sig.validated) -> String {
        DeliveryPolicy.author(groupSender: member, source: src, held: held, sourceStatus: status,
                              senderListed: listed, signature: sig)
    }
    check(author(inviter, .joined, MemberStatus.accepted) == member,
          "a current member of a joined group relays a listed member's post: shown as that member's")
    check(author(stranger, .joined, nil) == stranger, "a stranger's post is its own, never the member it names")
    check(author(inviter, .pending, MemberStatus.accepted) == inviter, "a pending group's member's post is its own")
    check(author(inviter, .joined, MemberStatus.left) == inviter, "a member that left speaks only for itself")
    check(author(inviter, .joined, MemberStatus.accepted, listed: false) == inviter,
          "a GROUP_SENDER not on the list is never believed")
    check(author(inviter, .joined, MemberStatus.accepted, sig: Sig.sourceUnknown) == inviter,
          "GROUP_SENDER is believed only with a validated signature")
}

func testHashesAndStanding() {
    check(DeliveryPolicy.members(["\(me)", " \(member)", member.uppercased(), "xyz", "", me, member + "0"]) == [me, member],
          "an invite's members are its 32-lowercase-hex hashes, once each")
    check(DeliveryPolicy.members(nil).isEmpty, "no list, no members")
    check(DeliveryPolicy.hash("0123456789ABCDEF0123456789abcdef") == nil && DeliveryPolicy.hash(" \(member) ") == member,
          "a hash is 32 lowercase hex")
    check(Sig.reason(valid: true, unverifiedReason: 2) == Sig.validated
            && Sig.reason(valid: false, unverifiedReason: 1) == Sig.sourceUnknown
            && Sig.reason(valid: false, unverifiedReason: 2) == Sig.invalid
            && Sig.reason(valid: false, unverifiedReason: nil) == Sig.invalid
            && Sig.reason(valid: false, unverifiedReason: 7) == Sig.invalid,
          "the signature's three outcomes; an unknown reason is invalid")
    typealias S = GroupMemberStatuses
    check(S.held(groupExists: false, groupStatus: nil) == .none
            && S.held(groupExists: true, groupStatus: "pending") == .pending
            && S.held(groupExists: true, groupStatus: "active") == .joined
            && S.held(groupExists: true, groupStatus: nil) == .joined,
          "the user's standing: pending until accepted; nil (older builds) is joined")
    let rows: [S.Row] = [(me, MemberStatus.accepted), (member, MemberStatus.accepted), (member, MemberStatus.left),
                         (other, MemberStatus.invited), (inviter, MemberStatus.declined)]
    check(S.statusOf(rows, member) == MemberStatus.left && S.statusOf(rows, inviter) == MemberStatus.left
            && S.statusOf(rows, other) == MemberStatus.invited && S.statusOf(rows, stranger) == nil,
          "a member listed twice counts by its most final status; declined is left")
}

func testLeaveTargetsAndClosedGroups() {
    typealias S = GroupMemberStatuses
    let rows: [S.Row] = [(me, MemberStatus.invited), (inviter, MemberStatus.accepted), (member, MemberStatus.invited),
                         (other, MemberStatus.left), (inviter, MemberStatus.accepted)]
    check(S.leaveTargets(rows, selfHash: me) == [inviter, member],
          "the leave (a decline's included) goes to every listed member that has not left, still-invited too, once")
    check(S.acceptedMembers(rows, selfHash: me) == [inviter], "a relay goes to the accepted members")
    check(S.conversationPeers(rows, selfHash: me, held: .pending).isEmpty
            && S.conversationPeers(rows, selfHash: me, held: .joined) == [inviter, member, other],
          "opening a pending group's chat asks nothing of its members")
    check(ClosedGroups.record([], "G1") == ["g1"] && ClosedGroups.record(["g1", "g2"], "g1") == ["g2", "g1"],
          "a group declined or left is recorded newest last, once")
    let full = (0..<ClosedGroups.limit).map { "g\($0)" }
    let next = ClosedGroups.record(full, "new")
    check(next.count == ClosedGroups.limit && next.first == "g1" && next.last == "new",
          "the record is bounded (500), the oldest dropped")
    check(ClosedGroups.contains(["abc"], "ABC") && !ClosedGroups.contains(["abc"], "abd"), "closed is case-insensitive")
}

// MARK: - Wiring (source)

func testTheReceiveWiring() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(!repo.contains("groupMessagePolicy(") && !repo.contains("shouldProcessGroupMessage("),
          "the old rule (any source, for a held group) is gone")
    let admit = body(repo, "private func admitGroupMessage(")
    check(admit.contains("DeliveryPolicy.shouldProcess(")
            && admit.contains("sourceAllowed: action == GroupAction.invite && isAllowlisted(destHash: sourceHex)")
            && admit.contains("namesOther: DeliveryPolicy.namesOther(groupSender: fields.groupSender, source: sourceHex)")
            && admit.contains("closed: standing.closed"),
          "the rule asks about the packet source, never GROUP_SENDER; only an invite asks the filter")
    check(body(repo, "private func groupStanding(").contains("ClosedGroups.contains(prefs.closedGroupIds, groupId)"),
          "a group declined or left counts as closed")
    let incoming = body(repo, "private func handleIncomingMessage(")
    check(incoming.contains("DeliveryPolicy.Signature.reason(valid: signatureValid,")
            && before(incoming, "guard let standing = admitGroupMessage(", "handleGroupMessage("),
          "the router's path admits a group message by the rule, with its signature, before any write")
    let nse = body(repo, "func importNSEMessages()")
    check(nse.contains("DeliveryPolicy.Signature.reason(valid: msg.signatureValid,")
            && before(nse, "if let standing = admitGroupMessage(", "handleGroupMessage("),
          "so does the NSE import")
    check(!repo.contains("fields.groupSender ?? srcHex"), "GROUP_SENDER is never taken as the source")
    let handle = body(repo, "private func handleGroupMessage(")
    check(handle.contains("applyGroupStatus(action: action ?? \"\", memberHex: srcHex,"),
          "an accept or a leave is the packet source's own")
    check(handle.contains("author: groupAuthor(fields: fields, sourceHex: srcHex,"),
          "a plain post's author is decided by DeliveryPolicy.author")
    check(handle.contains("default:\n") && !handle.contains("default:\n            // Regular group message"),
          "an unknown action is not stored as a post")
    let status = body(repo, "private func applyGroupStatus(")
    check(status.contains("GroupMemberStatuses.statusChange(current: standing.sourceStatus, action: action)")
            && !status.contains("ctx.insert(GroupMemberEntity("),
          "a status moves only for a listed member, never back from left, and nobody is added")
    check(status.contains("if memberHex != ownHashHex { ensureAllowlistedContact(destHash: memberHex) }"),
          "a member's own accept allowlists it, in a pending group too (v0.1.8)")
    let relay = body(repo, "private func handleGroupRelayRequest(")
    check(relay.contains("GroupMemberStatuses.acceptedMembers(standing.members, selfHash: ownHashHex)")
            && relay.contains("let originalSender = groupAuthor("),
          "a relay goes to the accepted members, for the author the rule believes")
}

func testTheInviteWiring() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let invite = body(repo, "private func handleGroupInvite(")
    check(invite.contains("let members = held ? distinct(standing.members.map(\\.hash)) : distinct(listed + [srcHex])")
            && invite.contains("guard let hash = DeliveryPolicy.hash(memberHash), members.contains(hash), hash != ownHashHex,"),
          "an invite brings keys only for members on the held list, or for a new group the list it gives")
    check(invite.contains("ensureAllowlistedContact(destHash: hash)")
            && invite.contains("if members.contains(srcHex), srcHex != ownHashHex {\n            ensureAllowlistedContact(destHash: srcHex)"),
          "an invite from an allowed inviter allowlists its listed members and the inviter at once (v0.1.8, James 2026-10-05)")
    check(before(invite, "member keys only", "ctx.insert(ChatEntity(")
            && !invite.contains("existing.inviteStatus = MemberStatus.accepted"),
          "a held group keeps its list: another invite changes nobody's status")
    check(invite.contains("inviteStatus: memberHash == srcHex ? MemberStatus.accepted")
            && invite.contains("distinct(listed + [srcHex, ownHashHex])")
            && invite.contains("groupStatus: \"pending\""),
          "a new group is pending, its inviter accepted and everyone else invited")
    check(invite.contains("names another chat: ignored"), "an invite never replaces a DM chat with the same id")
    let accept = body(repo, "func acceptGroupInvite(")
    check(before(accept, "guard missingKeys.isEmpty else", "chat.groupStatus = \"active\""),
          "a deferred accept leaves the group pending (it was made active before the keys check)")
}

func testDeclineLeaveAndDelete() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(body(repo, "func declineGroupInvite(").contains("quitGroup(chatId: groupId, how: \"declined\")"),
          "a decline is the user's leave (quitGroup)")
    check(body(repo, "func leaveGroup(").contains("quitGroup(chatId: chatId, how: \"left\")"),
          "a leave takes the same path")
    let delete = body(repo, "func deleteChat(")
    check(delete.contains("chat.isGroup {\n            quitGroup(chatId: chatId, how: \"deleted\")")
            && delete.contains("deleteChatLocal(chatId: chatId)"),
          "deleting a group conversation is leaving it; a DM's is deleted here")
    let quit = body(repo, "private func quitGroup(")
    check(quit.contains("GroupMemberStatuses.leaveTargets(rows, selfHash: ownHashHex)")
            && quit.contains("GroupChatManager.shared.sendLeave(groupId: chatId, to: targets, from: selfHash, via: client)"),
          "the leave goes to every listed member that has not left")
    check(before(quit, "prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, chatId)", "deleteChatLocal(chatId: chatId)")
            && before(quit, "GroupChatManager.shared.sendLeave(", "deleteChatLocal(chatId: chatId)"),
          "the group is recorded as closed and the leave sent before the chat goes")
    let manager = source("Retichat/Services/GroupChatManager.swift")
    let leave = body(manager, "func sendLeave(")
    check(leave.contains("createMessage(\n                to: destData, content: \"\", title: \"\", method: LxmfMethod.direct")
            && leave.contains(".action, .str(GroupAction.leave)")
            && leave.contains(".sender, .str(selfHash)")
            && leave.contains(".id, .str(groupId)"),
          "the leave is GROUP_ID, GROUP_ACTION leave and GROUP_SENDER the user, no content (as Android and the web)")
    check(!(body(repo, "func leaveGroup(") + quit).contains("MemberStatus.accepted"),
          "the leave no longer goes to the accepted members only")
}

func testTheDialogs() {
    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    check(view.contains("Button(\"Decline Invite\", role: .destructive) {\n                            showDeclineConfirm = true")
            && view.contains("Button {\n                    showDeclineConfirm = true\n                } label: {\n                    Text(\"Decline\")"),
          "the conversation's Decline asks first")
    check(view.contains(".confirmationDialog(GroupInviteText.declineTitle, isPresented: $showDeclineConfirm,")
            && view.contains("repository.declineGroupInvite(groupId: chatId)"),
          "and declines on confirmation")
    check(view.contains("static let declineMessage = \"The group's members are told you declined, and you won't be able to join this group later.\""),
          "the decline dialog says the members are told and it is final")
    check(view.contains("The members are told you left, and this conversation is deleted. You won't receive future messages, and you won't be able to rejoin this group."),
          "the leave dialog says so")
    check(view.contains("isGroup ? \"Delete and leave this group?\" : \"Delete this conversation?\"")
            && view.contains("Deleting a group conversation leaves the group: the members are told you left, and you won't be able to rejoin it."),
          "a group's delete dialog says it leaves the group")
    let list = source("Retichat/Views/ChatList/ChatListView.swift")
    check(list.contains("Button(role: .destructive) {\n                                                declining = chat")
            && list.contains(".confirmationDialog(GroupInviteText.declineTitle,")
            && list.contains("Text(GroupInviteText.declineMessage)"),
          "the chat list's Decline asks first, with the same words")
}

func testPendingGroupOpensNoLinks() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let open = body(repo, "func openConversation(chatId: String)")
    check(open.contains("GroupMemberStatuses.conversationPeers(rows, selfHash: ownHashHex, held: held)")
            && open.contains("openedGroupPeers[chatId] = peers"),
          "opening a group's chat opens links only once the user accepted it")
    check(body(repo, "func closeConversation(chatId: String)").contains("openedGroupPeers.removeValue(forKey: chatId)"),
          "and its close closes exactly what the open opened")
}

@main
struct GroupModelTestsMain {
    static func main() {
        testInvites()
        testAcceptAndLeave()
        testStatusChanges()
        testRelaysAndOtherActions()
        testPlainPostsAndTheirAuthor()
        testHashesAndStanding()
        testLeaveTargetsAndClosedGroups()
        testTheReceiveWiring()
        testTheInviteWiring()
        testDeclineLeaveAndDelete()
        testTheDialogs()
        testPendingGroupOpensNoLinks()
        if failures.isEmpty {
            print("all group model tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
