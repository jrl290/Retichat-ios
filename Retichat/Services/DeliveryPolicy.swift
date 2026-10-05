//
//  DeliveryPolicy.swift
//  Retichat
//
//  Which inbound LXMF messages the app keeps, and what a kept group message
//  may change: James's group model (LXMF-rust/DISPLAY_NAMES.md §7, "Group
//  trust rule" and "Group model"). Android DeliveryPolicy and
//  GroupMemberStatuses (Retichat-android v0.1.9) and Retichat-js
//  shouldProcessGroupMessage are the same rule. Foundation only (with
//  GroupAction and MemberStatus from LxmfFields.swift), so
//  tests/GroupModelTests.swift runs it for real.
//
//  James, 2026-10-01: "Groups start by invite. If the invite doesn't come
//  from someone on the allowlist, it is ignored. If the invite is accepted,
//  the other group members are considered allowed." and "There are no
//  membership changes for a group. One person starts the group with the
//  membership list. Each person can accept or reject. And each person can
//  leave at any time. Once the group is rejected/left, that person cannot
//  rejoin." The source every rule asks about is the packet's own LXMF
//  source, never GROUP_SENDER.
//
//  For this release (James, 2026-10-05) the filter keeps v0.1.8's
//  behaviour: an invite processed from an allowed inviter allowlists the
//  members it lists whose keys check out, and a member's own accept
//  allowlists it (ChatRepository.handleGroupInvite / applyGroupStatus).
//

import Foundation

nonisolated enum DeliveryPolicy {
    /// Where the user stands in the group a message names.
    enum Held: Equatable {
        /// No such group here.
        case none
        /// Invited, not accepted yet: the group relays for nobody, and its
        /// chat asks nothing of the members.
        case pending
        /// Created or accepted by the user.
        case joined
    }

    /// §5.2's three outcomes of a message's signature check.
    enum Signature {
        static let validated = 0
        /// No key for the source yet.
        static let sourceUnknown = 1
        /// The source's key is held and did not sign it.
        static let invalid = 2

        /// A delivery's check as one of the three. A message that is not
        /// validated and gives no reason, or one we do not know, is invalid:
        /// it never counts as the source's word.
        static func reason(valid: Bool, unverifiedReason: Int?) -> Int {
            if valid { return validated }
            return unverifiedReason == sourceUnknown ? sourceUnknown : invalid
        }
    }

    /// A member hash as it must travel: 32 lowercase hex (surrounding spaces
    /// ignored). Anything else is no hash (nil).
    static func hash(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespaces), t.utf8.count == 32,
              t.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        return t
    }

    /// The members an invite lists (GROUP_MEMBERS): its well-formed hashes,
    /// once each, in the order listed.
    static func members(_ listed: [String]?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in listed ?? [] {
            if let h = hash(raw), seen.insert(h).inserted { out.append(h) }
        }
        return out
    }

    /// The message names a member other than its packet source: it carries
    /// a GROUP_SENDER that is not the source's own hash (one that is no
    /// well-formed hash cannot be).
    static func namesOther(groupSender: String?, source: String) -> Bool {
        guard let groupSender else { return false }
        return hash(groupSender) != source
    }

    /// A current member's status: on the list and not left.
    static func isCurrent(_ status: String?) -> Bool {
        status == MemberStatus.invited || status == MemberStatus.accepted
    }

    /// Whether a group message is processed.
    ///
    /// - An invite: only from a source the privacy filter allows
    ///   (`sourceAllowed`), never for a group the user rejected or left
    ///   (`closed`), never with a signature that fails.
    /// - Anything else only for a group held here.
    /// - A plain message (no action): kept, whoever sent it (`author`
    ///   decides whose it is shown as).
    /// - An accept or a leave: only from a current member of the list
    ///   (`sourceStatus`, the packet source's status there, nil when it is
    ///   not listed) that names nobody else (`namesOther`), never with a
    ///   signature that fails. One from a source whose key is not here yet
    ///   counts, as v0.1.8 counts it (James, 2026-10-05). The risk: anyone
    ///   who knows the group id can forge a listed member's leave, and a
    ///   leave is final; the next release carries the member's key in each
    ///   accept and leave.
    /// - A relay request: only for a group the user joined, from a member
    ///   that accepted it, with a validated signature.
    /// - Any other action: only from a current member of a joined group,
    ///   with a validated signature.
    static func shouldProcess(action: String?, sourceAllowed: Bool, held: Held, sourceStatus: String?,
                              namesOther: Bool, closed: Bool, signature: Int) -> Bool {
        let forged = signature == Signature.invalid
        let proven = signature == Signature.validated
        if action == GroupAction.invite { return sourceAllowed && !closed && !forged }
        if held == .none { return false }
        guard let action else { return true }
        switch action {
        case GroupAction.relayRequest:
            return held == .joined && sourceStatus == MemberStatus.accepted && proven
        case GroupAction.accept, GroupAction.leave:
            return isCurrent(sourceStatus) && !namesOther && !forged
        default:
            return held == .joined && isCurrent(sourceStatus) && proven
        }
    }

    /// Whom a kept group message is shown as from: its GROUP_SENDER only
    /// when a current member of a joined group relays it (`sourceStatus`),
    /// signed by that member, and it names a member on the list
    /// (`senderListed`). Anyone else's is its packet source's own: a
    /// stranger's, a pending group's member's, an allowlisted contact's that
    /// is no member.
    static func author(groupSender: String?, source: String, held: Held, sourceStatus: String?,
                       senderListed: Bool, signature: Int) -> String {
        guard let named = hash(groupSender) else { return source }
        let trusted = held == .joined && isCurrent(sourceStatus) && signature == Signature.validated
        return trusted && senderListed ? named : source
    }
}

/// A group's member list as GroupMemberEntity rows hold it.
nonisolated enum GroupMemberStatuses {
    typealias Row = (hash: String, status: String)

    /// `hex`'s status in a group's list, nil when it is not listed. A member
    /// listed twice counts by its most final status (left, then accepted);
    /// "declined" (a local status of older builds) is left.
    static func statusOf(_ rows: [Row], _ hex: String) -> String? {
        let statuses = rows.filter { $0.hash == hex }.map(\.status)
        guard let first = statuses.first else { return nil }
        if statuses.contains(MemberStatus.left) || statuses.contains(MemberStatus.declined) {
            return MemberStatus.left
        }
        if statuses.contains(MemberStatus.accepted) { return MemberStatus.accepted }
        return first
    }

    /// Where the user stands in a group held here (ChatEntity.groupStatus:
    /// "pending" until the user accepts; nil, from older builds, is joined).
    static func held(groupExists: Bool, groupStatus: String?) -> DeliveryPolicy.Held {
        guard groupExists else { return .none }
        return groupStatus == "pending" ? .pending : .joined
    }

    /// What a member's own accept or leave moves it to from `current`, or
    /// nil when it changes nothing: a hash not on the list never becomes a
    /// member, a member that left (a decline arrives as a leave) stays left,
    /// and an accept from a member already accepted is nothing new.
    static func statusChange(current: String?, action: String?) -> String? {
        let next: String
        switch action {
        case GroupAction.accept: next = MemberStatus.accepted
        case GroupAction.leave: next = MemberStatus.left
        default: return nil
        }
        guard DeliveryPolicy.isCurrent(current) else { return nil }
        return current == next ? nil : next
    }

    /// Who the user's leave goes to, a decline's included: every member on
    /// the list but the user and the members that left. A member still
    /// invited is sent it too: it may have accepted already, or accept
    /// later, and must not go on counting the user as a member.
    static func leaveTargets(_ rows: [Row], selfHash: String) -> [String] {
        var seen = Set<String>()
        return rows.map(\.hash).filter { hash in
            hash != selfHash && seen.insert(hash).inserted && DeliveryPolicy.isCurrent(statusOf(rows, hash))
        }
    }

    /// The members a relay goes to: those that accepted, not the user.
    static func acceptedMembers(_ rows: [Row], selfHash: String) -> [String] {
        var seen = Set<String>()
        return rows.map(\.hash).filter { hash in
            hash != selfHash && seen.insert(hash).inserted && statusOf(rows, hash) == MemberStatus.accepted
        }
    }

    /// Whose links opening a group's conversation opens: nobody in a group
    /// the user has not accepted (§7: a client asks nothing of a pending
    /// group's members before the user accepts), else every listed member
    /// but the user.
    static func conversationPeers(_ rows: [Row], selfHash: String, held: DeliveryPolicy.Held) -> [String] {
        guard held == .joined else { return [] }
        var seen = Set<String>()
        return rows.map(\.hash).filter { $0 != selfHash && seen.insert($0).inserted }
    }
}

/// The groups the user rejected or left, for good (James, 2026-10-01: "Once
/// the group is rejected/left, that person cannot rejoin"): a later invite
/// to one of them is ignored, from anyone, so nothing offers it again. Kept
/// oldest first and bounded, as the web keeps it (Retichat-js
/// GroupStore.close, the last 500) and Android (ClosedGroups).
nonisolated enum ClosedGroups {
    static let limit = 500

    /// `entries` with `groupId` recorded as the newest, the oldest dropped
    /// past `limit`.
    static func record(_ entries: [String], _ groupId: String) -> [String] {
        let id = groupId.lowercased()
        return Array((entries.filter { $0 != id } + [id]).suffix(limit))
    }

    static func contains(_ entries: [String], _ groupId: String) -> Bool {
        entries.contains(groupId.lowercased())
    }
}
