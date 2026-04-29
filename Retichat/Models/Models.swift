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
    var displayName: String
    var lastSeen: Double
    /// True when the contact was explicitly added by the user (via hash entry,
    /// QR scan, or group creation).  Nil/false for contacts auto-created from
    /// incoming messages.  Used by the "filter strangers" feature.
    /// Optional so lightweight CoreData migration can add this column to
    /// existing stores without a default value.
    var isAllowlisted: Bool?

    init(destHash: String, displayName: String = "", lastSeen: Double = 0,
         isAllowlisted: Bool? = nil) {
        self.destHash = destHash
        self.displayName = displayName
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
    var senderName: String
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
    var senderDisplayName: String = ""            // display name embedded by sender in blob
    var content: String
    var timestamp: Double                         // Unix ms
    var isOutgoing: Bool
    /// Same `DeliveryState` numeric values used by direct/group chat:
    /// 0=pending, 1=sent (= published to RFed), 3=failed.
    /// Default 1 (sent) so existing rows from before this column existed
    /// render with the previous “no indicator needed” behaviour.
    var deliveryState: Int = DeliveryState.sent

    init(id: String, channelHash: String, senderHash: String, senderDisplayName: String = "",
         content: String, timestamp: Double, isOutgoing: Bool = false,
         deliveryState: Int = DeliveryState.sent) {
        self.id = id
        self.channelHash = channelHash
        self.senderHash = senderHash
        self.senderDisplayName = senderDisplayName
        self.content = content
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.deliveryState = deliveryState
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
    var senderDisplayName: String  // embedded in blob at send time; stored once on receive
    var content: String
    var timestamp: Double
    var isOutgoing: Bool
    /// Mirrors the direct/group `DeliveryState` ints. For incoming
    /// messages this is always `delivered`; outgoing messages start at
    /// `pending`, transition to `sent` once RFed accepts the packet,
    /// and to `failed` if every retry path is exhausted.
    var deliveryState: Int = DeliveryState.delivered
}
