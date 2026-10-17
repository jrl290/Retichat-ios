// ReactionsMigrationTests.swift
//
// Message reactions (REACTIONS-DESIGN.md §6) add three optional columns to MessageEntity: lxmfHash,
// postId and reactionsJson. The app has no VersionedSchema or migration plan, so SwiftData migrates
// by lightweight inference: this test opens a store written by the build BEFORE them (a328913)
// with the current Models.swift, as an updated app does, and checks:
//  - every old row is still there, and none has a hash, a post id or a reaction;
//  - a reaction stored on an old message, and a new message's hash and post id, are read back
//    across a restart (a second container on the same file);
//  - the lookups ChatRepository.reactionTarget makes find a message by its id, its lxmfHash or its
//    post id only within its own chat.
//
// Run from the workspace root with:
//
//   git -C Retichat-ios show a328913:Retichat/Models/Models.swift \
//     > /private/tmp/claude-501/ReactionsOldModels.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/reactions-old-store \
//     /private/tmp/claude-501/ReactionsOldModels.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DistroChannelStores.swift \
//     Retichat-ios/tests/ReactionsMigrationOldStore.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/reactions-migration \
//     Retichat-ios/Retichat/Models/Models.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DistroChannelStores.swift \
//     Retichat-ios/tests/ReactionsMigrationTests.swift && \
//   rm -rf /private/tmp/claude-501/reactions-store && \
//   mkdir -p /private/tmp/claude-501/reactions-store && \
//   /private/tmp/claude-501/reactions-old-store /private/tmp/claude-501/reactions-store && \
//   /private/tmp/claude-501/reactions-migration /private/tmp/claude-501/reactions-store
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

let alice = String(repeating: "a1", count: 16)
let received = String(repeating: "1a", count: 32)
let sent = String(repeating: "2b", count: 32)
let oldPost = String(repeating: "3c", count: 32)
let newHash = String(repeating: "4d", count: 32)
let postId = String(repeating: "5e", count: 16)
let reactions = #"{"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1":{"e":"👍","t":1700000300000}}"#

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
func everyOldMessageSurvivesWithNoHashPostIdOrReaction(_ url: URL) throws {
    let container = try openStore(url)  // kept: a model outlives no container
    let ctx = container.mainContext
    let messages = try ctx.fetch(FetchDescriptor<MessageEntity>(sortBy: [SortDescriptor(\.id)]))
    checkEqual(messages.map(\.id), [received, sent, oldPost], "every old message")
    checkEqual(messages.map(\.content), ["from Alice \u{1F600}", "to Alice", "a post"], "their texts")
    check(messages.allSatisfy { $0.lxmfHash == nil && $0.postId == nil && $0.reactionsJson == nil },
          "none has a hash, a post id or a reaction")
}

/// ChatRepository.reactionTarget's lookups, as it makes them.
@MainActor
func target(_ ctx: ModelContext, chatId: String, inGroup: Bool, toHex: String) -> MessageEntity? {
    let wanted: String? = toHex
    if inGroup {
        return try? ctx.fetch(FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.chatId == chatId && $0.postId == wanted })).first
    }
    if let found = try? ctx.fetch(FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == toHex && $0.chatId == chatId })).first {
        return found
    }
    return try? ctx.fetch(FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.chatId == chatId && $0.lxmfHash == wanted })).first
}

@MainActor
func reactionsHashesAndPostIdsAreKeptAcrossARestart(_ url: URL) throws {
    do {
        let container = try openStore(url)  // kept: a model outlives no container
        let ctx = container.mainContext
        guard let old = target(ctx, chatId: alice, inGroup: false, toHex: received) else {
            check(false, "an old message is found by its id in its chat")
            return
        }
        old.reactionsJson = reactions
        ctx.insert(MessageEntity(id: "distro-derived-id", chatId: alice, senderHash: alice, content: "via the distro",
                                 timestamp: 1_700_000_400, lxmfHash: newHash))
        ctx.insert(MessageEntity(id: String(repeating: "6f", count: 32), chatId: "group-1", senderHash: alice, content: "a new post",
                                 timestamp: 1_700_000_500, lxmfHash: String(repeating: "6f", count: 32), postId: postId))
        try ctx.save()
    }
    let container = try openStore(url)  // kept: a model outlives no container
    let ctx = container.mainContext
    checkEqual(target(ctx, chatId: alice, inGroup: false, toHex: received)?.reactionsJson, reactions, "the reaction on an old message")
    checkEqual(target(ctx, chatId: alice, inGroup: false, toHex: newHash)?.id, "distro-derived-id",
               "a message filed under another id is found by its lxmfHash")
    checkEqual(target(ctx, chatId: "group-1", inGroup: true, toHex: postId)?.content, "a new post", "a post by its post id")
    check(target(ctx, chatId: "group-1", inGroup: false, toHex: received) == nil, "never a message of another chat")
    check(target(ctx, chatId: alice, inGroup: true, toHex: postId) == nil, "never a post of another chat")
    check(target(ctx, chatId: "group-1", inGroup: true, toHex: oldPost) == nil, "an old post, which has no post id, is never a target")
    checkEqual(try ctx.fetch(FetchDescriptor<MessageEntity>()).count, 5, "nothing else was added")
}

@main
enum ReactionsMigrationTests {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: reactions-migration <directory>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        let tests: [(String, @MainActor (URL) throws -> Void)] = [
            ("every old message survives with no hash, post id or reaction", everyOldMessageSurvivesWithNoHashPostIdOrReaction),
            ("reactions, hashes and post ids are kept across a restart", reactionsHashesAndPostIdsAreKeptAcrossARestart),
        ]
        for (name, run) in tests {
            currentTest = name
            let before = failures.count
            do { try run(url) } catch { check(false, "threw \(error)") }
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(tests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
