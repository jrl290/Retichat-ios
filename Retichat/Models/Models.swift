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
    /// The name in the contact's last announce (§5.1), cleaned, "Anonymous
    /// Peer" as none. Replaced on every announce.
    var announceName: String?
    var lastSeen: Double
    /// True when the contact was explicitly added by the user (via hash entry,
    /// QR scan, or group creation).  Nil/false for contacts auto-created from
    /// incoming messages.  Used by the "filter strangers" feature.
    /// Optional so lightweight CoreData migration can add this column to
    /// existing stores without a default value.
    var isAllowlisted: Bool?

    init(destHash: String, announceName: String? = nil, lastSeen: Double = 0,
         isAllowlisted: Bool? = nil) {
        self.destHash = destHash
        self.displayName = ""
        self.announceName = announceName
        self.lastSeen = lastSeen
        self.isAllowlisted = isAllowlisted
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

    init(id: String, peerHash: String, lastMessageTime: Double = 0,
         isArchived: Bool = false, isGroup: Bool = false, groupName: String? = nil,
         groupStatus: String? = nil) {
        self.id = id
        self.peerHash = peerHash
        self.lastMessageTime = lastMessageTime
        self.isArchived = isArchived
        self.isGroup = isGroup
        self.groupName = groupName
        self.groupStatus = groupStatus
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

    init(id: String, chatId: String, senderHash: String, content: String,
         title: String = "", timestamp: Double = 0, isOutgoing: Bool = false,
         deliveryState: Int = 0, signatureValid: Bool = false, nativeHandle: UInt64 = 0) {
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

    var isPendingInvite: Bool { groupStatus == "pending" }
}

struct ChatMessage: Identifiable {
    let id: String
    var senderHash: String
    /// The sender's resolved label (DisplayNames), never a stored snapshot.
    var senderName: String
    /// Shown beside senderName: the 8-hex short hash when the label is a
    /// channel name (DISPLAY_NAMES.md §5.3), else nil.
    var senderSecondary: String? = nil
    var content: String
    var timestamp: Double
    var isOutgoing: Bool
    var deliveryState: Int
    var attachments: [Attachment]
    var uploadProgress: Float?
    var nativeHandle: UInt64 = 0
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
