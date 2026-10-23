//
//  NotificationIds.swift
//  Retichat
//
//  One notification per message (RFed-spec Notify.md "One notification per
//  message"; James, 2026-10-23: "include the message id in the notify packet
//  so that we can dedup notifications"). An RFed wake names the stored item
//  by its transient id, and apns-bridge sends that id, in hex, as the push's
//  apns-collapse-id: the identifier iOS gives the push's notification
//  request. The app posts its own notification for the message under the
//  same identifier, so a push, a mesh wake and the message itself make one
//  notification, not one each.
//
//  Pure (no UIKit, no FFI), so tests/NotificationIdsTests.swift can check it.
//

import CryptoKit
import Foundation

nonisolated enum NotificationIds {
    /// The transient id RFed names `bytes` by in a wake: SHA-256 of a distro
    /// blob (a bare LXMF message to the distro), or of a channel's hash and
    /// its post. A synced LXMF message's comes from the router
    /// (LXMF-rust lxmf_propagation), which holds the encrypted bytes.
    static func transientId(of bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    /// The notification request's identifier: the message's 32-byte
    /// transient id in lowercase hex, as apns-bridge writes the collapse id.
    /// Without one, a fresh identifier, as before.
    static func requestIdentifier(messageId: Data?) -> String {
        guard let messageId, messageId.count == 32 else { return UUID().uuidString }
        return messageId.map { String(format: "%02x", $0) }.joined()
    }
}
