// GroupStatusesMigrationOldStore.swift
//
// Writes a SwiftData store the way the build BEFORE member statuses and keys
// (Retichat-ios 096cfde, the distro-channels tip this branch was made from) did: the
// twelve entities it had, with a group held the way that build held it (no creator
// recorded) and rows of every other kind a user has. tests/GroupStatusesMigrationTests.swift
// then opens that store with the new Models.swift, as an updated app does.
//
// It is compiled with the OLD Models.swift (`git show 096cfde:Retichat/Models/Models.swift`),
// never the current one: see the run command in GroupStatusesMigrationTests.swift. It takes the
// directory the store goes in.

import Foundation
import SwiftData

@main
enum GroupStatusesMigrationOldStore {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: group-statuses-old-store <directory>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        // The model list RetichatApp's ModelContainer had at 096cfde.
        let container = try ModelContainer(
            for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
            GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
            ChannelMessageEntity.self, ChannelSenderEntity.self,
            ChannelNameStateEntity.self, ChannelMembershipEntity.self, DistroOutboxEntity.self,
            configurations: ModelConfiguration(url: url))
        let ctx = container.mainContext

        let alice = String(repeating: "a1", count: 16)
        let bob = String(repeating: "b2", count: 16)
        let creator = String(repeating: "c3", count: 16)
        let me = String(repeating: "de", count: 16)

        ctx.insert(ContactEntity(destHash: alice, announceName: "Alice", lastSeen: 1_700_000_000, isAllowlisted: true, isContact: true))
        ctx.insert(ChatEntity(id: "chat-alice", peerHash: alice, lastMessageTime: 1_700_000_200))
        // A group held the way 096cfde held it: joined ("active"), invited by `creator`, with no creator recorded (the column is new).
        ctx.insert(ChatEntity(id: "group-old", peerHash: creator, lastMessageTime: 1_700_000_300, isGroup: true,
                              groupName: "Old group", groupStatus: "active"))
        // A pending one (an invite not yet answered).
        ctx.insert(ChatEntity(id: "group-pending", peerHash: creator, lastMessageTime: 1_700_000_400, isGroup: true,
                              groupName: "Pending group", groupStatus: "pending"))
        for (hash, status) in [(creator, "accepted"), (alice, "accepted"), (bob, "invited"), (me, "accepted")] {
            ctx.insert(GroupMemberEntity(groupId: "group-old", memberHash: hash, inviteStatus: status))
        }
        for hash in [creator, me] {
            ctx.insert(GroupMemberEntity(groupId: "group-pending", memberHash: hash, inviteStatus: hash == creator ? "accepted" : "invited"))
        }
        for i in 0..<3 {
            ctx.insert(MessageEntity(id: "msg-\(i)", chatId: "group-old", senderHash: i == 1 ? me : alice,
                                     content: "group message \(i) \u{1F600}", timestamp: 1_700_000_000 + Double(i),
                                     isOutgoing: i == 1, deliveryState: 2, signatureValid: true))
        }
        ctx.insert(DistroOutboxEntity(id: "sent:aa", kind: "sent", distro: String(repeating: "d1", count: 16),
                                      distroKey: String(repeating: "7", count: 128), msgHash: "aa", packed: Data(repeating: 1, count: 200),
                                      label: "the sent-copy", toHex: alice, seq: 1))
        ctx.insert(ChannelMembershipEntity(channelHash: String(repeating: "c0", count: 16), op: "join", atMs: 1_767_225_600_000))
        try ctx.save()
        print("wrote the old store: 1 contact, 3 chats (2 groups), 4+2 members, 3 messages, 1 owed message, 1 membership record at \(url.path)")
    }
}
