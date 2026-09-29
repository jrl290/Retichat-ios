//
//  UploadProgress.swift
//  Retichat
//
//  The progress bar of an outgoing attachment's bubble: which rows are read
//  for one, what it shows, and which bars a reading changes. Pure (no FFI,
//  no SwiftData, no SwiftUI), so it compiles standalone with swiftc for
//  tests/UploadProgressTests.swift (DESIGN_PRINCIPLES.md §10).
//
//  The bar follows the message's DIRECT attempt — the handle the row keeps
//  (nativeHandle) — and shows while that attempt is SENDING, whatever the
//  bubble shows. The bubble says propagating while the DIRECT Resource may
//  still be moving: AppLinks Timer P asked for the propagated copy (0x10)
//  and the copy runs beside the DIRECT attempt (OutboundAttempts). Until
//  2026-09-29 a propagating row showed no bar, on the reasoning that its
//  DIRECT attempt had failed, which holds only when the copy followed a
//  failure; an iPad photo (~650 KB, 1708 parts, ~4 min over a Nearby RTNode
//  Bluetooth link) showed none for its whole transfer. A failed, delivered
//  or not-yet-started attempt is not SENDING, so it shows none either.
//
//  The value is LXMessage.progress (lxmf_message_progress): 0.10 + 0.90 × the
//  Resource's fraction while it transfers, as LXMF/LXMessage.py
//  __update_transfer_progress sets it. LXMF-rust 4125139 made the AppLinks
//  path do so; before, it sat at the 0.05 the router sets when the send
//  starts.
//
//  ConversationViewModel reads (state, progress) for the live rows on
//  ChatRepository's ffiQueue on every 3 s tick, structural change or not,
//  and assigns only the bars that changed. Until 2026-09-29 the bar was read
//  on the main actor, and only when a row was added or changed state, so it
//  never moved between those (and the lock-taking read ran on the UI
//  thread, §6).
//

nonisolated enum UploadProgress {

    /// LXMessage.SENDING (LXMF-rust lx_message.rs, LXMF/LXMessage.py).
    static let sending: Int32 = 0x02

    /// Whether the row's DIRECT attempt is read for a bar: an outgoing
    /// message with attachments whose handle is the one ChatRepository's
    /// pending entry for it holds (`pendingHandle`; nil when it has none).
    /// The entry lives from submission until the message completes and
    /// survives 0x10, so a propagating row is read while a delivered or
    /// failed one, a send still held (handle 0) and a row from an earlier
    /// run are not — the handle an earlier run stored names nothing, or some
    /// other object, in this process's handle registry.
    static func isLive(isOutgoing: Bool, withAttachments: Bool,
                       nativeHandle: UInt64, pendingHandle: UInt64?) -> Bool {
        isOutgoing && withAttachments && nativeHandle != 0 && pendingHandle == nativeHandle
    }

    /// The bar for the DIRECT attempt's own state and progress as the FFI
    /// reads them (-1 and -1.0 for a handle it no longer knows): the
    /// progress while the attempt is SENDING and short of 1.0; else none.
    static func bar(state: Int32, progress: Float) -> Float? {
        guard state == sending, progress >= 0, progress < 1 else { return nil }
        return progress
    }

    /// The bars that change. `rows` are the list's (id, bar) in order;
    /// `live` the ids live now (isLive); `read` a reading's bar (nil: none)
    /// for each id that was live when it was taken. A row no longer live
    /// shows no bar, whatever an older reading says; a live row takes its
    /// reading, or keeps its bar when the reading predates it. Unchanged
    /// bars are left out, so nothing redraws for them.
    static func changes(rows: [(id: String, bar: Float?)], live: Set<String>,
                        read: [String: Float?]) -> [(index: Int, bar: Float?)] {
        var out: [(index: Int, bar: Float?)] = []
        for (index, row) in rows.enumerated() {
            let bar: Float?
            if !live.contains(row.id) {
                bar = nil
            } else if let reading = read[row.id] {
                bar = reading
            } else {
                bar = row.bar
            }
            if bar != row.bar {
                out.append((index, bar))
            }
        }
        return out
    }

    /// A full reload builds its rows without bars (it reads no FFI). Each
    /// row keeps the bar its id showed before, until the next reading, so a
    /// moving bar does not blink off when a row elsewhere changes.
    static func carried(from old: [(id: String, bar: Float?)], to ids: [String]) -> [Float?] {
        var bars: [String: Float] = [:]
        for row in old {
            if let bar = row.bar { bars[row.id] = bar }
        }
        return ids.map { bars[$0] }
    }
}
