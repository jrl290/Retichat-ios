//
//  UserPreferences.swift
//  Retichat
//
//  UserDefaults wrapper mirroring Android SharedPreferences.
//

import Foundation
import CryptoKit

final class UserPreferences {
    static let shared = UserPreferences()
    private static let hiddenDefaultRfedNodeIdentityHash = "7e5ff856dc2aa0fbc9fc8831b62d2834"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let displayName = "display_name"
        static let channelDisplayName = "channel_display_name"
        static let dropAnnounces = "drop_announces"
        static let identityPath = "identity_path"
        static let rfedNotifyHash = "rfed_notify_hash"
        static let apnsDeviceToken = "apns_device_token"
        static let lxmfPropagationHash = "lxmf_propagation_hash"
        static let rfedNodeIdentityHash = "rfed_node_identity_hash"
        static let rfedLxmfPropOverride = "rfed_lxmf_prop_override"
        static let filterStrangers = "filter_strangers"
        static let mutedChatIds = "muted_chat_ids"
        static let channelNotificationsOn = "channel_notifications_on"
        static let channelPushEnabled = "channel_push_enabled"
        static let channelLastOpened = "channel_last_opened"
    }

    var displayName: String {
        get { defaults.string(forKey: Keys.displayName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.displayName) }
    }

    /// Display name embedded in outgoing channel messages.
    /// If empty, falls back to `displayName`. Stored once by the sender;
    /// receivers see whatever name was in the message when it arrived.
    var channelDisplayName: String {
        get { defaults.string(forKey: Keys.channelDisplayName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.channelDisplayName) }
    }

    var dropAnnounces: Bool {
        get { defaults.object(forKey: Keys.dropAnnounces) != nil ? defaults.bool(forKey: Keys.dropAnnounces) : true }
        set { defaults.set(newValue, forKey: Keys.dropAnnounces) }
    }

    var identityPath: String? {
        get { defaults.string(forKey: Keys.identityPath) }
        set { defaults.set(newValue, forKey: Keys.identityPath) }
    }

    /// 32-char hex destination hash of the rfed.notify destination.
    /// Used to register this device's notify relay with the rfed server.
    /// Leave empty to disable rfed notify registration.
    var rfedNotifyHash: String {
        get { defaults.string(forKey: Keys.rfedNotifyHash) ?? "" }
        set { defaults.set(newValue, forKey: Keys.rfedNotifyHash) }
    }

    /// Runtime RFed notify destination.
    /// Falls back to the app's hidden default RFed node when no explicit
    /// value has been saved in Settings.
    var effectiveRfedNotifyHash: String {
        let configured = Self.normalizedHex(rfedNotifyHash)
        if !configured.isEmpty { return configured }
        return Self.rnsDestHash(identityHashHex: effectiveRfedNodeIdentityHash,
                                app: "rfed", aspects: ["notify"]) ?? ""
    }



    /// Last known APNs device token (hex string). Stored for re-registration on launch.
    var apnsDeviceToken: String {
        get { defaults.string(forKey: Keys.apnsDeviceToken) ?? "" }
        set { defaults.set(newValue, forKey: Keys.apnsDeviceToken) }
    }

    /// 32-char hex destination hash of a preferred LXMF propagation node.
    /// When non-empty it is tried first on every poll cycle; falls back to
    /// the built-in rotated pool on failure.  Leave empty to use the pool.
    var lxmfPropagationHash: String {
        get { defaults.string(forKey: Keys.lxmfPropagationHash) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lxmfPropagationHash) }
    }

    /// Runtime LXMF propagation destination.
    /// When the override field is blank, derive from the effective RFed node.
    var effectiveLxmfPropagationHash: String {
        let configured = Self.normalizedHex(lxmfPropagationHash)
        if !configured.isEmpty { return configured }
        return Self.rnsDestHash(identityHashHex: effectiveRfedNodeIdentityHash,
                                app: "lxmf", aspects: ["propagation"]) ?? ""
    }

    /// 32-char hex public identity hash of the RFed node.
    /// Capability destination hashes (rfed.notify, rfed.channel, rfed.delivery,
    /// lxmf.propagation) are derived automatically from this value.
    var rfedNodeIdentityHash: String {
        get { defaults.string(forKey: Keys.rfedNodeIdentityHash) ?? "" }
        set { defaults.set(newValue, forKey: Keys.rfedNodeIdentityHash) }
    }

    /// Runtime RFed identity hash.
    /// Uses the hidden fallback only when Settings is blank.
    var effectiveRfedNodeIdentityHash: String {
        let configured = Self.normalizedHex(rfedNodeIdentityHash)
        if !configured.isEmpty { return configured }
        return Self.hiddenDefaultRfedNodeIdentityHash
    }

    /// Optional override for the LXMF propagation hash.
    /// When empty, the lxmf.propagation hash is derived from rfedNodeIdentityHash.
    var rfedLxmfPropOverride: String {
        get { defaults.string(forKey: Keys.rfedLxmfPropOverride) ?? "" }
        set { defaults.set(newValue, forKey: Keys.rfedLxmfPropOverride) }
    }

    /// When true, incoming messages from senders not in the contact allowlist
    /// are silently dropped.  Contacts are allowlisted when explicitly added
    /// via "New Chat" or QR scan.  Defaults to true (block strangers).
    var filterStrangers: Bool {
        get { defaults.object(forKey: Keys.filterStrangers) != nil ? defaults.bool(forKey: Keys.filterStrangers) : true }
        set { defaults.set(newValue, forKey: Keys.filterStrangers) }
    }

    /// Set of chat IDs for which notifications are silenced by the user.
    var mutedChatIds: Set<String> {
        get {
            let arr = defaults.stringArray(forKey: Keys.mutedChatIds) ?? []
            return Set(arr)
        }
        set { defaults.set(Array(newValue), forKey: Keys.mutedChatIds) }
    }

    func muteChat(_ chatId: String) {
        var ids = mutedChatIds
        ids.insert(chatId)
        mutedChatIds = ids
    }

    func unmuteChat(_ chatId: String) {
        var ids = mutedChatIds
        ids.remove(chatId)
        mutedChatIds = ids
    }

    func isChatMuted(_ chatId: String) -> Bool {
        mutedChatIds.contains(chatId)
    }

    /// Set of channel IDs for which notifications are enabled.
    /// Channels are opt-in (default off); add a channel ID here to enable notifications.
    var channelNotificationsOn: Set<String> {
        get {
            let arr = defaults.stringArray(forKey: Keys.channelNotificationsOn) ?? []
            return Set(arr)
        }
        set { defaults.set(Array(newValue), forKey: Keys.channelNotificationsOn) }
    }

    func enableChannelNotifications(_ channelId: String) {
        var ids = channelNotificationsOn
        ids.insert(channelId)
        channelNotificationsOn = ids
    }

    func disableChannelNotifications(_ channelId: String) {
        var ids = channelNotificationsOn
        ids.remove(channelId)
        channelNotificationsOn = ids
    }

    func isChannelNotificationsEnabled(_ channelId: String) -> Bool {
        channelNotificationsOn.contains(channelId)
    }

    /// Set of channel IDs for which push wakeups are enabled.
    /// When enabled, the device registers with rfed.notify so a silent push is fired
    /// for every new channel message (waking the app to pull it).
    /// Defaults to ON when a channel is joined.
    var channelPushEnabled: Set<String> {
        get {
            let arr = defaults.stringArray(forKey: Keys.channelPushEnabled) ?? []
            return Set(arr)
        }
        set { defaults.set(Array(newValue), forKey: Keys.channelPushEnabled) }
    }

    func enableChannelPush(_ channelId: String) {
        var ids = channelPushEnabled
        ids.insert(channelId)
        channelPushEnabled = ids
    }

    func disableChannelPush(_ channelId: String) {
        var ids = channelPushEnabled
        ids.remove(channelId)
        channelPushEnabled = ids
    }

    func isChannelPushEnabled(_ channelId: String) -> Bool {
        channelPushEnabled.contains(channelId)
    }

    /// Per-channel "last opened" timestamp in **seconds** (Apple epoch).
    /// Used by `ChatListView` as the channel sort key so channels only
    /// bubble to the top when the user actually opens them — incoming
    /// channel traffic does *not* reorder the list.  Channels never
    /// opened on this device sit at the bottom (timestamp 0).
    var channelLastOpened: [String: Double] {
        get {
            let raw = defaults.dictionary(forKey: Keys.channelLastOpened) as? [String: Double] ?? [:]
            // Migrate legacy ms-encoded values written before the unit switch.
            // Anything > 1e11 cannot be a seconds-epoch value (year 5138+).
            var migrated = raw
            var changed = false
            for (k, v) in raw where v > 1e11 {
                migrated[k] = v / 1000.0
                changed = true
            }
            if changed {
                defaults.set(migrated, forKey: Keys.channelLastOpened)
            }
            return migrated
        }
        set { defaults.set(newValue, forKey: Keys.channelLastOpened) }
    }

    func channelLastOpenedTime(_ channelId: String) -> Double {
        channelLastOpened[channelId] ?? 0
    }

    func markChannelOpened(_ channelId: String, at time: Double = Date().timeIntervalSince1970) {
        var map = channelLastOpened
        map[channelId] = time
        channelLastOpened = map
    }

    private static func normalizedHex(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func rnsDestHash(identityHashHex: String, app: String, aspects: [String]) -> String? {
        let hex = normalizedHex(identityHashHex)
        guard hex.count == 32, let identityBytes = Data(hexString: hex) else { return nil }
        let name = ([app] + aspects).joined(separator: ".")
        let nameHashFull = SHA256.hash(data: Data(name.utf8))
        let nameHashTrunc = Data(nameHashFull.prefix(10))
        let material = nameHashTrunc + identityBytes
        let destHashFull = SHA256.hash(data: material)
        return Data(destHashFull.prefix(16)).hexString
    }
}
