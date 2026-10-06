// GroupStatusesMigrationTests.swift
//
// Member statuses and keys (RFed-spec Group.md, 2026-10-06) add two SwiftData entities
// (Models.swift: GroupStatusCopyEntity, GroupHeldEntity) and one optional column to ChatEntity
// (creatorHash). The app has no VersionedSchema or migration plan, so SwiftData migrates by
// lightweight inference: this test opens a store written by the build BEFORE them (096cfde, the
// distro-channels tip this branch was made from) with the current Models.swift, as an updated app
// does, and checks that nothing a user has was lost and that the new storage works on the migrated store:
//  - every old row is still there, field for field, and every group held before has NO creator
//    recorded (so it neither answers nor counts a status, as the spec says);
//  - the creator is recorded for a group made or invited into afterwards, and read back;
//  - the creator's copies and the entries held for a key are kept across a restart (a second
//    container on the same file), in order, replaced in place, and go with their group;
//  - GroupStatusEngine runs over the real store: a creator keeps the copy of a keyed accept it counted
//    and answers it, and a restart finds the copy.
//
// Run from the workspace root with:
//
//   git -C Retichat-ios show 096cfde:Retichat/Models/Models.swift \
//     > /private/tmp/claude-501/OldModels2.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/group-statuses-old-store \
//     /private/tmp/claude-501/OldModels2.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/GroupStatusesMigrationOldStore.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/group-statuses-migration \
//     Retichat-ios/Retichat/Models/Models.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/GroupStatuses.swift \
//     Retichat-ios/Retichat/Services/GroupStatusStore.swift \
//     Retichat-ios/tests/GroupStatusFixtures.swift \
//     Retichat-ios/tests/GroupStatusesMigrationTests.swift && \
//   rm -rf /private/tmp/claude-501/group-statuses-store && \
//   mkdir -p /private/tmp/claude-501/group-statuses-store && \
//   /private/tmp/claude-501/group-statuses-old-store /private/tmp/claude-501/group-statuses-store && \
//   /private/tmp/claude-501/group-statuses-migration /private/tmp/claude-501/group-statuses-store
//
// SwiftData runs for real, against files in that scratch directory (never the app's store).

import Foundation
import SwiftData

func hex(_ name: String) -> String { Vectors.load().hashOf(name) }

let aliceHash = String(repeating: "a1", count: 16)
let bobHash = String(repeating: "b2", count: 16)
let creatorHash = String(repeating: "c3", count: 16)
let myHash = String(repeating: "de", count: 16)

/// The model list RetichatApp's ModelContainer has now.
@MainActor
func openStore(_ url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
        GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
        ChannelMessageEntity.self, ChannelSenderEntity.self,
        ChannelNameStateEntity.self, ChannelMembershipEntity.self, DistroOutboxEntity.self,
        GroupStatusCopyEntity.self, GroupHeldEntity.self,
        configurations: ModelConfiguration(url: url))
}

/// The engine's store over `container`'s main context, and what it was asked to do outside the store.
@MainActor
final class Outside {
    var allowed: [String] = []
    var watched: [(String, Bool)] = []
    var lines: [(chat: String, member: String, joined: Bool, id: String)] = []

    func store(_ container: ModelContainer) -> SwiftDataGroupStatusStore {
        SwiftDataGroupStatusStore(
            context: { container.mainContext },
            allowMember: { self.allowed.append($0) },
            watchMember: { self.watched.append(($0, $1)) },
            line: { chat, member, joined, id, _ in self.lines.append((chat, member, joined, id)) })
    }
}

@MainActor
func everyOldRowSurvivesTheMigrationAndNoGroupHeldBeforeHasACreator(_ url: URL) throws {
    let container = try openStore(url)   // kept alive: a context does not keep its container
    let ctx = container.mainContext
    checkEqual(try ctx.fetch(FetchDescriptor<ContactEntity>()).count, 1, "contacts")
    checkEqual(try ctx.fetch(FetchDescriptor<ChatEntity>()).count, 3, "chats")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupMemberEntity>()).count, 6, "group members")
    checkEqual(try ctx.fetch(FetchDescriptor<MessageEntity>()).count, 3, "messages")
    checkEqual(try ctx.fetch(FetchDescriptor<DistroOutboxEntity>()).count, 1, "owed messages")
    checkEqual(try ctx.fetch(FetchDescriptor<ChannelMembershipEntity>()).count, 1, "membership records")

    let chats = try ctx.fetch(FetchDescriptor<ChatEntity>(sortBy: [SortDescriptor(\.id)]))
    checkEqual(chats.map(\.id), ["chat-alice", "group-old", "group-pending"], "chat ids")
    checkEqual(chats.map { $0.groupName ?? "" }, ["", "Old group", "Pending group"], "group names")
    checkEqual(chats.map { $0.groupStatus ?? "" }, ["", "active", "pending"], "where the user stands in each group")
    checkEqual(chats.map(\.isGroup), [false, true, true], "groups")
    checkEqual(chats.map(\.lastMessageTime), [1_700_000_200, 1_700_000_300, 1_700_000_400], "times")
    check(chats.allSatisfy { $0.creatorHash == nil }, "no group held before records a creator: it neither answers nor counts a status")

    let members = try ctx.fetch(FetchDescriptor<GroupMemberEntity>(predicate: #Predicate { $0.groupId == "group-old" }))
    checkEqual(Set(members.map { $0.memberHash + ":" + $0.inviteStatus }),
               Set([creatorHash + ":accepted", aliceHash + ":accepted", bobHash + ":invited", myHash + ":accepted"]), "the old group's members")
    let messages = try ctx.fetch(FetchDescriptor<MessageEntity>(sortBy: [SortDescriptor(\.id)]))
    checkEqual(messages.map(\.content), ["group message 0 \u{1F600}", "group message 1 \u{1F600}", "group message 2 \u{1F600}"], "message texts")

    // The new entities start empty on a migrated store.
    checkEqual(try ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>()).count, 0, "copies")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupHeldEntity>()).count, 0, "held entries")
}

@MainActor
func theStoreReadsAGroupHeldBeforeWithNoCreatorAndOneRecordedAfterwards(_ url: URL) throws {
    let container = try openStore(url)
    let ctx = container.mainContext
    let outside = Outside()
    let store = outside.store(container)
    checkEqual(store.chat(id: "group-old"), GroupChatInfo(id: "group-old", creatorHex: nil, groupStatus: "active"), "a group held before: no creator, joined")
    checkEqual(store.chat(id: "group-old")?.held, DeliveryPolicy.Held.joined, "joined")
    checkEqual(store.chat(id: "group-pending")?.held, DeliveryPolicy.Held.pending, "pending")
    check(store.chat(id: "chat-alice") == nil, "a direct chat is no group")
    check(store.chat(id: "nowhere") == nil, "nor is a chat not held")
    // A group made, or invited into, after: its creator is recorded with it.
    ctx.insert(ChatEntity(id: "group-new", peerHash: creatorHash, isGroup: true, groupName: "New", groupStatus: "pending", creatorHash: creatorHash))
    ctx.insert(ChatEntity(id: "group-mine", peerHash: "", isGroup: true, groupName: "Mine", groupStatus: "active", creatorHash: myHash))
    try ctx.save()
    checkEqual(store.chat(id: "group-new")?.creatorHex, creatorHash, "the invite's source is the creator")
    checkEqual(store.chat(id: "group-mine")?.creatorHex, myHash, "this device's own hash for a group it made")
    // The member rows and a status moved in the store: the announces are watched, and the row is the member's.
    checkEqual(store.members(chatId: "group-old").count, 4, "the group's members")
    store.setMemberStatus(chatId: "group-old", memberHex: bobHash, status: MemberStatus.accepted)
    checkEqual(GroupMemberStatuses.statusOf(store.members(chatId: "group-old"), bobHash), MemberStatus.accepted, "bob moved")
    checkEqual(GroupMemberStatuses.statusOf(store.members(chatId: "group-pending"), bobHash), nil, "and no other group's row")
    store.setMemberStatus(chatId: "group-old", memberHex: bobHash, status: MemberStatus.left)
    checkEqual(outside.watched.map { "\($0.0 == bobHash ? "bob" : "?") \($0.1)" }, ["bob true", "bob false"], "an accepted member's announces are watched, a leaver's are not")
}

@MainActor
func theCopiesAndTheHeldEntriesAreKeptAcrossARestartInOrderReplacedInPlaceAndGoWithTheirGroup(_ url: URL) throws {
    do {
        let container = try openStore(url)
        let store = Outside().store(container)
        store.putCopy(chatId: "group-old", memberHex: aliceHash, action: "accept", packed: Data(repeating: 1, count: 300))
        store.putCopy(chatId: "group-old", memberHex: bobHash, action: "leave", packed: Data(repeating: 2, count: 300))
        store.putCopy(chatId: "group-pending", memberHex: aliceHash, action: "accept", packed: Data(repeating: 3, count: 300))
        // The newest replaces it, in place.
        store.putCopy(chatId: "group-old", memberHex: aliceHash, action: "accept", packed: Data(repeating: 4, count: 300))
        for (index, src) in [aliceHash, bobHash, aliceHash].enumerated() {
            store.hold(HeldEntry(chatId: "group-old", srcHex: src, action: "accept", msgHash: "m\(index)", packed: Data(repeating: UInt8(10 + index), count: 250)))
        }
        store.hold(HeldEntry(chatId: "group-pending", srcHex: aliceHash, action: "leave", msgHash: "m3", packed: Data(repeating: 13, count: 250)))
    }
    // A restart: a second container on the same file.
    let container = try openStore(url)
    let ctx = container.mainContext
    let store = Outside().store(container)
    checkEqual(try ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>()).count, 3, "one copy for each group and member")
    checkEqual(store.copy(chatId: "group-old", memberHex: aliceHash)?.packed, Data(repeating: 4, count: 300), "the newest copy")
    checkEqual(store.copy(chatId: "group-old", memberHex: bobHash)?.action, "leave", "a leave's copy")
    check(store.copy(chatId: "group-old", memberHex: creatorHash) == nil, "none for a member that sent none")
    checkEqual(store.copies(chatId: "group-old").map(\.memberHex).sorted(), [aliceHash, bobHash], "the group's copies, and no other group's")
    checkEqual(store.held().map(\.msgHash), ["m0", "m1", "m2", "m3"], "held entries, oldest first")
    checkEqual(store.heldCount(), 4, "four in all")
    checkEqual(store.heldCount(chatId: "group-old", srcHex: aliceHash), 2, "two for alice in the old group")
    checkEqual(store.heldCount(srcHex: aliceHash), 3, "three for alice in all")
    check(store.isHeld(msgHash: "m2") && !store.isHeld(msgHash: "nope"), "a message is held once")
    store.release(HeldEntry(chatId: "group-old", srcHex: bobHash, action: "accept", msgHash: "m1", packed: Data()))
    checkEqual(store.held().map(\.msgHash), ["m0", "m2", "m3"], "released by its message hash, and the order stays")
    store.hold(HeldEntry(chatId: "group-old", srcHex: bobHash, action: "accept", msgHash: "m4", packed: Data([1])))
    checkEqual(store.held().map(\.msgHash).last, "m4", "a later one goes last")

    // A group's rows go with it, and only its own.
    SwiftDataGroupStatusStore.deleteRows(groupId: "group-old", in: ctx)
    try ctx.save()
    check(store.copies(chatId: "group-old").isEmpty, "the old group's copies are gone")
    checkEqual(store.copies(chatId: "group-pending").count, 1, "the other group's stay")
    checkEqual(store.held().map(\.msgHash), ["m3"], "and so do its held entries")
}

@MainActor
func theEngineRunsOverTheRealStoreACreatorKeepsTheCopyOfAKeyedAcceptAndAnswersItAndARestartFindsIt(_ url: URL) throws {
    let v = Vectors.load()
    let creatorHex = v.hashOf(v.creator)
    let packed = MessageMaker(v).msg("alice")
    var answers: [(String, [Data])] = []
    let outside = Outside()
    do {
        let container = try openStore(url)
        let ctx = container.mainContext
        // The vectors' group, made by this device (the creator) and accepted.
        ctx.insert(ChatEntity(id: v.groupId, peerHash: "", isGroup: true, groupName: "Vectors", groupStatus: "active", creatorHash: creatorHex))
        for name in v.members {
            ctx.insert(GroupMemberEntity(groupId: v.groupId, memberHash: v.hashOf(name),
                                         inviteStatus: name == v.creator ? MemberStatus.accepted : MemberStatus.invited))
        }
        try ctx.save()
        let native = FakeGroupNative()
        native.know(v.identities["creator"]!)
        let engine = GroupStatusEngine(store: outside.store(container), native: native, selfHex: { creatorHex },
                                       answer: { _, member, statuses in answers.append((member, statuses)) }, switched: false)
        guard let u = native.receipt(packed), let chat = outside.store(container).chat(id: v.groupId) else { check(false, "the message and the group"); return }
        checkEqual(u.signature, DeliveryPolicy.Signature.validated, "alice's keyed accept verifies by the key it carries")
        engine.onKept(src: u.source.hexString, action: GroupAction.accept, signature: u.signature, senderKey: u.senderKey)
        check(engine.takeDirect(GroupArrival(msgId: u.hash.hexString, src: u.source.hexString, chat: chat, action: GroupAction.accept,
                                             timestamp: u.timestamp, signature: u.signature, senderKey: u.senderKey, packed: packed)),
              "it counts")
        checkEqual(GroupMemberStatuses.statusOf(outside.store(container).members(chatId: v.groupId), hex("alice")), MemberStatus.accepted,
                   "alice is accepted in the real store")
        checkEqual(answers.map(\.0), [hex("alice")], "the creator answers it")
        checkEqual(answers.first?.1.count, 0, "with nobody else's yet")
        checkEqual(outside.allowed, [hex("alice")], "a member of a group the user joined passes the filter")
        checkEqual(outside.lines.map { "\($0.member == hex("alice")) \($0.joined) \($0.id.hasPrefix("acc_"))" }, ["true true true"], "and is said once")
        checkEqual(native.remembered, [hex("alice")], "her key is remembered")
    }
    // A restart finds the copy, byte for byte.
    let container = try openStore(url)
    checkEqual(outside.store(container).copy(chatId: v.groupId, memberHex: hex("alice"))?.packed, packed, "the copy is kept as received")
    checkEqual(GroupMemberStatuses.statusOf(outside.store(container).members(chatId: v.groupId), hex("alice")), MemberStatus.accepted, "and the status")
}

@main
enum GroupStatusesMigrationTests {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: group-statuses-migration <directory with retichat.store>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        let tests: [(String, () throws -> Void)] = [
            ("every old row survives the migration and no group held before has a creator", { try everyOldRowSurvivesTheMigrationAndNoGroupHeldBeforeHasACreator(url) }),
            ("the store reads a group held before with no creator and one recorded afterwards", { try theStoreReadsAGroupHeldBeforeWithNoCreatorAndOneRecordedAfterwards(url) }),
            ("the copies and the held entries are kept across a restart, in order, and go with their group", { try theCopiesAndTheHeldEntriesAreKeptAcrossARestartInOrderReplacedInPlaceAndGoWithTheirGroup(url) }),
            ("the engine runs over the real store", { try theEngineRunsOverTheRealStoreACreatorKeepsTheCopyOfAKeyedAcceptAndAnswersItAndARestartFindsIt(url) }),
        ]
        for (name, run) in tests {
            currentTest = name
            let before = failures.count
            try run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(tests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
