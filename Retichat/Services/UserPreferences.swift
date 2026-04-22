//
//  UserPreferences.swift
//  Retichat
//
//  UserDefaults wrapper mirroring Android SharedPreferences.
//

import Foundation

final class UserPreferences {
    static let shared = UserPreferences()

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

    /// 32-char hex public identity hash of the RFed node.
    /// Capability destination hashes (rfed.notify, rfed.channel, rfed.delivery,
    /// lxmf.propagation) are derived automatically from this value.
    var rfedNodeIdentityHash: String {
        get { defaults.string(forKey: Keys.rfedNodeIdentityHash) ?? "" }
        set { defaults.set(newValue, forKey: Keys.rfedNodeIdentityHash) }
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
}
