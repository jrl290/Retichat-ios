// DistroChannelsMigrationOldStore.swift
//
// Writes a SwiftData store the way the build BEFORE channels and the distro
// (Retichat-ios 05df78e, the commit this branch was made from) did: its nine
// entities, with rows of every kind a user has. tests/DistroChannelsMigrationTests.swift
// then opens that store with the new Models.swift, as an updated app does.
//
// It is compiled with the OLD Models.swift (`git show 05df78e:Retichat/Models/
// Models.swift`), never the current one: see the run command in
// DistroChannelsMigrationTests.swift. It takes the directory the store goes in.

import Foundation
import SwiftData

@main
enum DistroChannelsMigrationOldStore {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: migration-old-store <directory>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        // The model list RetichatApp's ModelContainer had before this branch.
        let container = try ModelContainer(
            for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
            GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
            ChannelMessageEntity.self, ChannelSenderEntity.self,
            configurations: ModelConfiguration(url: url))
        let ctx = container.mainContext

        let alice = String(repeating: "a1", count: 16)
        let general = String(repeating: "c0", count: 16)
        let ops = String(repeating: "c1", count: 16)

        let contact = ContactEntity(destHash: alice, announceName: "Alice", lastSeen: 1_700_000_000,
                                    isAllowlisted: true, isContact: true)
        contact.localName = "Alice at work"
        contact.messageName = "Ali"
        contact.messageNameAt = 1_700_000_100
        ctx.insert(contact)

        ctx.insert(ChatEntity(id: "chat-alice", peerHash: alice, lastMessageTime: 1_700_000_200))
        for i in 0..<3 {
            ctx.insert(MessageEntity(id: "msg-\(i)", chatId: "chat-alice", senderHash: i == 1 ? "me" : alice,
                                     content: "message number \(i) \u{1F600}", timestamp: 1_700_000_000 + Double(i),
                                     isOutgoing: i == 1, deliveryState: i, signatureValid: true))
        }
        ctx.insert(AttachmentEntity(id: "att-1", messageId: "msg-2", filename: "photo.jpg",
                                    data: Data((0..<1024).map { UInt8($0 & 0xff) }), mimeType: "image/jpeg"))
        ctx.insert(GroupMemberEntity(groupId: "group-1", memberHash: alice, inviteStatus: "accepted"))
        ctx.insert(InterfaceConfigEntity(id: "tcp-1", type: "TCPClient", name: "Home", targetHost: "192.168.2.107",
                                         targetPort: 4242, enabled: true))

        // A channel the device posted in as itself: its §4.2 name state is on the channel row.
        let channel = ChannelEntity(channelHash: general, channelName: "public.general", rfedNodeHash: "ee" + String(repeating: "7f", count: 15),
                                    lastMessageTime: 1_700_000_300, isSubscribed: true, stampCost: 8)
        channel.nameLastDigestHex = String(repeating: "d1", count: 16)
        channel.nameLastIncludedAt = 1_700_000_250
        ctx.insert(channel)
        // A channel it never posted in: no name state.
        ctx.insert(ChannelEntity(channelHash: ops, channelName: "4cdc4115.ops", rfedNodeHash: "ee" + String(repeating: "7f", count: 15),
                                 lastMessageTime: 0, isSubscribed: false, stampCost: nil))
        for i in 0..<3 {
            ctx.insert(ChannelMessageEntity(id: (i == 2 ? "me" : alice) + String(format: "%016llx", 1_700_000_000_000 + i),
                                            channelHash: general, senderHash: i == 2 ? "me" : alice,
                                            content: "channel post \(i)", timestamp: 1_700_000_000_000 + Double(i),
                                            isOutgoing: i == 2, deliveryState: i == 2 ? 1 : 2))
        }
        let sender = ChannelSenderEntity(channelHash: general, senderHash: alice, firstSeenAt: 1_700_000_001)
        sender.channelName = "Ali on #general"
        sender.channelNameAtMs = 1_700_000_000_000
        ctx.insert(sender)

        try ctx.save()
        print("wrote the old store: 1 contact, 1 chat, 3 messages, 1 attachment, 1 member, 1 interface, 2 channels, 3 channel posts, 1 sender at \(url.path)")
    }
}
