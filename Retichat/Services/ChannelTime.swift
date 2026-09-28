//
//  ChannelTime.swift
//  Retichat
//
//  The one conversion between a channel post's wire timestamp and the
//  seconds a Channel's lastMessageTime holds. Foundation only, so
//  tests/ChannelLastMessageTimeTests.swift runs it as it is.
//

import Foundation

enum ChannelTime {
    /// A post carries its LXMF timestamp in milliseconds on the wire
    /// (ChannelLxmPackResult / ChannelLxmUnpackResult.timestampMs); a
    /// Channel's lastMessageTime is seconds since 1970, like
    /// Chat.lastMessageTime, which the chat list sorts it against and
    /// formats with Date(timeIntervalSince1970:). Passing the milliseconds
    /// straight through put a post made today in the year 58,000 ("Jun 30").
    static func lastMessageSeconds(postMs: UInt64) -> Double {
        Double(postMs) / 1000.0
    }

    /// Anything above this cannot be a seconds-epoch time (it is the year
    /// 5138), so a stored value above it was written in milliseconds.
    static let millisecondFloor: Double = 1e11

    /// A stored lastMessageTime in seconds: rows written in milliseconds
    /// (before the unit switch, and by the send path until 2026-09-27) are
    /// divided once; a seconds value comes back unchanged, so applying it
    /// on every load is idempotent.
    static func normalizedStoredSeconds(_ raw: Double) -> Double {
        raw > millisecondFloor ? raw / 1000.0 : raw
    }
}
