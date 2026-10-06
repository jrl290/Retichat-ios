//
//  GroupEnvelopes.swift
//  Retichat
//
//  The group entries of the control envelopes this device sends, apart from the
//  native message they are written on, so tests/GroupStatusesTests.swift can check
//  exactly what each one carries in both forms (RFed-spec Group.md, "Member
//  statuses and keys", James 2026-10-06; DISPLAY_NAMES.md §10). Retichat-android's
//  GroupEnvelopes.
//
//   - An accept and a leave (a decline is the very same message as a leave: James,
//     2026-10-02) carry exactly the sender's own key as GROUP_MEMBER_KEYS: one
//     `hash:base64-public-key` entry, in the form an invite chunk uses, in the old
//     field 0xA8 until the switch (RetichatField.groupEntriesInRetichatField) and in
//     key 9 of the Retichat field after it. A receiver that never heard of the
//     sender binds it and verifies the message by it.
//   - A status (the creator's answer to an accept) carries GROUP_ID, GROUP_ACTION
//     `status` and GROUP_SENDER the creator. Its GROUP_STATUSES (key 10) is written
//     by RetichatBridge.messageSetRetichatStatuses, which has no old field.
//
//  GroupChatManager writes these and nothing else for these three envelopes.
//

import Foundation

nonisolated enum GroupEnvelopes {
    /// One str entry of an envelope.
    struct Entry: Equatable {
        let entry: GroupEntry
        let value: String
    }

    /// The user's own GROUP_MEMBER_KEYS entry: `selfHex` and the 64-byte `publicKey`.
    static func ownKeyEntry(selfHex: String, publicKey: Data) -> String {
        GroupStatuses.keyEntry(hashHex: selfHex, publicKey: publicKey)
    }

    /// GROUP_ID, GROUP_ACTION `accept`, GROUP_SENDER `selfHex` and, last, the user's own key
    /// (`ownKey`, nil only when the identity's key cannot be read: then the message goes without
    /// it, as a build from before this change sends it, rather than not at all).
    static func accept(groupId: String, selfHex: String, ownKey: String?) -> [Entry] {
        control(groupId, GroupAction.accept, selfHex, ownKey)
    }

    /// As `accept`, for a leave, which a decline is too.
    static func leave(groupId: String, selfHex: String, ownKey: String?) -> [Entry] {
        control(groupId, GroupAction.leave, selfHex, ownKey)
    }

    /// GROUP_ID, GROUP_ACTION `status` and GROUP_SENDER the creator `selfHex`.
    static func status(groupId: String, selfHex: String) -> [Entry] {
        [Entry(entry: .id, value: groupId),
         Entry(entry: .action, value: GroupAction.status),
         Entry(entry: .sender, value: selfHex)]
    }

    private static func control(_ groupId: String, _ action: String, _ selfHex: String, _ ownKey: String?) -> [Entry] {
        var entries = [Entry(entry: .id, value: groupId),
                       Entry(entry: .action, value: action),
                       Entry(entry: .sender, value: selfHex)]
        if let ownKey { entries.append(Entry(entry: .memberKeys, value: ownKey)) }
        return entries
    }

    /// Where each of `entries` is written, in the form `inRetichatField` selects (the switch).
    static func writes(_ entries: [Entry],
                       inRetichatField: Bool = RetichatField.groupEntriesInRetichatField) -> [GroupFieldWrite] {
        entries.compactMap { GroupFieldWrite.of($0.entry, .str($0.value), inRetichatField: inRetichatField) }
    }
}
