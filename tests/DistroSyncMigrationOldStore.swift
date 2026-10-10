// DistroSyncMigrationOldStore.swift
//
// Writes a SwiftData store the way the build BEFORE the distro sync proof (Retichat-ios
// 0d8ed61, the group-statuses tip this branch was made from) did: the fourteen entities it
// had, with an owed message of each kind as that build kept them (no sealed bytes, no
// proof: the columns are new) and rows of the other kinds a user has.
// tests/DistroSyncMigrationTests.swift then opens that store with the new Models.swift, as
// an updated app does.
//
// It is compiled with the OLD Models.swift (`git show 0d8ed61:Retichat/Models/Models.swift`),
// never the current one: see the run command in DistroSyncMigrationTests.swift. It takes the
// directory the store goes in.

import Foundation
import SwiftData

@main
enum DistroSyncMigrationOldStore {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: distro-sync-old-store <directory>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        // The model list RetichatApp's ModelContainer had at 0d8ed61.
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
        let distro = String(repeating: "d1", count: 16)
        let general = String(repeating: "c0", count: 16)

        ctx.insert(ContactEntity(destHash: alice, announceName: "Alice", lastSeen: 1_700_000_000, isAllowlisted: true, isContact: true))
        ctx.insert(ChatEntity(id: "chat-alice", peerHash: alice, lastMessageTime: 1_700_000_200))
        // Owed when the update lands: a membership message and a sent copy, as 0d8ed61 kept them.
        ctx.insert(DistroOutboxEntity(id: "channel:\(general)", kind: "channel", distro: distro,
                                      distroKey: String(repeating: "7", count: 128), msgHash: "j01",
                                      packed: Data(repeating: 2, count: 180), label: "the join of #public.general (§17.12)",
                                      op: "join", name: "public.general", atMs: 1_767_225_600_000, seq: 1))
        ctx.insert(DistroOutboxEntity(id: "sent:aa", kind: "sent", distro: distro,
                                      distroKey: String(repeating: "7", count: 128), msgHash: "aa",
                                      packed: Data(repeating: 1, count: 200), label: "the sent-copy for a1a1a1a1 (§17.11)",
                                      toHex: alice, seq: 2))
        ctx.insert(ChannelMembershipEntity(channelHash: general, op: "join", atMs: 1_767_225_600_000))
        ctx.insert(GroupStatusCopyEntity(groupId: "group-old", memberHash: creator, action: "accept", packed: Data(repeating: 3, count: 90)))
        ctx.insert(GroupHeldEntity(msgHash: "h01", groupId: "group-old", srcHash: alice, action: "leave",
                                   packed: Data(repeating: 4, count: 70), seq: 1))
        try ctx.save()
        print("wrote the old store: 1 contact, 1 chat, 2 owed messages, 1 membership record, 1 status copy, 1 held entry at \(url.path)")
    }
}
