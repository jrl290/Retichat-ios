// DistroGroupsMigrationTests.swift
//
// Groups for distro holders (GROUPS-DISTRO-DESIGN.md §6.5, §8.1, §10.2, §10.5) add one SwiftData
// entity (Models.swift: GroupHeldArrivalEntity), two optional columns to ChatEntity (ownMember,
// membersCsv) and an owed kind ("group"). The app has no VersionedSchema or migration plan, so
// SwiftData migrates by lightweight inference: this test opens a store written by the build BEFORE
// them (f0599c2) with the current Models.swift, as an updated app does, and checks:
//  - every old row is still there, field for field, and every group held before has no own address
//    and no member list: it is a device group (GroupSelf), as before;
//  - a D-group made or joined afterwards records its own address and its list, read back across a
//    restart (a second container on the same file);
//  - held arrivals are kept across a restart, in arrival order, unique on their key;
//  - an owed group sync is kept by the outbox's own store across a restart as a group entry, beside
//    the old sent copy and channel record (an older build reads no row it does not know).
//
// Run from the workspace root with:
//
//   git -C Retichat-ios show f0599c2:Retichat/Models/Models.swift \
//     > /private/tmp/claude-501/OldModels3.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-groups-old-store \
//     /private/tmp/claude-501/OldModels3.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/DistroGroupsMigrationOldStore.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-groups-migration \
//     Retichat-ios/Retichat/Models/Models.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DistroChannelStores.swift \
//     Retichat-ios/tests/DistroGroupsMigrationTests.swift && \
//   rm -rf /private/tmp/claude-501/distro-groups-store && \
//   mkdir -p /private/tmp/claude-501/distro-groups-store && \
//   /private/tmp/claude-501/distro-groups-old-store /private/tmp/claude-501/distro-groups-store && \
//   /private/tmp/claude-501/distro-groups-migration /private/tmp/claude-501/distro-groups-store
//
// SwiftData runs for real, against files in that scratch directory (never the app's store).

import Foundation
import SwiftData

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func check(_ ok: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures.append("\(currentTest): \(what)")
        print("FAIL: \(currentTest): \(what) (line \(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

let aliceHash = String(repeating: "a1", count: 16)
let creatorHash = String(repeating: "c3", count: 16)
let myHash = String(repeating: "de", count: 16)
let distroHash = String(repeating: "d1", count: 16)

/// The model list RetichatApp's ModelContainer has now.
@MainActor
func openStore(_ url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
        GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
        ChannelMessageEntity.self, ChannelSenderEntity.self,
        ChannelNameStateEntity.self, ChannelMembershipEntity.self, DistroOutboxEntity.self,
        GroupStatusCopyEntity.self, GroupHeldEntity.self, GroupHeldArrivalEntity.self,
        configurations: ModelConfiguration(url: url))
}

@MainActor
func everyOldRowSurvivesAndEveryGroupHeldBeforeIsADeviceGroup(_ url: URL) throws {
    let container = try openStore(url)
    let ctx = container.mainContext
    checkEqual(try ctx.fetch(FetchDescriptor<ContactEntity>()).count, 1, "contacts")
    checkEqual(try ctx.fetch(FetchDescriptor<ChatEntity>()).count, 4, "chats")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupMemberEntity>()).count, 7, "group members")
    checkEqual(try ctx.fetch(FetchDescriptor<MessageEntity>()).count, 3, "messages")
    checkEqual(try ctx.fetch(FetchDescriptor<DistroOutboxEntity>()).count, 2, "owed messages")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>()).count, 1, "kept copies")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupHeldEntity>()).count, 1, "entries held for a key")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupHeldArrivalEntity>()).count, 0, "no held arrival on a migrated store")

    let chats = try ctx.fetch(FetchDescriptor<ChatEntity>(sortBy: [SortDescriptor(\.id)]))
    checkEqual(chats.map(\.id), ["chat-alice", "group-joined", "group-mine", "group-pending"], "chat ids")
    checkEqual(chats.map { $0.groupStatus ?? "" }, ["", "active", "active", "pending"], "where the user stands")
    checkEqual(chats.map { $0.creatorHash ?? "" }, ["", creatorHash, myHash, creatorHash], "the creators recorded before")
    check(chats.allSatisfy { $0.ownMember == nil && $0.membersCsv == nil }, "no own address and no list recorded before")
    check(chats.filter(\.isGroup).allSatisfy { !GroupSelf.isDistroGroup(ownMember: $0.ownMember, device: myHash) },
          "so every group held before is a device group, as it was")
    checkEqual(GroupSelf.signer(ownMember: chats[1].ownMember, device: myHash, loadedDistro: distroHash, distroSettled: true),
               .device, "signed by the device, as before")
    let messages = try ctx.fetch(FetchDescriptor<MessageEntity>(sortBy: [SortDescriptor(\.id)]))
    checkEqual(messages.map(\.content), (0..<3).map { "group message \($0) \u{1F600}" }, "message texts")
}

@MainActor
func aDGroupRecordsItsOwnAddressAndItsListAcrossARestart(_ url: URL) throws {
    let csv = "\(distroHash),\(creatorHash),\(aliceHash)"
    do {
        let container = try openStore(url)
        let ctx = container.mainContext
        ctx.insert(ChatEntity(id: "group-d", peerHash: creatorHash, isGroup: true, groupName: "D", groupStatus: "pending",
                              creatorHash: creatorHash, ownMember: distroHash, membersCsv: csv))
        let old = try ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == "group-joined" })).first
        check(old != nil, "an old group is there")
        try ctx.save()
    }
    let container = try openStore(url)
    let ctx = container.mainContext
    let d = try ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == "group-d" })).first
    checkEqual(d?.ownMember, distroHash, "the own address is read back")
    checkEqual(d?.membersCsv, csv, "and the list, verbatim")
    check(GroupSelf.isDistroGroup(ownMember: d?.ownMember, device: myHash), "a D-group")
    checkEqual(GroupSelf.signer(ownMember: d?.ownMember, device: myHash, loadedDistro: nil, distroSettled: true),
               .formerDistro(distroHash), "never signed by the device once D is gone")
}

@MainActor
func heldArrivalsAreKeptAcrossARestartInArrivalOrderUniqueOnTheirKey(_ url: URL) throws {
    do {
        let container = try openStore(url)
        let ctx = container.mainContext
        for (seq, source) in [(2, aliceHash), (1, creatorHash), (3, distroHash)] {
            ctx.insert(GroupHeldArrivalEntity(key: "h\(seq):validated", groupId: "group-d", srcHash: source, msgHash: "h\(seq)",
                                              signature: nil, validated: true, countsAgainstSource: source != distroHash,
                                              distro: distroHash, blob: Data(repeating: UInt8(seq), count: 100 * seq), seq: seq))
        }
        try ctx.save()
    }
    let container = try openStore(url)
    let ctx = container.mainContext
    let rows = try ctx.fetch(FetchDescriptor<GroupHeldArrivalEntity>(sortBy: [SortDescriptor(\.seq)]))
    checkEqual(rows.map(\.msgHash), ["h1", "h2", "h3"], "in arrival order")
    checkEqual(rows.map(\.size), [100, 200, 300], "with their sizes")
    checkEqual(rows.map(\.countsAgainstSource), [true, true, false], "a post G counts only against its group")
    // The same key again replaces, never adds (SwiftData's unique attribute).
    ctx.insert(GroupHeldArrivalEntity(key: "h1:validated", groupId: "group-d", srcHash: creatorHash, msgHash: "h1",
                                      signature: nil, validated: true, countsAgainstSource: true, distro: distroHash,
                                      blob: Data(repeating: 9, count: 10), seq: 4))
    try ctx.save()
    checkEqual(try ctx.fetch(FetchDescriptor<GroupHeldArrivalEntity>()).count, 3, "one row per key")
}

@MainActor
func anOwedGroupSyncIsKeptAcrossARestartAsAGroupEntryBesideTheOldOnes(_ url: URL) async throws {
    let container = try openStore(url)
    let entry = OwedEntry(id: DistroGroupSync.entryId(hashHex: "ff"), kind: .group, distro: distroHash,
                          distroKey: String(repeating: "7", count: 128), msgHash: "ff", packed: Data(repeating: 5, count: 400),
                          label: "the leave group sync of group-d (SPEC §17.14)",
                          sealed: Data(repeating: 6, count: 500), syncSig: Data(repeating: 7, count: 64))
    do {
        let store = SwiftDataOutboxStore(container: container)
        let old = await store.loadAll()
        checkEqual(old.map(\.id), ["sent:aa", "channel:cc"], "the old entries load, in order")
        checkEqual(old.map(\.kind), [.sent, .channel], "as their kinds")
        check(await store.put(entry), "a group sync is owed")
    }
    let again = await SwiftDataOutboxStore(container: try openStore(url)).loadAll()
    checkEqual(again.map(\.id), ["sent:aa", "channel:cc", "group:ff"], "a restart finds it last")
    let group = again.last
    checkEqual(group?.kind, .group, "as a group entry, not a sent copy")
    checkEqual(group?.packed, entry.packed, "its packed bytes")
    checkEqual(group?.sealed, entry.sealed, "its seal")
    checkEqual(group?.syncSig, entry.syncSig, "and its proof")
}

@main
enum DistroGroupsMigrationTests {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: distro-groups-migration <directory with retichat.store>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        let tests: [(String, () async throws -> Void)] = [
            ("every old row survives and every group held before is a device group", { try everyOldRowSurvivesAndEveryGroupHeldBeforeIsADeviceGroup(url) }),
            ("a D-group records its own address and its list across a restart", { try aDGroupRecordsItsOwnAddressAndItsListAcrossARestart(url) }),
            ("held arrivals are kept across a restart, in arrival order, unique on their key", { try heldArrivalsAreKeptAcrossARestartInArrivalOrderUniqueOnTheirKey(url) }),
            ("an owed group sync is kept across a restart as a group entry beside the old ones", { try await anOwedGroupSyncIsKeptAcrossARestartAsAGroupEntryBesideTheOldOnes(url) }),
        ]
        for (name, run) in tests {
            currentTest = name
            let before = failures.count
            try await run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(tests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
