//
//  GroupChatManager.swift
//  Retichat
//
//  Handles all network-level group chat protocol operations.
//
//  Protocol overview:
//  ─────────────────────────────────────────────────────────────────────────
//  CREATE  Creator generates a random 32-hex groupId, then sends an "invite"
//          message individually to every member.  The full member list is
//          included in every invite so recipients know who is in the group.
//
//  INVITE  Each invited member either ignores the invite (stranger-filter
//          match) or accepts it.  Accepting sends an "accept" to every
//          listed member and adds them all to the local allowlist.
//
//  MESSAGE Each member fans-out their own sent messages to every member whose
//          "accept" they have received.  There is no central owner after
//          group creation.
//
//  RELAY   If a member has a poor connection they can ask another member to
//          relay for them.  The relay request carries a GROUP_RELAY_SEEN list
//          (hashes already delivered) so the relayer skips those targets and
//          avoids re-delivery.  The relayer may itself ask a third member if
//          it too cannot reach the remaining targets.
//
//  LEAVE   A member sends a "leave" to all currently-accepted members and
//          then removes the group locally.
//
//  RFed    Packet format is intentionally compatible with a future RFed
//          one-to-many delivery path.  The group ID doubles as the rfed
//          channel hash; field layout is the same for both paths.
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import Security

final class GroupChatManager {
    static let shared = GroupChatManager()
    private init() {}

    // MARK: - Invite

    /// Send group invites to all members except the creator (self).
    func sendInvites(
        groupId: String,
        groupName: String,
        allMembers: [String],
        from selfHash: String,
        via client: LxmfClient
    ) {
        let membersCSV = allMembers.joined(separator: ",")
        let invitees = allMembers.filter { $0 != selfHash }
        let content = "You've been invited to \"\(groupName)\""

        for target in invitees {
            guard let destData = Data(hexString: target) else { continue }
            let handle = client.createMessage(
                to: destData, content: content, title: "", method: LxmfMethod.direct
            )
            guard handle != 0 else { continue }
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupId,      value: groupId)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupName,    value: groupName)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupMembers, value: membersCSV)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupAction,  value: GroupAction.invite)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupSender,  value: selfHash)
            destroyAfterSend(client: client, handle: handle)
        }
    }

    // MARK: - Accept

    /// Broadcast acceptance to every member in the list (excluding self).
    func sendAccept(
        groupId: String,
        to members: [String],
        from selfHash: String,
        via client: LxmfClient
    ) {
        for target in members where target != selfHash {
            guard let destData = Data(hexString: target) else { continue }
            let handle = client.createMessage(
                to: destData, content: "", title: "", method: LxmfMethod.direct
            )
            guard handle != 0 else { continue }
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupId,     value: groupId)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupAction, value: GroupAction.accept)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupSender, value: selfHash)
            destroyAfterSend(client: client, handle: handle)
        }
    }

    // MARK: - Leave

    /// Notify accepted members that we are leaving the group.
    func sendLeave(
        groupId: String,
        to members: [String],
        from selfHash: String,
        via client: LxmfClient
    ) {
        for target in members where target != selfHash {
            guard let destData = Data(hexString: target) else { continue }
            let handle = client.createMessage(
                to: destData, content: "", title: "", method: LxmfMethod.direct
            )
            guard handle != 0 else { continue }
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupId,     value: groupId)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupAction, value: GroupAction.leave)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupSender, value: selfHash)
            destroyAfterSend(client: client, handle: handle)
        }
    }

    // MARK: - Message fanout

    /// Send a group message to a list of accepted members.
    ///
    /// - Parameters:
    ///   - onHandle: Called once per successfully created send handle so the
    ///     caller can set up delivery-state polling if desired.
    func fanoutMessage(
        groupId: String,
        groupName: String,
        content: String,
        attachments: [(String, Data)],
        to members: [String],
        from selfHash: String,
        via client: LxmfClient,
        onHandle: ((UInt64, String) -> Void)? = nil
    ) {
        for target in members where target != selfHash {
            guard let destData = Data(hexString: target) else { continue }
            let handle = client.createMessage(
                to: destData, content: content, title: "", method: LxmfMethod.direct
            )
            guard handle != 0 else { continue }

            for (filename, data) in attachments {
                _ = LxmfClient.messageAddAttachment(handle, filename: filename, data: data)
            }
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupId,     value: groupId)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupName,   value: groupName)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupSender, value: selfHash)

            if client.sendMessage(handle) {
                onHandle?(handle, target)
            } else {
                LxmfClient.messageDestroy(handle)
            }
        }
    }

    // MARK: - Relay request

    /// Ask a single peer to relay a message to the remaining members.
    ///
    /// - Parameters:
    ///   - alreadySeen: Member hashes that have already received the message;
    ///     the relayer will skip these.
    func sendRelayRequest(
        groupId: String,
        content: String,
        originalSender: String,
        alreadySeen: [String],
        to relayer: String,
        via client: LxmfClient
    ) {
        guard let destData = Data(hexString: relayer) else { return }
        let handle = client.createMessage(
            to: destData, content: content, title: "", method: LxmfMethod.direct
        )
        guard handle != 0 else { return }
        _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupId,       value: groupId)
        _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupAction,   value: GroupAction.relayRequest)
        _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupSender,   value: originalSender)
        _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupRelayFor, value: originalSender)
        let seenCSV = alreadySeen.joined(separator: ",")
        if !seenCSV.isEmpty {
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupRelaySeen, value: seenCSV)
        }
        destroyAfterSend(client: client, handle: handle)
    }

    // MARK: - Handle relay request (incoming)

    /// Relay a group message to all members NOT yet covered by the relay chain.
    ///
    /// Sends a relay-done confirmation back to the requester.
    func performRelay(
        groupId: String,
        groupName: String,
        content: String,
        originalSender: String,
        alreadySeen: [String],
        requester: String,
        allAcceptedMembers: [String],
        selfHash: String,
        via client: LxmfClient
    ) {
        let seenSet = Set(alreadySeen + [requester, selfHash, originalSender])
        let targets = allAcceptedMembers.filter { !seenSet.contains($0) }

        // Forward to uncovered members
        let newSeen = Array(seenSet) + targets
        for target in targets {
            guard let destData = Data(hexString: target) else { continue }
            let handle = client.createMessage(
                to: destData, content: content, title: "", method: LxmfMethod.direct
            )
            guard handle != 0 else { continue }
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupId,      value: groupId)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupName,    value: groupName)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupSender,  value: originalSender)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupRelayFor, value: originalSender)
            _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupRelaySeen,
                                           value: newSeen.joined(separator: ","))
            destroyAfterSend(client: client, handle: handle)
        }

        // Send relay-done back to requester
        if let destData = Data(hexString: requester) {
            let handle = client.createMessage(
                to: destData, content: "", title: "", method: LxmfMethod.direct
            )
            if handle != 0 {
                _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupId,     value: groupId)
                _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupAction, value: GroupAction.relayDone)
                _ = LxmfClient.messageAddField(handle, key: LxmfFieldKey.groupSender, value: selfHash)
                _ = LxmfClient.messageAddFieldBool(handle, key: LxmfFieldKey.groupRelayDone, value: true)
                destroyAfterSend(client: client, handle: handle)
            }
        }

        print("[GroupChat] Relayed msg to \(targets.count) member(s), relay-done → \(requester.prefix(8))")
    }

    // MARK: - Private helpers

    private func destroyAfterSend(client: LxmfClient, handle: UInt64) {
        if client.sendMessage(handle) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                LxmfClient.messageDestroy(handle)
            }
        } else {
            LxmfClient.messageDestroy(handle)
        }
    }
}

