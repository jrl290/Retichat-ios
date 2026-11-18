// DistroDirectMigrationTests.swift
//
// Offline use of a distro address (RFed SPEC §17.15, 2026-11-18) adds one optional column to
// DistroOutboxEntity (Models.swift: stamp, the sender's stamp on a message received direct). The
// app has no VersionedSchema or migration plan, so SwiftData migrates by lightweight inference:
// this test opens a store written by the build BEFORE it (f1eb7bb) with the current Models.swift,
// as an updated app does, and checks:
//  - every old row is still there, field for field, a sealed one with its seal and proof, and none
//    has a stamp;
//  - a message received direct keeps its sealed bytes, proof and the sender's stamp across a
//    restart (a second container on the same file), byte for byte, through SwiftDataOutboxStore;
//  - a row of that kind without all three is left alone (DistroOutboxRows.entry), never uploaded.
//
// Run from the workspace root with:
//
//   git -C Retichat-ios show f1eb7bb:Retichat/Models/Models.swift \
//     > /private/tmp/claude-501/OldModels4.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-direct-old-store \
//     /private/tmp/claude-501/OldModels4.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/DistroDirectMigrationOldStore.swift && \
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-direct-migration \
//     Retichat-ios/Retichat/Models/Models.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DistroChannelStores.swift \
//     Retichat-ios/tests/DistroDirectMigrationTests.swift && \
//   rm -rf /private/tmp/claude-501/distro-direct-store && \
//   mkdir -p /private/tmp/claude-501/distro-direct-store && \
//   /private/tmp/claude-501/distro-direct-old-store /private/tmp/claude-501/distro-direct-store && \
//   /private/tmp/claude-501/distro-direct-migration /private/tmp/claude-501/distro-direct-store
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
let distro = String(repeating: "d1", count: 16)
let general = String(repeating: "c0", count: 16)

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
func everyOldRowSurvivesWithItsSealAndNoneHasAStamp(_ url: URL) async throws {
    let container = try openStore(url)   // kept alive: a context does not keep its container
    let ctx = container.mainContext
    let rows = try ctx.fetch(FetchDescriptor<DistroOutboxEntity>(sortBy: [SortDescriptor(\.seq)]))
    checkEqual(rows.map(\.id), ["channel:\(general)", "sent:aa"], "both owed rows are there, in order")
    checkEqual(rows.map(\.packed), [Data(repeating: 2, count: 180), Data(repeating: 1, count: 200)], "the packed bytes, unchanged")
    checkEqual(rows.last?.sealed, Data(repeating: 0x5e, count: 300), "the sent copy's seal")
    checkEqual(rows.last?.syncSig, Data(repeating: 0x51, count: 64), "and its proof")
    check(rows.allSatisfy { $0.stamp == nil }, "no row owed before has a stamp")
    checkEqual(try ctx.fetch(FetchDescriptor<ContactEntity>()).map(\.destHash), [alice], "the contact")

    let loaded = await SwiftDataOutboxStore(container: try openStore(url)).loadAll()
    checkEqual(loaded.map(\.id), ["channel:\(general)", "sent:aa"], "the outbox loads both")
    checkEqual(loaded.map(\.kind), [.channel, .sent], "as what they were")
    check(loaded.allSatisfy { $0.stamp == nil }, "with no stamp")
}

@MainActor
func aMessageReceivedDirectKeepsItsStampAcrossARestartAndIsLeftAloneWithoutIt(_ url: URL) async throws {
    let first = SwiftDataOutboxStore(container: try openStore(url))
    let direct = OwedEntry(id: "direct:cc", kind: .direct, distro: distro, distroKey: String(repeating: "7", count: 128),
                           msgHash: "cc", packed: Data(), label: "the message cc received direct (§17.15)",
                           sealed: Data(repeating: 0xd1, count: 16) + Data(repeating: 0x5e, count: 400),
                           syncSig: Data(repeating: 0x33, count: 64), stamp: Data(repeating: 0x0f, count: 32))
    check(await first.put(direct), "a message received direct is kept")

    // The app stops: a new container on the same file, a new store.
    let loaded = await SwiftDataOutboxStore(container: try openStore(url)).loadAll()
    checkEqual(loaded.map(\.id), ["channel:\(general)", "sent:aa", "direct:cc"], "in the order owed")
    guard let back = loaded.last, back.id == "direct:cc" else { return }
    checkEqual(back.kind, .direct, "its kind")
    checkEqual(back.packed, Data(), "no packed bytes of its own")
    checkEqual(back.sealed, direct.sealed, "its sealed bytes, unchanged")
    checkEqual(back.syncSig, direct.syncSig, "its proof")
    checkEqual(back.stamp, direct.stamp, "the sender's stamp")

    // A row of that kind without all three cannot be uploaded as it came: left alone.
    let row = DistroOutboxRows.row(direct, seq: 9)
    check(DistroOutboxRows.entry(row) != nil, "whole, it is read")
    row.stamp = nil
    check(DistroOutboxRows.entry(row) == nil, "without the stamp, left alone")
    let other = DistroOutboxRows.row(direct, seq: 10)
    other.syncSig = nil
    check(DistroOutboxRows.entry(other) == nil, "without its proof, left alone")
}

@main
enum DistroDirectMigrationTests {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("usage: distro-direct-migration <directory the old store was written to>")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("retichat.store")
        let tests: [(String, () async throws -> Void)] = [
            ("every old row survives with its seal, and none has a stamp",
             { try await everyOldRowSurvivesWithItsSealAndNoneHasAStamp(url) }),
            ("a message received direct keeps its stamp across a restart, and is left alone without it",
             { try await aMessageReceivedDirectKeepsItsStampAcrossARestartAndIsLeftAloneWithoutIt(url) }),
        ]
        for (name, run) in tests {
            currentTest = name
            let before = failures.count
            do { try await run() } catch { check(false, "threw: \(error)") }
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(tests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
