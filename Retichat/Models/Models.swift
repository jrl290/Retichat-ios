//
//  Models.swift
//  Retichat
//
//  Domain models mirroring the Android app's data layer.
//

import Foundation
import SwiftData

// MARK: - SwiftData Models

@Model
final class ContactEntity {
    @Attribute(.unique) var destHash: String
    /// The single name slot of builds before DISPLAY_NAMES.md (2026-09-27).
    /// Read once, by the §5.4 migration (ChatRepository
    /// .migrateLegacyContactNamesIfNeeded), and never written or shown
    /// after: the three slots below replace it.
    var displayName: String
    /// The user's own name for the contact (§5.1). nil = none; the rename
    /// UI clears it by saving an empty name.
    var localName: String?
    /// The name the contact sends in its messages, field 0xD1 (§5.1),
    /// accepted by the §5.2 rules.
    var messageName: String?
    /// The LXMF timestamp (seconds) of the message that last set or cleared
    /// messageName (§5.1, §5.2): only a newer message's 0xD1 counts. nil
    /// until one has (rows from before this rule). Optional, so SwiftData
    /// adds the column by lightweight migration.
    var messageNameAt: Double?
    /// The name in the contact's last announce (§5.1), cleaned, "Anonymous
    /// Peer" as none. Replaced on every announce.
    var announceName: String?
    var lastSeen: Double
    /// The privacy filter lets this peer through: the user added it, or
    /// created or accepted a group with it, or an invite from an allowed
    /// inviter listed it, or it accepted a group of ours. Nil/false for rows
    /// made for anyone else. Not the same as being a contact (isContact).
    /// Optional so lightweight CoreData migration can add this column to
    /// existing stores without a default value.
    var isAllowlisted: Bool?
    /// The user added this peer (Add Contact, New Conversation, a QR code or
    /// an lxma:// link; ChatRepository.createDirectChat): the row is listed
    /// in Contacts, New Chat and the New Group picker. false: a hidden row,
    /// kept for a group member's key or a sender's names and listed nowhere
    /// (James, 2026-10-02: contacts only when explicitly added). nil: a row
    /// from before the flag, listed as before, when allowlisted (no cleanup;
    /// ContactRows.isListed). Optional, so SwiftData adds the column by
    /// lightweight migration.
    var isContact: Bool?

    init(destHash: String, announceName: String? = nil, lastSeen: Double = 0,
         isAllowlisted: Bool? = nil, isContact: Bool = false) {
        self.destHash = destHash
        self.displayName = ""
        self.announceName = announceName
        self.lastSeen = lastSeen
        self.isAllowlisted = isAllowlisted
        self.isContact = isContact
    }
}

@Model
final class ChatEntity {
    @Attribute(.unique) var id: String
    var peerHash: String
    var lastMessageTime: Double
    var isArchived: Bool
    var isGroup: Bool
    var groupName: String?
    /// For group chats: "active" (full member) or "pending" (invite not yet accepted).
    /// Nil is treated as "active" for backward compatibility.
    var groupStatus: String?
    /// For group chats: the group's creator (32-hex `lxmf.delivery` hash), which a `status`
    /// counts from and which alone answers an accept with one (RFed-spec Group.md, "Member
    /// statuses and keys", 2026-10-06). This device's own hash for a group it creates, the
    /// invite's authenticated source for one it is invited into. Nil for every group held
    /// before it was recorded: such a group neither answers nor counts a status. A new
    /// optional attribute is a lightweight migration (tests/GroupStatusesMigrationTests.swift).
    var creatorHash: String?
    /// For group chats: the group's own address, the member the user acts as in it
    /// (GROUPS-DISTRO-DESIGN.md §8.1): the user's distro D for a group created here while D was
    /// held, admitted from an invite whose list names the D held then, or built from a group
    /// sync; nil for the device (every group held from before this change, and one whose list
    /// names the device but not D). A D-group is one whose own address is a distro (the current
    /// D or a former one): its sends are signed by D only, never by the device (§8.7). Pending or
    /// joined is read from this member's row alone (§9.2). A new optional attribute is a
    /// lightweight migration (tests/DistroGroupsMigrationTests.swift).
    var ownMember: String?
    /// For group chats: the GROUP_MEMBERS csv exactly as the invite carried it (or as this
    /// device wrote it into its invite chunks), which an `accept` or `create` group sync carries
    /// verbatim (§10.2). Nil for a group held from before this change.
    var membersCsv: String?

    init(id: String, peerHash: String, lastMessageTime: Double = 0,
         isArchived: Bool = false, isGroup: Bool = false, groupName: String? = nil,
         groupStatus: String? = nil, creatorHash: String? = nil, ownMember: String? = nil,
         membersCsv: String? = nil) {
        self.id = id
        self.peerHash = peerHash
        self.lastMessageTime = lastMessageTime
        self.isArchived = isArchived
        self.isGroup = isGroup
        self.groupName = groupName
        self.groupStatus = groupStatus
        self.creatorHash = creatorHash
        self.ownMember = ownMember
        self.membersCsv = membersCsv
    }
}

@Model
final class MessageEntity {
    @Attribute(.unique) var id: String  // message hash hex
    var chatId: String
    var senderHash: String
    var content: String
    var title: String
    var timestamp: Double
    var isOutgoing: Bool
    var deliveryState: Int  // 0=pending, 1=sent, 2=delivered, 3=failed
    var signatureValid: Bool
    var nativeHandle: UInt64  // Rust handle for tracking outbound state
    /// REACTIONS-DESIGN.md §6, all optional so a store from before them opens (lightweight
    /// migration). The message's LXMF hash, 64 hex, wherever it is known: the id already is the
    /// hash where it can be, but a Distro Fanout message and a Distro Sync of a send are filed
    /// under a derived id.
    var lxmfHash: String? = nil
    /// A Group post's id (GROUP_POST_ID, 32 hex): the target a Group reaction names. nil for a
    /// post from an older client, which offers no reactions.
    var postId: String? = nil
    /// The message's reactions: `{"<reactor 32 hex>": {"e": "👍", "t": <ms>}}`, `"e": ""` a
    /// removal (Reactions).
    var reactionsJson: String? = nil

    init(id: String, chatId: String, senderHash: String, content: String,
         title: String = "", timestamp: Double = 0, isOutgoing: Bool = false,
         deliveryState: Int = 0, signatureValid: Bool = false, nativeHandle: UInt64 = 0,
         lxmfHash: String? = nil, postId: String? = nil) {
        self.id = id
        self.chatId = chatId
        self.senderHash = senderHash
        self.content = content
        self.title = title
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.deliveryState = deliveryState
        self.signatureValid = signatureValid
        self.nativeHandle = nativeHandle
        self.lxmfHash = lxmfHash
        self.postId = postId
    }
}

@Model
final class AttachmentEntity {
    @Attribute(.unique) var id: String
    var messageId: String
    var filename: String
    var data: Data
    var mimeType: String

    init(id: String, messageId: String, filename: String, data: Data, mimeType: String = "") {
        self.id = id
        self.messageId = messageId
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
    }
}

@Model
final class GroupMemberEntity {
    var groupId: String
    var memberHash: String
    /// One of MemberStatus: "invited", "accepted", "left", "declined".
    /// Defaults to "accepted" so pre-migration records are treated as full members.
    var inviteStatus: String

    init(groupId: String, memberHash: String, inviteStatus: String = MemberStatus.accepted) {
        self.groupId = groupId
        self.memberHash = memberHash
        self.inviteStatus = inviteStatus
    }
}

@Model
final class InterfaceConfigEntity {
    @Attribute(.unique) var id: String
    /// One of `InterfaceKind.rawValue`: "TCPClient", "RNode", etc.
    var type: String
    var name: String
    var targetHost: String
    var targetPort: Int
    var enabled: Bool
    /// Optional JSON blob holding type-specific config (e.g. RNode radio
    /// parameters + remembered BLE peripheral). nil for plain TCP rows.
    /// Stored as a string so SwiftData can auto-migrate by adding a NULL
    /// column for existing records.
    var configJSON: String?

    init(id: String = UUID().uuidString, type: String, name: String,
         targetHost: String = "", targetPort: Int = 0, enabled: Bool = true,
         configJSON: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.enabled = enabled
        self.configJSON = configJSON
    }
}

/// Supported network interface kinds. Stored as the `type` column on
/// `InterfaceConfigEntity`.
enum InterfaceKind: String, CaseIterable, Identifiable {
    case tcpClient = "TCPClient"
    case rnode     = "RNode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tcpClient: return "TCP Client"
        case .rnode:     return "RNode (Bluetooth)"
        }
    }

    var symbolName: String {
        switch self {
        case .tcpClient: return "network"
        case .rnode:     return "antenna.radiowaves.left.and.right"
        }
    }

    var helpText: String {
        switch self {
        case .tcpClient: return "Connect to a Reticulum node over the internet."
        case .rnode:     return "Connect a LoRa radio over Bluetooth."
        }
    }
}

// MARK: - View Models (non-persistent)

struct Contact: Identifiable, Hashable {
    let id: String  // destHash
    var displayName: String
    var lastSeen: Double
}

struct Chat: Identifiable {
    let id: String
    var peerHash: String
    var displayName: String
    var lastMessage: String
    var lastMessageTime: Double
    var unreadCount: Int
    var isArchived: Bool
    var isGroup: Bool
    var groupName: String?
    /// "active" (full member), "pending" (awaiting accept/decline), or nil (treat as active).
    var groupStatus: String?
    /// A group whose own address is the user's distro D, current or former
    /// (GROUPS-DISTRO-DESIGN.md §8.1): its decline, leave and delete act on all the user's
    /// devices (§13).
    var isDistroGroup: Bool = false
    /// GROUPS-DISTRO-DESIGN.md §8.7 (James, 2026-10-11): the app is starting, or the distro this
    /// group uses is still being read: Accept, Decline, Leave and Delete are greyed, with no
    /// text, and a post waits as a DM does. Never "Delete from this device" then.
    var groupActionsWait: Bool = false
    /// §8.7: the group uses a distro address no longer on this device: this text, in a bar in
    /// place of the composer, Accept, Decline and Leave, with "Delete from this device". Nil
    /// otherwise.
    var formerDistroText: String? = nil

    var isPendingInvite: Bool { groupStatus == "pending" }
}

struct ChatMessage: Identifiable {
    let id: String
    var senderHash: String
    /// The sender's resolved label (DisplayNames), never a stored snapshot.
    var senderName: String
    /// Shown beside senderName in grey (DISPLAY_NAMES.md §5.3): in a channel,
    /// the poster's channel name beside the user's local name for them, or
    /// the short hash beside a channel name; else nil.
    var senderSecondary: String? = nil
    /// Whether senderSecondary is the short hash (set in monospace).
    var senderSecondaryIsHash: Bool = false
    var content: String
    var timestamp: Double
    var isOutgoing: Bool
    var deliveryState: Int
    var attachments: [Attachment]
    var uploadProgress: Float?
    var nativeHandle: UInt64 = 0
    /// REACTIONS-DESIGN.md §3, §7: the chips under the bubble, the stored JSON they come from
    /// (what a refresh compares), and whether reactions are offered on it (a target it can name:
    /// never on a channel post, a system message, a Group post without a post id, or a send not
    /// yet handed to the router).
    var reactions: [ReactionChip] = []
    var reactionsJson: String? = nil
    var reactable: Bool = false
}

/// One reaction chip under a bubble (Reactions.chips): a reaction, how many hold it, and whether
/// one of them is the user.
struct ReactionChip: Equatable, Identifiable {
    let emoji: String
    let count: Int
    let mine: Bool
    var id: String { emoji }
}

struct Attachment: Identifiable {
    let id: String
    var filename: String
    var data: Data
    var mimeType: String

    var isImage: Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ||
               lower.hasSuffix(".png") || lower.hasSuffix(".gif") ||
               lower.hasSuffix(".webp") || lower.hasSuffix(".heic")
    }
}

// MARK: - Delivery state

enum DeliveryState {
    static let pending = 0
    static let sent = 1
    static let delivered = 2
    static let failed = 3
    /// Direct delivery failed; message has been handed to a propagation node
    /// for store-and-forward delivery.
    static let propagating = 4
    /// A channel post waiting to be sent: no stack yet, or its rfed.link not
    /// up (back from the background, connections coming back). Shows the
    /// pending clock; sent when the stack starts or the link comes up
    /// (RfedChannelClient.queuePost, James 2026-10-19).
    static let queued = 5
}

// MARK: - Channel SwiftData Models

@Model
final class ChannelEntity {
    @Attribute(.unique) var channelHash: String  // 32-char hex (16 bytes)
    var channelName: String
    var rfedNodeHash: String                      // 32-char hex of rfed.channel dest
    var lastMessageTime: Double
    var isSubscribed: Bool
    var stampCost: Int?                           // PoW bits required by rfed; nil = disabled
    /// DISPLAY_NAMES.md §4.2, persisted: digest (hex, 16 bytes) of the
    /// Channel Display Name last included in a post here (the empty-name
    /// digest after a clear), and when (seconds). nil = never.
    var nameLastDigestHex: String?
    var nameLastIncludedAt: Double?

    init(channelHash: String, channelName: String, rfedNodeHash: String,
         lastMessageTime: Double = 0, isSubscribed: Bool = true, stampCost: Int? = nil) {
        self.channelHash = channelHash
        self.channelName = channelName
        self.rfedNodeHash = rfedNodeHash
        self.lastMessageTime = lastMessageTime
        self.isSubscribed = isSubscribed
        self.stampCost = stampCost
    }
}

@Model
final class ChannelMessageEntity {
    @Attribute(.unique) var id: String           // sender_hex+timestamp hex
    var channelHash: String
    var senderHash: String                        // 32-char hex (16 bytes)
    /// Unused: the pre-LXMF channel blob carried a name here. Names now
    /// live per (channel, sender) in ChannelSenderEntity (DISPLAY_NAMES.md
    /// §5.1) and are resolved when shown. Kept so existing stores load.
    var senderDisplayName: String = ""
    var content: String
    var timestamp: Double                         // Unix ms
    var isOutgoing: Bool
    /// Same `DeliveryState` numeric values used by direct/group chat:
    /// 0=pending, 1=sent (= published to RFed), 3=failed.
    /// Default 1 (sent) so existing rows from before this column existed
    /// render with the previous “no indicator needed” behaviour.
    var deliveryState: Int = DeliveryState.sent

    init(id: String, channelHash: String, senderHash: String,
         content: String, timestamp: Double, isOutgoing: Bool = false,
         deliveryState: Int = DeliveryState.sent) {
        self.id = id
        self.channelHash = channelHash
        self.senderHash = senderHash
        self.content = content
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.deliveryState = deliveryState
    }
}

/// One sender seen in one channel (DISPLAY_NAMES.md §4.2, §5.1): when this
/// device first saw them post there, and the Channel Display Name their
/// posts there carry. The name never becomes the contact's messageName.
@Model
final class ChannelSenderEntity {
    var channelHash: String                       // 32-char hex
    var senderHash: String                        // 32-char hex
    /// Local time (seconds) this sender was first seen posting here: rule 2
    /// of §4.2 includes the name when this is after the last inclusion.
    var firstSeenAt: Double
    /// From 0xD1 in this sender's posts here; nil = none (or cleared).
    var channelName: String?
    /// The post time (ms) of the post that last set or cleared channelName:
    /// an older post pulled later ("Load earlier messages") does not undo it.
    var channelNameAtMs: Double?

    init(channelHash: String, senderHash: String, firstSeenAt: Double) {
        self.channelHash = channelHash
        self.senderHash = senderHash
        self.firstSeenAt = firstSeenAt
    }
}

/// The channel send rule's persisted state (DISPLAY_NAMES.md §4.2), kept per
/// channel AND posting identity (RFed SPEC §17.12): a device that holds a
/// distro signs its channel posts as the distro, and readers have never had a
/// name from it, so the state is kept for each identity a device has posted as
/// (the `lxmf.delivery` hash the posts are signed with, `postingHash`) and a
/// new identity starts from none, never carrying the old one's over. The
/// digest (hex, 16 bytes) is that of the Channel Display Name last included in
/// a post as that identity (the empty-name digest after a clear), and the time
/// (seconds) when.
///
/// Until this entity the state was two columns of ChannelEntity
/// (nameLastDigestHex, nameLastIncludedAt), made when the device posted as
/// itself, the only posting identity then. Those columns stay where they are
/// and are the device's from the first time the device looks for its own state
/// (RfedChannelClient.adoptLegacyNameState moves them here and clears them),
/// as Android adopts its rows from before database 13. A new entity is a
/// lightweight migration: the store opens, and no message or channel is
/// touched (tests/DistroChannelsMigrationTests.swift opens a store written
/// by the previous build).
@Model
final class ChannelNameStateEntity {
    /// "<channelHash>|<postingHash>", the one row per channel and identity.
    @Attribute(.unique) var key: String
    var channelHash: String                       // 32-char hex
    var postingHash: String                       // 32-char hex
    var lastDigestHex: String
    var lastIncludedAt: Double

    init(channelHash: String, postingHash: String, lastDigestHex: String, lastIncludedAt: Double) {
        self.key = Self.key(channelHash: channelHash, postingHash: postingHash)
        self.channelHash = channelHash
        self.postingHash = postingHash
        self.lastDigestHex = lastDigestHex
        self.lastIncludedAt = lastIncludedAt
    }

    static func key(channelHash: String, postingHash: String) -> String { "\(channelHash)|\(postingHash)" }
}

/// RFed SPEC §17.12 rule 5's record: per channel, the last membership action
/// (`op`, "join" or "leave") this device made or applied, with its time
/// (`atMs`, the action's own milliseconds since the epoch). Persisted, and
/// kept after a leave: a leave's record is what stops an older join from
/// coming back. Written for every join and leave the user makes here, whether
/// or not the device holds a distro.
@Model
final class ChannelMembershipEntity {
    @Attribute(.unique) var channelHash: String   // 32-char hex
    var op: String
    var atMs: Int

    init(channelHash: String, op: String, atMs: Int) {
        self.channelHash = channelHash
        self.op = op
        self.atMs = atMs
    }
}

/// One message this device owes its distro (RFed SPEC §17.12 "On the sending
/// device", §17.11): kept here until the propagation node proves the upload.
/// `id` is `channel:<channel hash>` for a membership message (one per
/// channel: a later action replaces it) or `sent:<LXMF message hash>` for a
/// sent copy. `packed` is the LXMF message as the distro packed and signed it
/// when the user acted, never packed again; `msgHash` is its LXMF message
/// hash, which is what tells one message from another under the same `id`.
/// `distro` is the distro's `lxmf.delivery` hash and `distroKey` its public key
/// (hex), so a sent copy is still encrypted to its own distro after the device
/// gives that distro up. A channel entry adds `op`, `name` and `atMs`; a sent
/// entry adds `toHex`. `seq` orders what is owed, oldest first. `sealed` and
/// `syncSig` are the message sealed for the distro sync proof and D's signature
/// over it (RFed SPEC §17.13; DISTRO-SYNC-PROOF-DESIGN.md §5.1), made once in the
/// write that owes it, for both kinds; nil on a row owed before they existed, which
/// is built the legacy way. Optional attributes with no default store value: a
/// store written before them opens by SwiftData's lightweight migration, its rows
/// with both nil (tests/DistroSyncMigrationTests.swift). Retichat-android's
/// `distro_outbox` table, field for field.
@Model
final class DistroOutboxEntity {
    @Attribute(.unique) var id: String
    var kind: String                              // "channel" | "sent" | "group"
    var distro: String
    var distroKey: String
    var msgHash: String
    var packed: Data
    var label: String
    var op: String?
    var name: String?
    var atMs: Int?
    var toHex: String?
    var seq: Int
    var sealed: Data?
    var syncSig: Data?

    init(id: String, kind: String, distro: String, distroKey: String, msgHash: String, packed: Data,
         label: String, op: String? = nil, name: String? = nil, atMs: Int? = nil, toHex: String? = nil,
         seq: Int, sealed: Data? = nil, syncSig: Data? = nil) {
        self.id = id
        self.kind = kind
        self.distro = distro
        self.distroKey = distroKey
        self.msgHash = msgHash
        self.packed = packed
        self.label = label
        self.op = op
        self.name = name
        self.atMs = atMs
        self.toHex = toHex
        self.seq = seq
        self.sealed = sealed
        self.syncSig = syncSig
    }
}

/// The creator's copy of a member's newest accept or leave that counted (RFed-spec Group.md,
/// "Member statuses and keys", 2026-10-06): the packed LXMF message exactly as received
/// (destination, source, signature, payload), which the creator passes on as an element of a
/// `status`. One row per group and member, the newest replacing it, kept only by the group's
/// creator. `key` is "<groupId>|<memberHash>". Retichat-android's `group_statuses` table.
@Model
final class GroupStatusCopyEntity {
    @Attribute(.unique) var key: String
    var groupId: String
    var memberHash: String
    var action: String                            // "accept" | "leave"
    var packed: Data

    init(groupId: String, memberHash: String, action: String, packed: Data) {
        self.key = Self.key(groupId: groupId, memberHash: memberHash)
        self.groupId = groupId
        self.memberHash = memberHash
        self.action = action
        self.packed = packed
    }

    static func key(groupId: String, memberHash: String) -> String { "\(groupId)|\(memberHash)" }
}

/// An accept or leave held until its sender's key is here (RFed-spec Group.md, "Verifying an
/// accept or leave": from the switch around 2026-10-26 an unverifiable one is held, not
/// counted): `packed` is the message as received, the bytes its signature covers, decided
/// once the key arrives. `msgHash` (the LXMF message hash) is its identity; `seq` orders
/// them, oldest first. Bounded (4 a member, 128 in all) and released with its group.
/// Retichat-android's `group_held` table.
@Model
final class GroupHeldEntity {
    @Attribute(.unique) var msgHash: String
    var groupId: String
    var srcHash: String
    var action: String                            // "accept" | "leave"
    var packed: Data
    var seq: Int

    init(msgHash: String, groupId: String, srcHash: String, action: String, packed: Data, seq: Int) {
        self.msgHash = msgHash
        self.groupId = groupId
        self.srcHash = srcHash
        self.action = action
        self.packed = packed
        self.seq = seq
    }
}

/// A group message that reached the user's distro D for a group not joined here yet, kept as
/// the fan-out blob it arrived as until the group is joined, then fed to the distro path again
/// in arrival order (GROUPS-DISTRO-DESIGN.md §6.5, "Held arrivals"): a creator's status, a
/// member's accept or post, a `post` group sync. Never recorded as seen while held. `key` is
/// the LXMF hash with the signature (or, when the unwrap gives none, whether it validated): the
/// pair the store deduplicates on. `distro` is the D it arrived for: forgotten when the device
/// gives D up. Bounded (HeldArrivals) by count and bytes, never by a clock. Client-local:
/// nothing about it is on the wire.
@Model
final class GroupHeldArrivalEntity {
    @Attribute(.unique) var key: String
    var groupId: String
    var srcHash: String
    var msgHash: String
    var signature: Data?
    var validated: Bool
    /// False for a `post` group sync (source D): it counts only against its group.
    var countsAgainstSource: Bool
    var distro: String
    var blob: Data
    var size: Int
    var seq: Int

    init(key: String, groupId: String, srcHash: String, msgHash: String, signature: Data?, validated: Bool,
         countsAgainstSource: Bool, distro: String, blob: Data, seq: Int) {
        self.key = key
        self.groupId = groupId
        self.srcHash = srcHash
        self.msgHash = msgHash
        self.signature = signature
        self.validated = validated
        self.countsAgainstSource = countsAgainstSource
        self.distro = distro
        self.blob = blob
        self.size = blob.count
        self.seq = seq
    }
}

// MARK: - Channel View Models

struct Channel: Identifiable, Hashable {
    let id: String          // channelHash hex
    var channelName: String
    var rfedNodeHash: String
    var lastMessageTime: Double
    var isSubscribed: Bool
    var stampCost: Int?     // nil = no stamp required
}

struct ChannelMessage: Identifiable {
    let id: String
    var channelHash: String
    var senderHash: String
    var content: String
    var timestamp: Double
    var isOutgoing: Bool
    /// Mirrors the direct/group `DeliveryState` ints. For incoming
    /// messages this is always `delivered`; outgoing messages start at
    /// `pending`, transition to `sent` once RFed accepts the packet,
    /// and to `failed` if every retry path is exhausted.
    var deliveryState: Int = DeliveryState.delivered
}
