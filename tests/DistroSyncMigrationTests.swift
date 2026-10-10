// DistroSyncMigrationTests.swift
//
// The distro sync proof (RFed SPEC §17.13; DISTRO-SYNC-PROOF-DESIGN.md §12.16, §13.1) adds two
// optional columns to DistroOutboxEntity (Models.swift: sealed, syncSig). The app has no
// VersionedSchema or migration plan, so SwiftData migrates by lightweight inference: this test
// opens a store written by the build BEFORE them (0d8ed61, the group-statuses tip this branch was
// made from) with the current Models.swift, as an updated app does, and checks:
//  - every old row is still there, field for field, and an entry owed before has neither column:
//    it loads with no seal and no proof, and is built the legacy way (UploadBuild.of);
//  - an entry owed now keeps its sealed bytes and proof across a restart (a second container on
//    the same file), byte for byte, through SwiftDataOutboxStore;
//  - a message replaced under its id takes the replacement's seal, or none when the replacement
//    could not be sealed (fill writes both columns), and an old row replaced gains one.
//
// Run from the workspace root with:
//
//   git -C Retichat-ios show 0d8ed61:Retichat/Models/Models.swift \
//     > /private/tmp/claude-501/OldModels3.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-sync-old-store \
//     /private/tmp/claude-501/OldModels3.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/DistroSyncMigrationOldStore.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-sync-migration \
//     Retichat-ios/Retichat/Models/Models.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DistroChannelStores.swift \
//     Retichat-ios/tests/DistroSyncMigrationTests.swift && \
//   rm -rf /private/tmp/claude-501/distro-sync-store && \
//   mkdir -p /private/tmp/claude-501/distro-sync-store && \
//   /private/tmp/claude-501/distro-sync-old-store /private/tmp/claude-501/distro-sync-store && \
//   /private/tmp/claude-501/distro-sync-migration /private/tmp/claude-501/distro-sync-store
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
let creator = String(repeating: "c3", count: 16)
let distro = String(repeating: "d1", count: 16)
let general = String(repeating: "c0", count: 16)
let ops = String(repeating: "c1", count: 16)
let rfedNode = Data(repeating: 0xa7, count: 16)

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

/// An entry owed now: sealed once, with D's signature over the sealed bytes (shapes only; the
/// bytes are the glue crate's, verified in DistroChannelsFFITests and the crate's own tests).
func sealedEntry(_ id: String, _ hash: String, kind: OwedKind) -> OwedEntry {
    OwedEntry(id: id, kind: kind, distro: distro, distroKey: String(repeating: "7", count: 128), msgHash: hash,
              packed: Data(hash.utf8) + Data(repeating: 0xAB, count: 300), label: "the thing \(hash)",
              op: kind == .channel ? "leave" : nil, name: kind == .channel ? "public.x" : nil,
              atMs: kind == .channel ? 1_767_225_700_000 : nil, toHex: kind == .sent ? String(repeating: "c", count: 32) : nil,
              sealed: Data(repeating: 0xd1, count: 16) + Data(hash.utf8) + Data(repeating: 0x5e, count: 400),
              syncSig: Data((0..<64).map { UInt8($0) ^ UInt8(hash.utf8.first ?? 0) }))
}

@MainActor
func everyOldRowSurvivesAndAnEntryOwedBeforeLoadsWithNoSealAndBuildsTheLegacyWay(_ url: URL) async throws {
    let container = try openStore(url)   // kept alive: a context does not keep its container
    let ctx = container.mainContext
    let rows = try ctx.fetch(FetchDescriptor<DistroOutboxEntity>(sortBy: [SortDescriptor(\.seq)]))
    checkEqual(rows.map(\.id), ["channel:\(general)", "sent:aa"], "both owed rows are there, in order")
    checkEqual(rows.map(\.msgHash), ["j01", "aa"], "their messages")
    checkEqual(rows.map(\.packed), [Data(repeating: 2, count: 180), Data(repeating: 1, count: 200)], "the packed bytes, unchanged")
    checkEqual(rows.first?.op ?? "", "join", "the channel row's action")
    checkEqual(rows.first?.atMs ?? 0, 1_767_225_600_000, "and its time")
    checkEqual(rows.last?.toHex ?? "", alice, "the sent copy's recipient")
    check(rows.allSatisfy { $0.sealed == nil && $0.syncSig == nil }, "no row owed before has a seal or a proof")

    checkEqual(try ctx.fetch(FetchDescriptor<ContactEntity>()).map(\.destHash), [alice], "the contact")
    checkEqual(try ctx.fetch(FetchDescriptor<ChatEntity>()).map(\.id), ["chat-alice"], "the chat")
    checkEqual(try ctx.fetch(FetchDescriptor<ChannelMembershipEntity>()).map(\.op), ["join"], "rule 5's record")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>()).map(\.memberHash), [creator], "the creator's status copy")
    checkEqual(try ctx.fetch(FetchDescriptor<GroupHeldEntity>()).map(\.msgHash), ["h01"], "the held accept or leave")

    let loaded = await SwiftDataOutboxStore(container: try openStore(url)).loadAll()
    checkEqual(loaded.map(\.id), ["channel:\(general)", "sent:aa"], "the outbox loads both")
    check(loaded.allSatisfy { $0.sealed == nil && $0.syncSig == nil }, "with no seal and no proof")
    for entry in loaded {
        checkEqual(UploadBuild.of(entry, node: rfedNode, rfedDerived: rfedNode), .legacy,
                   "\(entry.id) is built the legacy way, even for the RFed's own node")
    }
}

@MainActor
func anEntryOwedNowKeepsItsSealAndProofAcrossARestartAndAReplacementTakesItsOwn(_ url: URL) async throws {
    let first = SwiftDataOutboxStore(container: try openStore(url))
    let copy = sealedEntry("sent:bb", "bb", kind: .sent)
    let leave = sealedEntry("channel:\(ops)", "l02", kind: .channel)
    check(await first.put(copy), "a sealed sent copy is kept")
    check(await first.put(leave), "a sealed membership message is kept")

    // The app stops: a new container on the same file, a new store.
    let second = SwiftDataOutboxStore(container: try openStore(url))
    let loaded = await second.loadAll()
    checkEqual(loaded.map(\.id), ["channel:\(general)", "sent:aa", "sent:bb", "channel:\(ops)"], "in the order owed")
    guard loaded.count == 4 else { return }
    checkEqual(loaded[2].sealed, copy.sealed, "the sent copy's sealed bytes, unchanged")
    checkEqual(loaded[2].syncSig, copy.syncSig, "and its proof")
    checkEqual(loaded[3].sealed, leave.sealed, "the membership message's sealed bytes")
    checkEqual(loaded[3].syncSig, leave.syncSig, "and its proof")
    checkEqual(loaded[3].op ?? "", "leave", "with its other fields")
    checkEqual(UploadBuild.of(loaded[2], node: rfedNode, rfedDerived: rfedNode), .sealed(withClaim: true),
               "a sealed entry carries its claim to the RFed's own node after a restart")

    // A later action on an old row's channel replaces it in place, sealed now.
    let rejoin = sealedEntry("channel:\(general)", "j03", kind: .channel)
    check(await second.put(rejoin), "the old row is replaced")
    // And a later one that could not be sealed takes the seal away with the message it replaces.
    var unsealed = sealedEntry("channel:\(ops)", "l04", kind: .channel)
    unsealed.sealed = nil
    unsealed.syncSig = nil
    check(await second.put(unsealed), "an unsealed replacement is kept")

    let third = SwiftDataOutboxStore(container: try openStore(url))
    let after = await third.loadAll()
    checkEqual(after.map(\.msgHash), ["aa", "bb", "j03", "l04"], "replaced in place, and last")
    guard after.count == 4 else { return }
    checkEqual(after[2].sealed, rejoin.sealed, "the old row gained the replacement's seal")
    checkEqual(after[2].syncSig, rejoin.syncSig, "and its proof")
    check(after[3].sealed == nil && after[3].syncSig == nil, "a replacement with no seal leaves none of the old one's")
    checkEqual(UploadBuild.of(after[3], node: rfedNode, rfedDerived: rfedNode), .legacy, "so it goes the legacy way")
}

@main
enum DistroSyncMigrationTests {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("usage: distro-sync-migration <directory with the old store>")
            exit(2)
        }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = dir.appendingPathComponent("retichat.store")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("FAIL: no old store at \(url.path): run distro-sync-old-store first")
            exit(2)
        }
        let steps: [(String, () async throws -> Void)] = [
            ("every old row survives, and an entry owed before loads with no seal and builds the legacy way",
             { try await everyOldRowSurvivesAndAnEntryOwedBeforeLoadsWithNoSealAndBuildsTheLegacyWay(url) }),
            ("an entry owed now keeps its seal and proof across a restart, and a replacement takes its own",
             { try await anEntryOwedNowKeepsItsSealAndProofAcrossARestartAndAReplacementTakesItsOwn(url) }),
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
