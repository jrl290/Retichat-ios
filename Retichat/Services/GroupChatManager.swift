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

/// Who a group send goes out as (GROUPS-DISTRO-DESIGN.md §8.1-§8.2): the group's own address,
/// resolved at send time by ChatRepository.groupSigner, never captured once. `hex` is the LXMF
/// source and GROUP_SENDER, `identityHandle` signs, `publicKey` is the key an accept or leave
/// carries. In a D-group it is D (the distro this device holds now, equal to the group's own
/// address); otherwise the device.
struct GroupSigner: Sendable {
    let hex: String
    let hash: Data
    let identityHandle: UInt64
    let publicKey: Data?
    /// The signer is the user's distro, not the device: its acts are owed a group sync (§10.6).
    let isDistro: Bool
}

final class GroupChatManager {
    static let shared = GroupChatManager()
    private init() {}

    private let stateLock = NSLock()
    private var trackedHandles: [String: UInt64] = [:]
    private var fallbackStarted: Set<UInt64> = []
    var onTracked: ((String) -> Void)?

    // MARK: - Who sends

    /// One envelope from the group's own address `signer` to `dest`, signed by its identity
    /// (GROUPS-DISTRO-DESIGN.md §8.2): `retichat_message_create`, never `lxmf_message_new`, which
    /// always signs as the device. DIRECT, with the propagated fallback (handleMessageState); a
    /// member that is a distro is propagated at once by the router (§8.4).
    private func create(to dest: Data, content: String, as signer: GroupSigner) -> UInt64 {
        RetichatBridge.shared.messageCreate(destHash: dest, sourceHash: signer.hash, content: content, title: "",
                                            method: LxmfMethod.direct, identityHandle: signer.identityHandle)
    }

    // MARK: - Invite

    /// Send group invites to `targets` (every listed member that is not the user), as the
    /// group's own address `signer`, the creator: one chunk per member key, each listing every
    /// member. Returns the GROUP_MEMBER_KEYS entries the chunks carry (what a `create` group sync
    /// carries, §10.2), or nil when a member's key is missing and nothing was sent.
    @discardableResult
    func sendInvites(
        groupId: String,
        groupName: String,
        allMembers: [String],
        memberPublicKeys: [String: String],
        targets: [String],
        as signer: GroupSigner,
        via client: LxmfClient
    ) -> [String]? {
        let membersCSV = allMembers.joined(separator: ",")
        guard allMembers.allSatisfy({ memberPublicKeys[$0]?.count == 128 }) else {
            print("[GroupChat] invite aborted: missing member public key")
            return nil
        }
        let memberKeyEntries = allMembers.sorted().compactMap { hash -> String? in
            guard let keyData = Data(hexString: memberPublicKeys[hash]!) else { return nil }
            return "\(hash):\(keyData.base64EncodedString())"
        }
        guard memberKeyEntries.count == allMembers.count else { return nil }
        let content = ""

        for target in targets where target != signer.hex {
            guard let destData = Data(hexString: target) else { continue }
            for memberKeyEntry in memberKeyEntries {
                let handle = create(to: destData, content: content, as: signer)
                guard handle != 0 else { continue }
                _ = LxmfClient.messageSetGroupEntry(handle, .id, .str(groupId))
                _ = LxmfClient.messageSetGroupEntry(handle, .name, .str(groupName))
                _ = LxmfClient.messageSetGroupEntry(handle, .members, .str(membersCSV))
                _ = LxmfClient.messageSetGroupEntry(handle, .memberKeys, .str(memberKeyEntry))
                _ = LxmfClient.messageSetGroupEntry(handle, .action, .str(GroupAction.invite))
                _ = LxmfClient.messageSetGroupEntry(handle, .sender, .str(signer.hex))
                destroyAfterSend(client: client, handle: handle)
            }
        }
        return memberKeyEntries
    }

    // MARK: - Accept

    /// Broadcast acceptance to `members` (the caller left out every self address), as the
    /// group's own address. Every accept carries the signer's own key (GroupEnvelopes, RFed-spec
    /// Group.md "The sender's key", James 2026-10-06), so a member that never heard of it can
    /// verify it, and the creator answers it with a `status`. In a D-group that is D's key,
    /// whichever device of D sends it (GROUPS-DISTRO-DESIGN.md §8.2).
    func sendAccept(
        groupId: String,
        to members: [String],
        as signer: GroupSigner,
        via client: LxmfClient
    ) {
        let ownKey = ownKeyEntry(signer)
        for target in members where target != signer.hex {
            guard let destData = Data(hexString: target) else { continue }
            let handle = create(to: destData, content: "", as: signer)
            guard handle != 0 else { continue }
            write(GroupEnvelopes.accept(groupId: groupId, selfHex: signer.hex, ownKey: ownKey), on: handle)
            destroyAfterSend(client: client, handle: handle)
        }
    }

    /// The signer's own GROUP_MEMBER_KEYS entry, `hash:base64-public-key`: the form an invite
    /// chunk uses. Read from the identity, not the router, so a leave sent with no connection
    /// carries it too. Nil, and logged, when the key cannot be read: the accept or leave then goes
    /// without it, as a build from before this change sent it, rather than not at all.
    private func ownKeyEntry(_ signer: GroupSigner) -> String? {
        guard let publicKey = signer.publicKey, publicKey.count == 64 else {
            print("[GroupChat] own key not readable, the accept/leave carries none: \(LxmfClient.lastError ?? "unknown")")
            return nil
        }
        return GroupEnvelopes.ownKeyEntry(selfHex: signer.hex, publicKey: publicKey)
    }

    /// Write the envelope's entries on the native message `handle`, in the form the switch picks.
    private func write(_ entries: [GroupEnvelopes.Entry], on handle: UInt64) {
        for entry in entries {
            _ = LxmfClient.messageSetGroupEntry(handle, entry.entry, .str(entry.value))
        }
    }

    // MARK: - Status (the creator's answer to an accept)

    /// The creator's answer to an accept that counted and carried its sender's key (RFed-spec
    /// Group.md, "The creator's answer: status"): one `status` to `memberHex` alone, `statuses`
    /// being every OTHER listed member's newest counted accept or leave exactly as this device
    /// received it, by member hash ascending (the caller chose them; an empty list is a valid
    /// answer). It goes like every group control message: DIRECT, with the propagated fallback,
    /// and as a Resource when too large for a packet. Once per accept received: nothing here
    /// sends it again (DESIGN_PRINCIPLES §3). A status that cannot be built is not sent. Sent as
    /// the group's own address: a creator that is D answers as D (GROUPS-DISTRO-DESIGN.md §12.1).
    func sendStatus(
        groupId: String,
        to memberHex: String,
        statuses: [Data],
        as signer: GroupSigner,
        via client: LxmfClient
    ) {
        guard let destData = Data(hexString: memberHex) else { return }
        let handle = create(to: destData, content: "", as: signer)
        guard handle != 0 else { return }
        write(GroupEnvelopes.status(groupId: groupId, selfHex: signer.hex), on: handle)
        guard RetichatBridge.shared.messageSetRetichatStatuses(handle: handle, elements: statuses) else {
            print("[GroupChat] the status for \(memberHex.prefix(8)) could not be built, not sent: \(LxmfClient.lastError ?? "unknown")")
            LxmfClient.messageDestroy(handle)
            return
        }
        destroyAfterSend(client: client, handle: handle)
    }

    // MARK: - Leave

    /// Tell `members` (the caller left out every self address) that the user leaves the group,
    /// as the group's own address. Like an accept it carries the signer's own key
    /// (GroupEnvelopes), so a member that never heard of it can verify it before it makes the
    /// leave final.
    func sendLeave(
        groupId: String,
        to members: [String],
        as signer: GroupSigner,
        via client: LxmfClient
    ) {
        let ownKey = ownKeyEntry(signer)
        for target in members where target != signer.hex {
            guard let destData = Data(hexString: target) else { continue }
            let handle = create(to: destData, content: "", as: signer)
            guard handle != 0 else { continue }
            write(GroupEnvelopes.leave(groupId: groupId, selfHex: signer.hex, ownKey: ownKey), on: handle)
            destroyAfterSend(client: client, handle: handle)
        }
    }

    // MARK: - Message fanout

    /// Send a group message to a list of accepted members (the caller left out every self
    /// address), as the group's own address. Returns how many envelopes the router or its
    /// outbox accepted: a `post` group sync is owed only once one was (§10.6).
    ///
    /// REACTIONS-DESIGN.md §4: a post carries its `postId` (GROUP_POST_ID, key 11) on every
    /// member copy; a reaction goes the same way, with `reaction` (0x40: the 16 bytes of the post
    /// id it names, and the reaction) and no text. An envelope whose post id or reaction cannot
    /// be set is not sent: it would reach the member as another message.
    ///
    /// - Parameters:
    ///   - onHandle: Called once per successfully created send handle so the
    ///     caller can set up delivery-state polling if desired.
    @discardableResult
    func fanoutMessage(
        groupId: String,
        groupName: String,
        content: String,
        attachments: [(String, Data)],
        to members: [String],
        as signer: GroupSigner,
        via client: LxmfClient,
        postId: String? = nil,
        reaction: (to: Data, content: String)? = nil,
        onHandle: ((UInt64, String) -> Void)? = nil
    ) -> Int {
        var submitted = 0
        for target in members where target != signer.hex {
            guard let destData = Data(hexString: target) else { continue }
            let handle = create(to: destData, content: content, as: signer)
            guard handle != 0 else { continue }

            LxmfClient.messageAddAttachments(handle, attachments)
            _ = LxmfClient.messageSetGroupEntry(handle, .id, .str(groupId))
            _ = LxmfClient.messageSetGroupEntry(handle, .name, .str(groupName))
            _ = LxmfClient.messageSetGroupEntry(handle, .sender, .str(signer.hex))
            guard setPostIdAndReaction(handle, postId: postId, reaction: reaction, for: target) else {
                LxmfClient.messageDestroy(handle)
                continue
            }

            if client.sendMessageViaAppLinks(handle) {
                submitted += 1
                track(handle: handle)
                onHandle?(handle, target)
            } else {
                LxmfClient.messageDestroy(handle)
            }
        }
        return submitted
    }

    // MARK: - Relay request

    /// Ask a single peer to relay a message to the remaining members.
    ///
    /// - Parameters:
    ///   - alreadySeen: Member hashes that have already received the message;
    ///     the relayer will skip these.
    ///   - postId, reaction: what is relayed carries them (REACTIONS-DESIGN.md §4): the post's
    ///     GROUP_POST_ID, or the reaction's 0x40.
    func sendRelayRequest(
        groupId: String,
        content: String,
        originalSender: String,
        alreadySeen: [String],
        to relayer: String,
        postId: String? = nil,
        reaction: (to: Data, content: String)? = nil,
        via client: LxmfClient
    ) {
        guard let destData = Data(hexString: relayer) else { return }
        let handle = client.createMessage(
            to: destData, content: content, title: "", method: LxmfMethod.direct
        )
        guard handle != 0 else { return }
        _ = LxmfClient.messageSetGroupEntry(handle, .id, .str(groupId))
        _ = LxmfClient.messageSetGroupEntry(handle, .action, .str(GroupAction.relayRequest))
        _ = LxmfClient.messageSetGroupEntry(handle, .sender, .str(originalSender))
        _ = LxmfClient.messageSetGroupEntry(handle, .relayFor, .str(originalSender))
        let seenCSV = alreadySeen.joined(separator: ",")
        if !seenCSV.isEmpty {
            _ = LxmfClient.messageSetGroupEntry(handle, .relaySeen, .str(seenCSV))
        }
        guard setPostIdAndReaction(handle, postId: postId, reaction: reaction, for: relayer) else {
            LxmfClient.messageDestroy(handle)
            return
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
        postId: String? = nil,
        reaction: (to: Data, content: String)? = nil,
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
            _ = LxmfClient.messageSetGroupEntry(handle, .id, .str(groupId))
            _ = LxmfClient.messageSetGroupEntry(handle, .name, .str(groupName))
            _ = LxmfClient.messageSetGroupEntry(handle, .sender, .str(originalSender))
            _ = LxmfClient.messageSetGroupEntry(handle, .relayFor, .str(originalSender))
            _ = LxmfClient.messageSetGroupEntry(handle, .relaySeen, .str(newSeen.joined(separator: ",")))
            // REACTIONS-DESIGN.md §4: the relayer copies the post id and the reaction onto each
            // relayed copy.
            guard setPostIdAndReaction(handle, postId: postId, reaction: reaction, for: target) else {
                LxmfClient.messageDestroy(handle)
                continue
            }
            destroyAfterSend(client: client, handle: handle)
        }

        // Send relay-done back to requester
        if let destData = Data(hexString: requester) {
            let handle = client.createMessage(
                to: destData, content: "", title: "", method: LxmfMethod.direct
            )
            if handle != 0 {
                _ = LxmfClient.messageSetGroupEntry(handle, .id, .str(groupId))
                _ = LxmfClient.messageSetGroupEntry(handle, .action, .str(GroupAction.relayDone))
                _ = LxmfClient.messageSetGroupEntry(handle, .sender, .str(selfHash))
                _ = LxmfClient.messageSetGroupEntry(handle, .relayDone, .bool(true))
                destroyAfterSend(client: client, handle: handle)
            }
        }

        print("[GroupChat] Relayed msg to \(targets.count) member(s), relay-done → \(requester.prefix(8))")
    }

    // MARK: - Private helpers

    /// GROUP_POST_ID (key 11) and the reaction (0x40) on a group envelope, each when given
    /// (REACTIONS-DESIGN.md §4). False, logged, when the library refuses either.
    private func setPostIdAndReaction(_ handle: UInt64, postId: String?,
                                      reaction: (to: Data, content: String)?, for target: String) -> Bool {
        if let postId, !LxmfClient.messageSetGroupPostId(handle, postId) {
            print("[GroupChat] the post id for \(target.prefix(8)) could not be set, not sent: \(LxmfClient.lastError ?? "unknown")")
            return false
        }
        if let reaction, !LxmfClient.messageSetReaction(handle, to: reaction.to, content: reaction.content) {
            print("[GroupChat] the reaction for \(target.prefix(8)) could not be set, not sent: \(LxmfClient.lastError ?? "unknown")")
            return false
        }
        return true
    }

    private func destroyAfterSend(client: LxmfClient, handle: UInt64) {
        if client.sendMessageViaAppLinks(handle) {
            track(handle: handle)
        } else {
            LxmfClient.messageDestroy(handle)
        }
    }

    private func track(handle: UInt64) {
        guard let hash = LxmfClient.messageHash(handle), !hash.isEmpty else {
            LxmfClient.messageDestroy(handle)
            return
        }
        let hashHex = hash.hexString
        stateLock.lock()
        trackedHandles[hashHex] = handle
        stateLock.unlock()
        onTracked?(hashHex)
    }

    /// Consume message-state callbacks for group fanout/control handles.
    /// Returns true when the hash belongs to GroupChatManager.
    func handleMessageState(hashHex: String, state: UInt8, client: LxmfClient) -> Bool {
        stateLock.lock()
        guard let handle = trackedHandles[hashHex] else {
            stateLock.unlock()
            return false
        }

        // The copy starts on 0x10 or on the DIRECT send's own failure, once (GroupEnvelopeReport).
        let startCopy = GroupEnvelopeReport.startsCopy(state) && fallbackStarted.insert(handle).inserted
        let ended = GroupEnvelopeReport.ends(state)
        if ended {
            trackedHandles.removeValue(forKey: hashHex)
            fallbackStarted.remove(handle)
        }
        stateLock.unlock()

        // The copy is cloned from the DIRECT handle, so the handle goes after it.
        if startCopy {
            startPropagationFallback(from: handle, client: client)
        }
        if ended {
            LxmfClient.messageDestroy(handle)
        }
        return true
    }

    private func startPropagationFallback(from directHandle: UInt64, client: LxmfClient) {
        let propagated = LxmfClient.messageClonePropagated(directHandle)
        guard propagated != 0 else {
            print("[GroupChat] propagated clone failed: \(LxmfClient.lastError ?? "unknown")")
            return
        }
        guard client.sendMessageViaAppLinks(propagated) else {
            print("[GroupChat] propagated send failed: \(LxmfClient.lastError ?? "unknown")")
            LxmfClient.messageDestroy(propagated)
            return
        }
        // The router retains the message Arc; release the registry handle so it
        // cannot replace the direct handle under their shared canonical hash.
        LxmfClient.messageDestroy(propagated)
        print("[GroupChat] propagation fallback dispatched")
    }
}

