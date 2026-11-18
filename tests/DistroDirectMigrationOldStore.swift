// DistroDirectMigrationOldStore.swift
//
// Writes a SwiftData store the way the build BEFORE offline use of a distro address (Retichat-ios
// f1eb7bb, the main this branch was made from) did: the fifteen entities RetichatApp's container
// had, with owed messages as that build kept them (no `stamp`: the column is new), a sealed sent
// copy among them, and a contact. tests/DistroDirectMigrationTests.swift then opens that store
// with the new Models.swift, as an updated app does.
//
// It is compiled with the OLD Models.swift (`git show f1eb7bb:Retichat/Models/Models.swift`),
// never the current one: see the run command in DistroDirectMigrationTests.swift. It takes the
// directory the store goes in.

import Foundation
import SwiftData

@main
enum DistroDirectMigrationOldStore {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: distro-direct-old-store <directory>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        // The model list RetichatApp's ModelContainer had at f1eb7bb.
        let container = try ModelContainer(
            for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
            GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
            ChannelMessageEntity.self, ChannelSenderEntity.self,
            ChannelNameStateEntity.self, ChannelMembershipEntity.self, DistroOutboxEntity.self,
            GroupStatusCopyEntity.self, GroupHeldEntity.self, GroupHeldArrivalEntity.self,
            configurations: ModelConfiguration(url: url))
        let ctx = container.mainContext

        let alice = String(repeating: "a1", count: 16)
        let distro = String(repeating: "d1", count: 16)
        let general = String(repeating: "c0", count: 16)

        ctx.insert(ContactEntity(destHash: alice, announceName: "Alice", lastSeen: 1_700_000_000, isAllowlisted: true, isContact: true))
        // Owed when the update lands: a membership message, and a sent copy sealed with its proof.
        ctx.insert(DistroOutboxEntity(id: "channel:\(general)", kind: "channel", distro: distro,
                                      distroKey: String(repeating: "7", count: 128), msgHash: "j01",
                                      packed: Data(repeating: 2, count: 180), label: "the join of #public.general (§17.12)",
                                      op: "join", name: "public.general", atMs: 1_767_225_600_000, seq: 1))
        ctx.insert(DistroOutboxEntity(id: "sent:aa", kind: "sent", distro: distro,
                                      distroKey: String(repeating: "7", count: 128), msgHash: "aa",
                                      packed: Data(repeating: 1, count: 200), label: "the sent-copy for a1a1a1a1 (§17.11)",
                                      toHex: alice, seq: 2,
                                      sealed: Data(repeating: 0x5e, count: 300), syncSig: Data(repeating: 0x51, count: 64)))
        try ctx.save()
        print("wrote the old store: 1 contact, 2 owed messages at \(url.path)")
    }
}
