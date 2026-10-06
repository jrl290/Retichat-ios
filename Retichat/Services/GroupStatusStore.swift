//
//  GroupStatusStore.swift
//  Retichat
//
//  What GroupStatusEngine keeps and changes, over SwiftData (RFed-spec Group.md,
//  "Member statuses and keys", 2026-10-06): the group rows ChatRepository
//  already holds (ChatEntity, GroupMemberEntity), the creator's copy of each
//  member's newest counted accept or leave (GroupStatusCopyEntity), and the
//  accepts and leaves held until their sender's key is here (GroupHeldEntity).
//  Retichat-android's RoomGroupStatusStore and GroupStatusDao.
//
//  It runs on the main actor with the main context, as every group handler does
//  (the engine never suspends, so one event runs to completion before the next).
//  What only ChatRepository can do (let a member through the privacy filter,
//  watch a member's announces, write the system line about a member) it is
//  handed as closures.
//

import Foundation
import SwiftData

@MainActor
final class SwiftDataGroupStatusStore: GroupStatusStore {
    private let context: () -> ModelContext?
    private let allowMember: (String) -> Void
    private let watchMember: (_ memberHex: String, _ watch: Bool) -> Void
    private let line: (_ chatId: String, _ memberHex: String, _ joined: Bool, _ id: String, _ timestamp: Double) -> Void

    init(context: @escaping () -> ModelContext?,
         allowMember: @escaping (String) -> Void,
         watchMember: @escaping (_ memberHex: String, _ watch: Bool) -> Void,
         line: @escaping (_ chatId: String, _ memberHex: String, _ joined: Bool, _ id: String, _ timestamp: Double) -> Void) {
        self.context = context
        self.allowMember = allowMember
        self.watchMember = watchMember
        self.line = line
    }

    // MARK: The group

    func chat(id groupId: String) -> GroupChatInfo? {
        guard let ctx = context(),
              let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(
                predicate: #Predicate { $0.id == groupId && $0.isGroup == true })).first
        else { return nil }
        return GroupChatInfo(id: chat.id, creatorHex: chat.creatorHash, groupStatus: chat.groupStatus)
    }

    func members(chatId: String) -> [GroupMemberStatuses.Row] {
        guard let ctx = context() else { return [] }
        let rows = (try? ctx.fetch(FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == chatId }))) ?? []
        return rows.map { (hash: $0.memberHash, status: $0.inviteStatus) }
    }

    func setMemberStatus(chatId: String, memberHex: String, status: String) {
        guard let ctx = context() else { return }
        let rows = (try? ctx.fetch(FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == chatId && $0.memberHash == memberHex }))) ?? []
        for row in rows { row.inviteStatus = status }
        try? ctx.save()
        watchMember(memberHex, status == MemberStatus.accepted)
    }

    func memberLine(chatId: String, memberHex: String, joined: Bool, id: String, timestamp: Double) {
        line(chatId, memberHex, joined, id, timestamp)
    }

    func allow(memberHex: String) { allowMember(memberHex) }

    // MARK: The creator's copies

    func copy(chatId: String, memberHex: String) -> StatusCopy? {
        guard let ctx = context() else { return nil }
        let key = GroupStatusCopyEntity.key(groupId: chatId, memberHash: memberHex)
        guard let row = try? ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>(
            predicate: #Predicate { $0.key == key })).first else { return nil }
        return StatusCopy(memberHex: row.memberHash, action: row.action, packed: row.packed)
    }

    func putCopy(chatId: String, memberHex: String, action: String, packed: Data) {
        guard let ctx = context() else { return }
        let key = GroupStatusCopyEntity.key(groupId: chatId, memberHash: memberHex)
        if let row = try? ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>(
            predicate: #Predicate { $0.key == key })).first {
            row.action = action
            row.packed = packed
        } else {
            ctx.insert(GroupStatusCopyEntity(groupId: chatId, memberHash: memberHex, action: action, packed: packed))
        }
        try? ctx.save()
    }

    func copies(chatId: String) -> [StatusCopy] {
        guard let ctx = context() else { return [] }
        let rows = (try? ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>(
            predicate: #Predicate { $0.groupId == chatId }))) ?? []
        return rows.map { StatusCopy(memberHex: $0.memberHash, action: $0.action, packed: $0.packed) }
    }

    // MARK: Held until a key is here

    func held() -> [HeldEntry] {
        guard let ctx = context() else { return [] }
        let rows = (try? ctx.fetch(FetchDescriptor<GroupHeldEntity>(sortBy: [SortDescriptor(\.seq)]))) ?? []
        return rows.map {
            HeldEntry(chatId: $0.groupId, srcHex: $0.srcHash, action: $0.action, msgHash: $0.msgHash, packed: $0.packed)
        }
    }

    func heldCount() -> Int {
        guard let ctx = context() else { return 0 }
        return (try? ctx.fetchCount(FetchDescriptor<GroupHeldEntity>())) ?? 0
    }

    func heldCount(chatId: String, srcHex: String) -> Int {
        guard let ctx = context() else { return 0 }
        return (try? ctx.fetchCount(FetchDescriptor<GroupHeldEntity>(
            predicate: #Predicate { $0.groupId == chatId && $0.srcHash == srcHex }))) ?? 0
    }

    func heldCount(srcHex: String) -> Int {
        guard let ctx = context() else { return 0 }
        return (try? ctx.fetchCount(FetchDescriptor<GroupHeldEntity>(
            predicate: #Predicate { $0.srcHash == srcHex }))) ?? 0
    }

    func isHeld(msgHash: String) -> Bool {
        guard let ctx = context() else { return false }
        return ((try? ctx.fetchCount(FetchDescriptor<GroupHeldEntity>(
            predicate: #Predicate { $0.msgHash == msgHash }))) ?? 0) > 0
    }

    func hold(_ entry: HeldEntry) {
        guard let ctx = context() else { return }
        var newest = FetchDescriptor<GroupHeldEntity>(sortBy: [SortDescriptor(\.seq, order: .reverse)])
        newest.fetchLimit = 1
        let seq = ((try? ctx.fetch(newest))?.first?.seq ?? 0) + 1
        ctx.insert(GroupHeldEntity(msgHash: entry.msgHash, groupId: entry.chatId, srcHash: entry.srcHex,
                                   action: entry.action, packed: entry.packed, seq: seq))
        try? ctx.save()
    }

    func release(_ entry: HeldEntry) {
        guard let ctx = context() else { return }
        let hash = entry.msgHash
        for row in (try? ctx.fetch(FetchDescriptor<GroupHeldEntity>(predicate: #Predicate { $0.msgHash == hash }))) ?? [] {
            ctx.delete(row)
        }
        try? ctx.save()
    }

    // MARK: A group goes

    /// The creator's copies and the entries held for a key go with their group. Saved by the caller.
    static func deleteRows(groupId: String, in ctx: ModelContext) {
        for row in (try? ctx.fetch(FetchDescriptor<GroupStatusCopyEntity>(
            predicate: #Predicate { $0.groupId == groupId }))) ?? [] { ctx.delete(row) }
        for row in (try? ctx.fetch(FetchDescriptor<GroupHeldEntity>(
            predicate: #Predicate { $0.groupId == groupId }))) ?? [] { ctx.delete(row) }
    }
}
