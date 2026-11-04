//
//  ChannelActivity.swift
//  Retichat
//
//  When each channel was last active, which places it in the chat list
//  (James, 2026-11-03: "I want the Channel chat to be open and a message be
//  sent or received before moving it to the top of the chat list"). The
//  times are seconds (Apple epoch) keyed by channel id, as
//  UserPreferences.channelLastActive keeps them. Foundation only, so
//  tests/ChannelListOrderTests.swift runs it as it is.
//

import Foundation

enum ChannelActivity {
    /// `times` after the channel was active at `time`: a post sent from it,
    /// or one that came in while it was open. Only ever later, so nothing
    /// moves a channel down.
    static func marked(_ times: [String: Double], channelId: String, at time: Double) -> [String: Double] {
        var times = times
        times[channelId] = max(times[channelId] ?? 0, time)
        return times
    }

    /// `times` with each channel that has no time yet placed at its newest
    /// post's (`lastMessageTimes`, by channel id), or nil when every channel
    /// has one. A channel that was here before 2026-11-03 and never opened
    /// stays where the list had it, by that time; a channel just joined,
    /// whose time is its join, goes to the top.
    static func placingNew(_ times: [String: Double], lastMessageTimes: [String: Double]) -> [String: Double]? {
        var times = times
        var changed = false
        for (id, time) in lastMessageTimes where times[id] == nil {
            times[id] = time
            changed = true
        }
        return changed ? times : nil
    }

    /// What the chat list orders a channel by. Its row shows its newest
    /// post's time, `lastMessageTime`, which places only a channel not
    /// placed yet.
    static func sortTime(_ times: [String: Double], channelId: String, lastMessageTime: Double) -> Double {
        times[channelId] ?? lastMessageTime
    }
}
