import Foundation

// MARK: - Channel pull for a push (2026-09-26)
//
// A channel with "Push All Messages" on is woken like LXMF, and the push names
// the channel (userInfo["rfed"]["channel"], apns-bridge apns.rs build_payload).
// The blob waits in RFed's deferred queue under this device's identity; only
// /rfed/pull on the channel node's rfed.channel.pull, over a link identified as
// this device, hands it over. Until 2026-09-26 the NSE ran only a propagation
// sync and a distro pull, found nothing, and hid the notification (and RFed
// woke channel subscribers under a key no push token was registered under, so
// the push never came at all: RFed-rust 7225295).
//
// The app shares, per channel with push on, the name (the channel message key
// derives from it), the pull destination and its path seeds
// (PendingNotification.ChannelPushEntry). Every pulled blob is saved for the
// app first (the pull drained RFed's queue); the app ingests them as a pull of
// its own (RfedChannelClient.importNSEBlobs). The NSE shows a message only
// when its signature verifies, as the app accepts only those.

enum NSEChannelPull {

    struct Shown {
        let senderHash: String
        let content: String
        let timestamp: Double
    }

    struct Result {
        var pulled = 0
        var shown: [Shown] = []
        /// The channel is known and its pull did not complete: a message may
        /// be waiting, so the push must not be hidden.
        var failed = false
        /// No directory entry for the channel (push off, or an app that has
        /// not written the directory yet).
        var unknownChannel = false
        /// The channel's "Notifications" toggle.
        var notify = true
        var channelName = ""
        var channelHex = ""
    }

    /// At most this many rounds, as the distro pull.
    private static let roundsMax = 8

    /// Pull, save and unpack. Blocking: call from the NSE's own thread.
    static func run(channelHex: String, identityHandle: UInt64, deadline: Date) -> Result {
        var result = Result()
        let key = channelHex.lowercased()
        guard let entry = PendingNotification.readChannelPushDirectory()[key],
              let channel = NSEDistroPull.hexData(entry.channel), channel.count == 16,
              let dest = NSEDistroPull.hexData(entry.pull), dest.count == 16 else {
            result.unknownChannel = true
            return result
        }
        result.notify = entry.notify
        result.channelName = entry.name
        result.channelHex = key

        guard NSEDistroPull.ensurePath(to: dest, from: entry.sources.compactMap(NSEDistroPull.hexData),
                                       deadline: deadline, label: "rfed.channel.pull") else {
            NSLog("[NSE-Channel] no path to rfed.channel.pull %@", String(entry.pull.prefix(8)))
            result.failed = true
            return result
        }

        // msgpack bin(16): the channel, as the app's pull sends it
        // (RfedChannelClient.pullDeferred, msgpackBin).
        let payload = Data([0xC4, 0x10]) + channel
        for round in 1...roundsMax {
            let left = deadline.timeIntervalSinceNow
            guard left > 1 else {
                NSLog("[NSE-Channel] no time left for round %d", round)
                result.failed = true
                break
            }
            guard let response = NSEDistroPull.linkRequest(
                dest: dest, aspects: "channel,pull", path: "/rfed/pull", payload: payload,
                identityHandle: identityHandle, timeoutSecs: min(left, 10)) else {
                NSLog("[NSE-Channel] pull round %d: RFed not reachable", round)
                result.failed = true
                break
            }
            // Same envelope as the distro pull: [[[bin channel, bin blob], ...], more].
            guard let (blobs, more) = NSEDistroPullDecoder.decode(response) else {
                NSLog("[NSE-Channel] pull round %d: refused or malformed (%d bytes)", round, response.count)
                result.failed = true
                break
            }
            // Saved before anything else: the pull has drained RFed's queue.
            if !PendingNotification.saveNSEChannelBlobs(blobs.map { (channel: channel, blob: $0) }) {
                result.failed = true
            }
            result.pulled += blobs.count
            if entry.notify {
                for blob in blobs {
                    if let shown = unpackToShow(name: entry.name, lxmfData: channel + blob) {
                        result.shown.append(shown)
                    }
                }
            }
            NSLog("[NSE-Channel] pull round %d: %d blob(s), more=%d", round, blobs.count, more ? 1 : 0)
            if !more { break }
        }
        return result
    }

    private static func unpackToShow(name: String, lxmfData: Data) -> Shown? {
        var outLen: UInt32 = 0
        guard let ptr = name.withCString({ cName in
            lxmfData.withUnsafeBytes { buf in
                retichat_channel_lxm_unpack(cName, buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            UInt32(lxmfData.count), &outLen)
            }
        }) else { return nil }
        let raw = Data(bytes: ptr, count: Int(outLen))
        lxmf_free_bytes(ptr, outLen)
        guard let message = NSEChannelUnpackDecoder.decode(raw), message.signatureValidated else { return nil }
        return Shown(senderHash: message.sourceHash.map { String(format: "%02x", $0) }.joined(),
                     content: message.content,
                     timestamp: Double(message.timestampMs) / 1000)
    }
}

// BEGIN NSEChannelUnpackDecoder
// Foundation only: tests/NSEChannelPullTests.swift compiles this block on its own.

/// The output of retichat_channel_lxm_unpack, as RetichatBridge.channelLxmUnpack
/// reads it: source(16) | timestamp_ms u64 BE | sig_ok u8 | reason u8 |
/// title_len u16 BE | content_len u32 BE | title | content.
enum NSEChannelUnpackDecoder {
    struct Message: Equatable {
        let sourceHash: Data
        let timestampMs: UInt64
        let signatureValidated: Bool
        let title: String
        let content: String
    }

    static func decode(_ raw: Data) -> Message? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 32 else { return nil }
        func uint(_ from: Int, _ count: Int) -> Int {
            bytes[from..<(from + count)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let titleLen = uint(26, 2)
        let contentLen = uint(28, 4)
        guard bytes.count >= 32 + titleLen + contentLen else { return nil }
        let timestamp = bytes[16..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Message(
            sourceHash: Data(bytes[0..<16]),
            timestampMs: timestamp,
            signatureValidated: bytes[24] == 1,
            title: String(decoding: bytes[32..<(32 + titleLen)], as: UTF8.self),
            content: String(decoding: bytes[(32 + titleLen)..<(32 + titleLen + contentLen)], as: UTF8.self))
    }
}
// END NSEChannelUnpackDecoder
