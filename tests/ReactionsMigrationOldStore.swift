// ReactionsMigrationOldStore.swift
//
// Writes a SwiftData store the way the build BEFORE message reactions (Retichat-ios a328913, the
// base of this change) did: a direct chat with a message received and one sent, filed under their
// LXMF hashes, and a group with a post. tests/ReactionsMigrationTests.swift then opens that store
// with the new Models.swift, as an updated app does.
//
// It is compiled with the OLD Models.swift (`git show a328913:Retichat/Models/Models.swift`), never
// the current one: see the run command in ReactionsMigrationTests.swift. It takes the directory the
// store goes in.

import Foundation
import SwiftData

@main
enum ReactionsMigrationOldStore {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: reactions-old-store <directory>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        // The model list RetichatApp's ModelContainer had at a328913.
        let container = try ModelContainer(
            for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
            GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
            ChannelMessageEntity.self, ChannelSenderEntity.self,
            ChannelNameStateEntity.self, ChannelMembershipEntity.self, DistroOutboxEntity.self,
            GroupStatusCopyEntity.self, GroupHeldEntity.self, GroupHeldArrivalEntity.self,
            configurations: ModelConfiguration(url: url))
        let ctx = container.mainContext

        let alice = String(repeating: "a1", count: 16)
        let me = String(repeating: "de", count: 16)
        ctx.insert(ChatEntity(id: alice, peerHash: alice, lastMessageTime: 1_700_000_200))
        ctx.insert(MessageEntity(id: String(repeating: "1a", count: 32), chatId: alice, senderHash: alice,
                                 content: "from Alice \u{1F600}", timestamp: 1_700_000_100, deliveryState: 2, signatureValid: true))
        ctx.insert(MessageEntity(id: String(repeating: "2b", count: 32), chatId: alice, senderHash: me,
                                 content: "to Alice", timestamp: 1_700_000_200, isOutgoing: true, deliveryState: 2))
        ctx.insert(ChatEntity(id: "group-1", peerHash: alice, lastMessageTime: 1_700_000_300, isGroup: true,
                              groupName: "Group", groupStatus: "active", creatorHash: alice))
        ctx.insert(MessageEntity(id: String(repeating: "3c", count: 32), chatId: "group-1", senderHash: alice,
                                 content: "a post", timestamp: 1_700_000_300, deliveryState: 2, signatureValid: true))
        try ctx.save()
        print("wrote the old store: 2 chats, 3 messages at \(url.path)")
    }
}
