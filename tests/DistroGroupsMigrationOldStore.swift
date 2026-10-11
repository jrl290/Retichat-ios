// DistroGroupsMigrationOldStore.swift
//
// Writes a SwiftData store the way the build BEFORE groups for distro holders (Retichat-ios
// f0599c2, the base of this change) did: the fourteen entities it had, with groups held the way
// that build held them (no own address, no member list recorded), an owed sent copy and channel
// record, a creator's kept copy and an entry held for a key. tests/DistroGroupsMigrationTests.swift
// then opens that store with the new Models.swift, as an updated app does.
//
// It is compiled with the OLD Models.swift (`git show f0599c2:Retichat/Models/Models.swift`), never
// the current one: see the run command in DistroGroupsMigrationTests.swift. It takes the directory
// the store goes in.

import Foundation
import SwiftData

@main
enum DistroGroupsMigrationOldStore {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: distro-groups-old-store <directory>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        // The model list RetichatApp's ModelContainer had at f0599c2.
        let container = try ModelContainer(
            for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
            GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
            ChannelMessageEntity.self, ChannelSenderEntity.self,
            ChannelNameStateEntity.self, ChannelMembershipEntity.self, DistroOutboxEntity.self,
            GroupStatusCopyEntity.self, GroupHeldEntity.self,
            configurations: ModelConfiguration(url: url))
        let ctx = container.mainContext

        let alice = String(repeating: "a1", count: 16)
        let creator = String(repeating: "c3", count: 16)
        let me = String(repeating: "de", count: 16)
        let distro = String(repeating: "d1", count: 16)

        ctx.insert(ContactEntity(destHash: alice, announceName: "Alice", lastSeen: 1_700_000_000, isAllowlisted: true, isContact: true))
        ctx.insert(ChatEntity(id: "chat-alice", peerHash: alice, lastMessageTime: 1_700_000_200))
        // A group the device joined, created by `creator`, and one it made itself.
        ctx.insert(ChatEntity(id: "group-joined", peerHash: creator, lastMessageTime: 1_700_000_300, isGroup: true,
                              groupName: "Joined", groupStatus: "active", creatorHash: creator))
        ctx.insert(ChatEntity(id: "group-mine", peerHash: "", lastMessageTime: 1_700_000_400, isGroup: true,
                              groupName: "Mine", groupStatus: "active", creatorHash: me))
        ctx.insert(ChatEntity(id: "group-pending", peerHash: creator, lastMessageTime: 1_700_000_500, isGroup: true,
                              groupName: "Pending", groupStatus: "pending", creatorHash: creator))
        for (group, hash, status) in [("group-joined", creator, "accepted"), ("group-joined", me, "accepted"),
                                      ("group-joined", alice, "invited"), ("group-mine", me, "accepted"),
                                      ("group-mine", alice, "accepted"), ("group-pending", creator, "accepted"),
                                      ("group-pending", me, "invited")] {
            ctx.insert(GroupMemberEntity(groupId: group, memberHash: hash, inviteStatus: status))
        }
        for i in 0..<3 {
            ctx.insert(MessageEntity(id: "msg-\(i)", chatId: "group-joined", senderHash: i == 1 ? me : alice,
                                     content: "group message \(i) \u{1F600}", timestamp: 1_700_000_000 + Double(i),
                                     isOutgoing: i == 1, deliveryState: 2, signatureValid: true))
        }
        ctx.insert(DistroOutboxEntity(id: "sent:aa", kind: "sent", distro: distro, distroKey: String(repeating: "7", count: 128),
                                      msgHash: "aa", packed: Data(repeating: 1, count: 200), label: "the sent-copy",
                                      toHex: alice, seq: 1))
        ctx.insert(DistroOutboxEntity(id: "channel:cc", kind: "channel", distro: distro, distroKey: String(repeating: "7", count: 128),
                                      msgHash: "cc", packed: Data(repeating: 2, count: 100), label: "the join",
                                      op: "join", name: "public.x", atMs: 1_767_225_600_000, seq: 2))
        ctx.insert(GroupStatusCopyEntity(groupId: "group-mine", memberHash: alice, action: "accept", packed: Data(repeating: 3, count: 300)))
        ctx.insert(GroupHeldEntity(msgHash: "held-1", groupId: "group-joined", srcHash: alice, action: "accept",
                                   packed: Data(repeating: 4, count: 300), seq: 1))
        try ctx.save()
        print("wrote the old store: 1 contact, 4 chats (3 groups), 7 members, 3 messages, 2 owed messages, 1 copy, 1 held entry at \(url.path)")
    }
}
