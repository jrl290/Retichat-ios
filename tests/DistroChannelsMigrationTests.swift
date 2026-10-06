// DistroChannelsMigrationTests.swift
//
// Channels and the distro add three SwiftData entities (Models.swift:
// ChannelNameStateEntity, ChannelMembershipEntity, DistroOutboxEntity), and the
// §4.2 name state moves from two columns of ChannelEntity to a row per channel
// and posting identity. The app has no VersionedSchema or migration plan, so
// SwiftData migrates by lightweight inference: this test opens a store written
// by the build BEFORE them (05df78e, the commit this branch was made from) with
// the current Models.swift, as an updated app does, and checks that nothing a
// user has was lost and that the new storage works on the migrated store:
//  - every old row is still there, field for field (messages, attachments,
//    contacts, channels with their posts and senders);
//  - the name state kept on a channel is adopted as the device's, once, and a
//    new posting identity starts from none;
//  - rule 5's record is kept per channel and updated in place;
//  - the outbox keeps what is owed across a restart (a second container on the
//    same file), in order, replaces an id in place, lets a message go only with
//    its own hash, and leaves a row of a kind it does not know alone.
//
// Run from the workspace root with:
//
//   git -C Retichat-ios show 05df78e:Retichat/Models/Models.swift \
//     > /private/tmp/claude-501/OldModels.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/migration-old-store \
//     /private/tmp/claude-501/OldModels.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/DistroChannelsMigrationOldStore.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-channels-migration \
//     Retichat-ios/Retichat/Models/Models.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DistroChannelStores.swift \
//     Retichat-ios/tests/DistroChannelsMigrationTests.swift && \
//   rm -rf /private/tmp/claude-501/migration-store && \
//   mkdir -p /private/tmp/claude-501/migration-store && \
//   /private/tmp/claude-501/migration-old-store /private/tmp/claude-501/migration-store && \
//   /private/tmp/claude-501/distro-channels-migration /private/tmp/claude-501/migration-store
//
// SwiftData runs for real, against files in that scratch directory (never the
// app's store). The wiring of the stores into RfedChannelClient is asserted on
// the source in DistroOutboxWiringTests.swift.

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

let alice = String(repeating: "a1", count: 16)
let general = String(repeating: "c0", count: 16)
let ops = String(repeating: "c1", count: 16)
let device = String(repeating: "de", count: 16)
let distro = String(repeating: "d1", count: 16)

/// The model list RetichatApp's ModelContainer has now.
@MainActor
func openStore(_ url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: ContactEntity.self, ChatEntity.self, MessageEntity.self, AttachmentEntity.self,
        GroupMemberEntity.self, InterfaceConfigEntity.self, ChannelEntity.self,
        ChannelMessageEntity.self, ChannelSenderEntity.self,
        ChannelNameStateEntity.self, ChannelMembershipEntity.self, DistroOutboxEntity.self,
        configurations: ModelConfiguration(url: url))
}

func entry(_ id: String, _ hash: String, kind: OwedKind = .channel, distro: String = distro) -> OwedEntry {
    OwedEntry(id: id, kind: kind, distro: distro, distroKey: String(repeating: "7", count: 128), msgHash: hash,
              packed: Data(hash.utf8) + Data(repeating: 0xAB, count: 300), label: "the thing \(hash)",
              op: kind == .channel ? "join" : nil, name: kind == .channel ? "public.x" : nil,
              atMs: kind == .channel ? 1_767_225_600_000 : nil, toHex: kind == .sent ? String(repeating: "c", count: 32) : nil)
}

@MainActor
func everyOldRowSurvivesTheMigrationFieldForField(_ url: URL) throws {
    let container = try openStore(url)   // kept alive: a context does not keep its container
    let ctx = container.mainContext
    checkEqual(try ctx.fetch(FetchDescriptor<ContactEntity>()).count, 1, "contacts")
    checkEqual(try ctx.fetch(FetchDescriptor<ChatEntity>()).count, 1, "chats")
    checkEqual(try ctx.fetch(FetchDescriptor<MessageEntity>()).count, 3, "messages")
    checkEqual(try ctx.fetch(FetchDescriptor<AttachmentEntity>()).count, 1, "attachments")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupMemberEntity>()).count, 1, "group members")
    checkEqual(try ctx.fetch(FetchDescriptor<InterfaceConfigEntity>()).count, 1, "interfaces")
    checkEqual(try ctx.fetch(FetchDescriptor<ChannelEntity>()).count, 2, "channels")
    checkEqual(try ctx.fetch(FetchDescriptor<ChannelMessageEntity>()).count, 3, "channel posts")
    checkEqual(try ctx.fetch(FetchDescriptor<ChannelSenderEntity>()).count, 1, "channel senders")

    let contact = try ctx.fetch(FetchDescriptor<ContactEntity>()).first
    checkEqual(contact?.destHash ?? "", alice, "contact hash")
    checkEqual(contact?.localName ?? "", "Alice at work", "contact local name")
    checkEqual(contact?.messageName ?? "", "Ali", "contact message name")
    checkEqual(contact?.announceName ?? "", "Alice", "contact announce name")
    checkEqual(contact?.isContact ?? false, true, "contact flag")

    let messages = try ctx.fetch(FetchDescriptor<MessageEntity>(sortBy: [SortDescriptor(\.id)]))
    checkEqual(messages.map(\.content), ["message number 0 \u{1F600}", "message number 1 \u{1F600}", "message number 2 \u{1F600}"], "message texts")
    checkEqual(messages.map(\.isOutgoing), [false, true, false], "message directions")
    checkEqual(messages.map(\.deliveryState), [0, 1, 2], "message states")
    checkEqual(messages.map(\.timestamp), [1_700_000_000, 1_700_000_001, 1_700_000_002], "message times")

    let attachment = try ctx.fetch(FetchDescriptor<AttachmentEntity>()).first
    checkEqual(attachment?.data ?? Data(), Data((0..<1024).map { UInt8($0 & 0xff) }), "attachment bytes")
    checkEqual(attachment?.filename ?? "", "photo.jpg", "attachment name")

    let channels = try ctx.fetch(FetchDescriptor<ChannelEntity>(sortBy: [SortDescriptor(\.channelHash)]))
    checkEqual(channels.map(\.channelName), ["public.general", "4cdc4115.ops"], "channel names")
    checkEqual(channels.map(\.stampCost), [8, nil], "stamp costs")
    checkEqual(channels.map(\.isSubscribed), [true, false], "subscriptions")
    // The §4.2 state the build before kept on the channel is still there, until the device adopts it.
    checkEqual(channels[0].nameLastDigestHex ?? "", String(repeating: "d1", count: 16), "legacy digest")
    checkEqual(channels[0].nameLastIncludedAt ?? 0, 1_700_000_250, "legacy time")
    check(channels[1].nameLastDigestHex == nil && channels[1].nameLastIncludedAt == nil, "no legacy state where there was none")

    let posts = try ctx.fetch(FetchDescriptor<ChannelMessageEntity>(sortBy: [SortDescriptor(\.timestamp)]))
    checkEqual(posts.map(\.content), ["channel post 0", "channel post 1", "channel post 2"], "channel post texts")
    checkEqual(posts.map(\.isOutgoing), [false, false, true], "channel post directions")
    checkEqual(posts.last?.id ?? "", "me" + String(format: "%016llx", 1_700_000_000_002), "an own post keeps its (source, timestamp) id")
    let sender = try ctx.fetch(FetchDescriptor<ChannelSenderEntity>()).first
    checkEqual(sender?.channelName ?? "", "Ali on #general", "a sender's channel name")

    // The new entities start empty on a migrated store.
    checkEqual(try ctx.fetch(FetchDescriptor<ChannelNameStateEntity>()).count, 0, "name states")
    checkEqual(try ctx.fetch(FetchDescriptor<ChannelMembershipEntity>()).count, 0, "membership records")
    checkEqual(try ctx.fetch(FetchDescriptor<DistroOutboxEntity>()).count, 0, "owed messages")
}

@MainActor
func theNameStateOfTheBuildBeforeIsAdoptedByTheDeviceOnceAndANewIdentityStartsFromNone(_ url: URL) throws {
    let container = try openStore(url)   // kept alive: a context does not keep its container
    let ctx = container.mainContext
    check(ChannelNameStateStore.state(channelHash: general, postingHash: device, in: ctx) == nil, "none before the adoption")
    checkEqual(ChannelNameStateStore.adoptLegacy(deviceHash: "", in: ctx), 0, "no device address, nothing moved")
    checkEqual(ChannelNameStateStore.adoptLegacy(deviceHash: device, in: ctx), 1, "one channel carried state")
    let adopted = ChannelNameStateStore.state(channelHash: general, postingHash: device, in: ctx)
    checkEqual(adopted?.digestHex ?? "", String(repeating: "d1", count: 16), "the digest is the device's now")
    checkEqual(adopted?.at ?? 0, 1_700_000_250, "and its time")
    // A distro this device takes starts from none: readers have never had a name from it.
    check(ChannelNameStateStore.state(channelHash: general, postingHash: distro, in: ctx) == nil, "a new posting identity starts from none")
    check(ChannelNameStateStore.state(channelHash: ops, postingHash: device, in: ctx) == nil, "a channel with no state has none")
    // Once: ChannelEntity's copy is cleared, so a second pass moves nothing and clobbers nothing.
    ChannelNameStateStore.upsert(channelHash: general, postingHash: device, digestHex: "newer", at: 1_800_000_000, in: ctx)
    checkEqual(ChannelNameStateStore.adoptLegacy(deviceHash: device, in: ctx), 0, "a second pass moves nothing")
    checkEqual(ChannelNameStateStore.state(channelHash: general, postingHash: device, in: ctx)?.digestHex ?? "", "newer", "and keeps what is newer")
    let channel = try ctx.fetch(FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.channelHash == general })).first
    check(channel?.nameLastDigestHex == nil && channel?.nameLastIncludedAt == nil, "the channel's copy is cleared")
    // Each identity keeps its own row; a channel's rows go with the channel.
    ChannelNameStateStore.upsert(channelHash: general, postingHash: distro, digestHex: "as-distro", at: 5, in: ctx)
    checkEqual(ChannelNameStateStore.state(channelHash: general, postingHash: distro, in: ctx)?.digestHex ?? "", "as-distro", "the distro's row")
    checkEqual(ChannelNameStateStore.state(channelHash: general, postingHash: device, in: ctx)?.digestHex ?? "", "newer", "the device's row is its own")
    ChannelNameStateStore.upsert(channelHash: general, postingHash: distro, digestHex: "again", at: 6, in: ctx)
    checkEqual((try ctx.fetch(FetchDescriptor<ChannelNameStateEntity>())).count, 2, "an update is in place, one row per channel and identity")
    ChannelNameStateStore.forget(channelHash: general, in: ctx)
    checkEqual((try ctx.fetch(FetchDescriptor<ChannelNameStateEntity>())).count, 0, "every identity's state goes with the channel")

    // A pair the old build left half-written is cleared, not turned into a state.
    let half = ChannelEntity(channelHash: ops, channelName: "4cdc4115.ops", rfedNodeHash: "ee")
    half.nameLastDigestHex = "orphan"
    ctx.delete(try ctx.fetch(FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.channelHash == ops })).first!)
    try ctx.save()
    ctx.insert(half)
    try ctx.save()
    checkEqual(ChannelNameStateStore.adoptLegacy(deviceHash: device, in: ctx), 0, "a half pair is not a state")
    check(half.nameLastDigestHex == nil, "and is cleared")
}

@MainActor
func ruleFivesRecordIsKeptPerChannelAndUpdatedInPlace(_ url: URL) throws {
    let container = try openStore(url)   // kept alive: a context does not keep its container
    let ctx = container.mainContext
    check(ChannelMembershipStore.record(channelHash: general, in: ctx) == nil, "none yet")
    ChannelMembershipStore.upsert(channelHash: general, record: .init(op: "join", atMs: 1_767_225_600_000), in: ctx)
    ChannelMembershipStore.upsert(channelHash: ops, record: .init(op: "leave", atMs: 5), in: ctx)
    ChannelMembershipStore.upsert(channelHash: general, record: .init(op: "leave", atMs: 1_767_225_600_001), in: ctx)
    checkEqual(ChannelMembershipStore.record(channelHash: general, in: ctx), .init(op: "leave", atMs: 1_767_225_600_001), "updated in place")
    checkEqual(ChannelMembershipStore.record(channelHash: ops, in: ctx), .init(op: "leave", atMs: 5), "a leave's record is kept")
    checkEqual((try ctx.fetch(FetchDescriptor<ChannelMembershipEntity>())).count, 2, "one row per channel")
    // The record outlives the channel's own row: it is what stops an older join coming back.
    for channel in try ctx.fetch(FetchDescriptor<ChannelEntity>()) { ctx.delete(channel) }
    try ctx.save()
    checkEqual(ChannelMembershipStore.record(channelHash: general, in: ctx)?.op ?? "", "leave", "kept after the channel is gone")
    // 2^53 - 1 fits the column.
    ChannelMembershipStore.upsert(channelHash: general, record: .init(op: "join", atMs: DistroChannelSync.maxAtMs), in: ctx)
    checkEqual(ChannelMembershipStore.record(channelHash: general, in: ctx)?.atMs ?? 0, DistroChannelSync.maxAtMs, "the largest at_ms")
}

@MainActor
func theOutboxKeepsWhatIsOwedAcrossARestartInOrderAndLetsAMessageGoOnlyWithItsOwnHash(_ url: URL) async throws {
    let first = SwiftDataOutboxStore(container: try openStore(url))
    let join = entry("channel:\(general)", "join")
    let copy = entry("sent:abc", "abc", kind: .sent)
    let other = entry("channel:\(ops)", "other")
    check(await first.put(join), "the join is kept")
    check(await first.put(copy), "the copy is kept")
    check(await first.put(other), "another channel's is kept")
    // The app stops: a new container on the same file, a new store.
    let second = SwiftDataOutboxStore(container: try openStore(url))
    let loaded = await second.loadAll()
    checkEqual(loaded, [join, copy, other], "loaded in the order owed")
    checkEqual(loaded.map(\.packed), [join, copy, other].map(\.packed), "the packed bytes, unchanged")
    checkEqual(loaded.map(\.kind), [.channel, .sent, .channel], "the kinds")
    checkEqual(loaded[0].op ?? "", "join", "a channel entry's action")
    checkEqual(loaded[0].atMs ?? 0, 1_767_225_600_000, "and its time")
    checkEqual(loaded[1].toHex ?? "", String(repeating: "c", count: 32), "a sent copy's recipient")
    checkEqual(loaded[1].distroKey, String(repeating: "7", count: 128), "and the key it is owed under")

    // A later action under an id replaces it, in place, and goes to the end.
    let leave = entry("channel:\(general)", "leave")
    check(await second.put(leave), "the leave replaces the join")
    checkEqual(await second.loadAll(), [copy, other, leave], "replaced and last")
    // A message goes only with its own hash: the join's removal is a no-op now.
    await second.remove(id: leave.id, msgHash: "join")
    checkEqual(await second.loadAll().count, 3, "an older message's removal takes nothing")
    await second.remove(id: leave.id, msgHash: "leave")
    checkEqual(await second.loadAll(), [copy, other], "the proved message goes")
    // Whatever is under an id goes with removeId (a replaced message when its replacement's write was refused).
    try await second.removeId(other.id)
    checkEqual(await second.loadAll(), [copy], "removeId")
    // A row of a kind this build does not know is left alone and never uploaded.
    let container = try openStore(url)   // kept alive: a context does not keep its container
    let ctx = container.mainContext
    ctx.insert(DistroOutboxEntity(id: "future:1", kind: "from-a-newer-build", distro: distro, distroKey: "k", msgHash: "m",
                                  packed: Data([1]), label: "future", seq: 99))
    try ctx.save()
    let third = SwiftDataOutboxStore(container: try openStore(url))
    checkEqual(await third.loadAll(), [copy], "an unknown kind is not loaded")
    check(await third.put(entry("sent:def", "def", kind: .sent)), "a write after a load goes after the highest seq")
    let last = try ctx.fetch(FetchDescriptor<DistroOutboxEntity>(sortBy: [SortDescriptor(\.seq)])).map(\.id)
    checkEqual(last, ["sent:abc", "future:1", "sent:def"], "the seq only grows")
}

@main
enum DistroChannelsMigrationTests {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("usage: distro-channels-migration <directory with the old store>")
            exit(2)
        }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = dir.appendingPathComponent("retichat.store")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("FAIL: no old store at \(url.path): run migration-old-store first")
            exit(2)
        }
        let steps: [(String, () async throws -> Void)] = [
            ("every old row survives the migration, field for field", { try everyOldRowSurvivesTheMigrationFieldForField(url) }),
            ("the name state of the build before is adopted by the device once and a new identity starts from none",
             { try theNameStateOfTheBuildBeforeIsAdoptedByTheDeviceOnceAndANewIdentityStartsFromNone(url) }),
            ("rule 5's record is kept per channel and updated in place", { try ruleFivesRecordIsKeptPerChannelAndUpdatedInPlace(url) }),
            ("the outbox keeps what is owed across a restart, in order, and lets a message go only with its own hash",
             { try await theOutboxKeepsWhatIsOwedAcrossARestartInOrderAndLetsAMessageGoOnlyWithItsOwnHash(url) }),
        ]
        for (name, run) in steps {
            currentTest = name
            let before = failures.count
            do { try await run() } catch { check(false, "threw \(error)") }
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(steps.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
