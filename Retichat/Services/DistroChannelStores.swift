//
//  DistroChannelStores.swift
//  Retichat
//
//  The storage behind channels and the distro (RFed SPEC §17.12), over the
//  three SwiftData entities of Models.swift. Foundation and SwiftData only, so
//  tests/DistroChannelsMigrationTests.swift runs it against a real store with
//  the app's Models.swift (DESIGN_PRINCIPLES.md §10):
//
//   - ChannelNameStateStore: the channel send rule's state per channel and
//     posting identity (DISPLAY_NAMES.md §4.2), and the adoption of the state
//     kept on ChannelEntity before it;
//   - ChannelMembershipStore: §17.12 rule 5's record, kept after a leave;
//   - SwiftDataOutboxStore: what the device owes its distro, the DistroOutbox's
//     OutboxStore, on its own context and serial queue.
//
//  Retichat-android's counterparts are ChannelDao's name-state and membership
//  queries and RoomOutboxStore.
//

import Foundation
import SwiftData

// MARK: - The name state, per channel and posting identity

enum ChannelNameStateStore {

    /// The digest (hex) of the Channel Display Name last included in a post to
    /// `channelHash` signed as `postingHash`, and when (seconds), or nil when
    /// none was (a new posting identity starts from none).
    static func state(channelHash: String, postingHash: String, in ctx: ModelContext)
        -> (digestHex: String, at: Double)? {
        let key = ChannelNameStateEntity.key(channelHash: channelHash, postingHash: postingHash)
        guard let row = (try? ctx.fetch(FetchDescriptor<ChannelNameStateEntity>(
            predicate: #Predicate { $0.key == key })))?.first else { return nil }
        return (row.lastDigestHex, row.lastIncludedAt)
    }

    /// Record what was last included for the channel and identity, and when.
    static func upsert(channelHash: String, postingHash: String, digestHex: String, at: Double,
                       in ctx: ModelContext) {
        let key = ChannelNameStateEntity.key(channelHash: channelHash, postingHash: postingHash)
        if let row = (try? ctx.fetch(FetchDescriptor<ChannelNameStateEntity>(
            predicate: #Predicate { $0.key == key })))?.first {
            row.lastDigestHex = digestHex
            row.lastIncludedAt = at
        } else {
            ctx.insert(ChannelNameStateEntity(channelHash: channelHash, postingHash: postingHash,
                                              lastDigestHex: digestHex, lastIncludedAt: at))
        }
        try? ctx.save()
    }

    /// A channel's state for every posting identity goes with the channel.
    static func forget(channelHash: String, in ctx: ModelContext) {
        let channel = channelHash
        let rows = (try? ctx.fetch(FetchDescriptor<ChannelNameStateEntity>(
            predicate: #Predicate { $0.channelHash == channel }))) ?? []
        for row in rows { ctx.delete(row) }
        try? ctx.save()
    }

    /// The state ChannelEntity kept before there was one per posting identity
    /// (nameLastDigestHex, nameLastIncludedAt) was made when the device posted
    /// as itself, the only posting identity then: it becomes `deviceHash`'s,
    /// where the device has no row of its own yet, and ChannelEntity's copy is
    /// cleared so this happens once. Nothing is lost, and no channel's name is
    /// announced again for the migration. Returns how many channels it moved.
    @discardableResult
    static func adoptLegacy(deviceHash: String, in ctx: ModelContext) -> Int {
        guard !deviceHash.isEmpty else { return 0 }
        let channels = (try? ctx.fetch(FetchDescriptor<ChannelEntity>())) ?? []
        var adopted = 0
        var changed = false
        for channel in channels where channel.nameLastDigestHex != nil || channel.nameLastIncludedAt != nil {
            if let digest = channel.nameLastDigestHex, let at = channel.nameLastIncludedAt,
               state(channelHash: channel.channelHash, postingHash: deviceHash, in: ctx) == nil {
                ctx.insert(ChannelNameStateEntity(channelHash: channel.channelHash, postingHash: deviceHash,
                                                  lastDigestHex: digest, lastIncludedAt: at))
                adopted += 1
            }
            channel.nameLastDigestHex = nil
            channel.nameLastIncludedAt = nil
            changed = true
        }
        if changed { try? ctx.save() }
        return adopted
    }
}

// MARK: - §17.12 rule 5's record

enum ChannelMembershipStore {

    /// The last membership action this device made or applied for the channel.
    static func record(channelHash: String, in ctx: ModelContext) -> DistroChannelSync.Record? {
        let channel = channelHash
        guard let row = (try? ctx.fetch(FetchDescriptor<ChannelMembershipEntity>(
            predicate: #Predicate { $0.channelHash == channel })))?.first else { return nil }
        return DistroChannelSync.Record(op: row.op, atMs: Int64(row.atMs))
    }

    /// Keep `record` for the channel: written for every join and leave the user makes here and
    /// every one applied from a sibling, and kept after a leave.
    static func upsert(channelHash: String, record: DistroChannelSync.Record, in ctx: ModelContext) {
        let channel = channelHash
        if let row = (try? ctx.fetch(FetchDescriptor<ChannelMembershipEntity>(
            predicate: #Predicate { $0.channelHash == channel })))?.first {
            row.op = record.op
            row.atMs = Int(record.atMs)
        } else {
            ctx.insert(ChannelMembershipEntity(channelHash: channelHash, op: record.op, atMs: Int(record.atMs)))
        }
        try? ctx.save()
    }
}

// MARK: - What the device owes its distro

/// The outbox's rows and the entries they hold, one for the other.
nonisolated enum DistroOutboxRows {
    static func row(_ entry: OwedEntry, seq: Int) -> DistroOutboxEntity {
        DistroOutboxEntity(id: entry.id, kind: entry.kind.rawValue, distro: entry.distro,
                           distroKey: entry.distroKey, msgHash: entry.msgHash, packed: entry.packed,
                           label: entry.label, op: entry.op, name: entry.name,
                           atMs: entry.atMs.map { Int($0) }, toHex: entry.toHex, seq: seq)
    }

    /// The row of an id already stored, made `entry` (the same fields `row` writes).
    static func fill(_ row: DistroOutboxEntity, from entry: OwedEntry, seq: Int) {
        row.kind = entry.kind.rawValue
        row.distro = entry.distro
        row.distroKey = entry.distroKey
        row.msgHash = entry.msgHash
        row.packed = entry.packed
        row.label = entry.label
        row.op = entry.op
        row.name = entry.name
        row.atMs = entry.atMs.map { Int($0) }
        row.toHex = entry.toHex
        row.seq = seq
    }

    /// Nil for a row of a kind this build does not know: it is left alone and never uploaded.
    static func entry(_ row: DistroOutboxEntity) -> OwedEntry? {
        guard let kind = OwedKind(rawValue: row.kind) else { return nil }
        return OwedEntry(id: row.id, kind: kind, distro: row.distro, distroKey: row.distroKey,
                         msgHash: row.msgHash, packed: row.packed, label: row.label,
                         op: row.op, name: row.name, atMs: row.atMs.map { Int64($0) }, toHex: row.toHex)
    }
}

/// The distro outbox's storage (OutboxStore) in SwiftData. The outbox keeps what
/// is owed in memory and this is its durable copy: read once at start, and
/// written by `put` when something is owed, `remove` when the node proves it or
/// it is owed no more, and `removeId` when a refused write must still take a
/// replaced message out.
///
/// Rows are ordered by `seq`, which only grows: a message owed under an id
/// already there replaces it and goes to the end, as the web's outbox does. A
/// write that fails (a full disk) returns false and says nothing here: the
/// outbox says it, and holds the entry for this run.
///
/// It has its own ModelContext, used only on its own serial queue (the main
/// context stays the UI's, and no disk write waits on the main thread:
/// DESIGN_PRINCIPLES §6).
nonisolated final class SwiftDataOutboxStore: OutboxStore, @unchecked Sendable {
    private let container: ModelContainer
    private let queue = DispatchQueue(label: "distro-outbox.store", qos: .utility)
    private var context: ModelContext?
    private var seq: Int?

    init(container: ModelContainer) {
        self.container = container
    }

    /// Runs `work` on the store's queue and hands its result back.
    private func onQueue<T>(_ work: @escaping @Sendable (SwiftDataOutboxStore) -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work(self)) }
        }
    }

    /// Only on `queue`.
    private func ctx() -> ModelContext {
        if let context { return context }
        let created = ModelContext(container)
        created.autosaveEnabled = false
        context = created
        return created
    }

    /// Only on `queue`: the next `seq`, from the highest one stored when first asked.
    private func nextSeq(_ ctx: ModelContext) -> Int {
        if seq == nil {
            var descriptor = FetchDescriptor<DistroOutboxEntity>(sortBy: [SortDescriptor(\.seq, order: .reverse)])
            descriptor.fetchLimit = 1
            seq = (try? ctx.fetch(descriptor))?.first?.seq ?? 0
        }
        seq! += 1
        return seq!
    }

    nonisolated(nonsending) func loadAll() async -> [OwedEntry] {
        await onQueue { store in
            let ctx = store.ctx()
            let rows = (try? ctx.fetch(FetchDescriptor<DistroOutboxEntity>(sortBy: [SortDescriptor(\.seq)]))) ?? []
            store.seq = rows.map(\.seq).max() ?? 0
            return rows.compactMap(DistroOutboxRows.entry)
        }
    }

    nonisolated(nonsending) func put(_ entry: OwedEntry) async -> Bool {
        await onQueue { store in
            let ctx = store.ctx()
            let id = entry.id
            let seq = store.nextSeq(ctx)
            do {
                if let row = try ctx.fetch(FetchDescriptor<DistroOutboxEntity>(predicate: #Predicate { $0.id == id })).first {
                    // The message under this id is replaced, in place, and goes to the end.
                    DistroOutboxRows.fill(row, from: entry, seq: seq)
                } else {
                    ctx.insert(DistroOutboxRows.row(entry, seq: seq))
                }
                try ctx.save()
                return true
            } catch {
                ctx.rollback()
                return false
            }
        }
    }

    nonisolated(nonsending) func remove(id: String, msgHash: String) async {
        await onQueue { store in
            let ctx = store.ctx()
            if let row = (try? ctx.fetch(FetchDescriptor<DistroOutboxEntity>(predicate: #Predicate { $0.id == id })))?.first,
               row.msgHash == msgHash {
                ctx.delete(row)
                try? ctx.save()
            }
        }
    }

    nonisolated(nonsending) func removeId(_ id: String) async throws {
        let failure: String? = await onQueue { store in
            let ctx = store.ctx()
            do {
                for row in try ctx.fetch(FetchDescriptor<DistroOutboxEntity>(predicate: #Predicate { $0.id == id })) {
                    ctx.delete(row)
                }
                try ctx.save()
                return nil
            } catch {
                ctx.rollback()
                return "\(error)"
            }
        }
        if let failure { throw OutboxStoreError(message: failure) }
    }
}

nonisolated struct OutboxStoreError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
