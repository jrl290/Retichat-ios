//
//  DistroCodec.swift
//  Retichat
//
//  Pure encode/decode helpers for the RFed distro feature (RFed SPEC §17).
//  Foundation + CryptoKit only, no FFI, so it compiles standalone with swiftc
//  for tests/DistroCodecTests.swift (DESIGN_PRINCIPLES.md §10).
//
//  Mirrors Android service/DistroCodec.kt; the web client's equivalents live
//  in Retichat-js app.js (_parseDistroKey, _isAffirmative).
//

import Foundation
import CryptoKit

/// nonisolated: the project isolates to MainActor by default, and these are
/// called from the distro blob queue and from detached Keychain tasks.
nonisolated enum DistroCodec {

    /// `rfed-distro-private-key://<128 hex>`. Named for what it carries: the
    /// older `rfed-distro-id://` read like a public identifier.
    static let privateKeyScheme = "rfed-distro-private-key://"
    /// Still accepted on import so a key exported by an older build is not stranded.
    static let legacyScheme = "rfed-distro-id://"

    /// msgpack `nil`: the `/rfed/pull` request body (SPEC §17.8).
    static let msgpackNil = Data([0xC0])

    private static let privateKeyBytes = 64

    /// Parse a distro private key from user or transfer input.
    ///
    /// Accepts either URI scheme (any case), or bare hex, with surrounding
    /// whitespace and one trailing "/" tolerated. Returns the 64 raw bytes or
    /// nil. Android DistroCodec.kt:20-36.
    static func parsePrivateKey(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        for scheme in [privateKeyScheme, legacyScheme] where lower.hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
            break
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        s = s.lowercased()
        guard s.count == privateKeyBytes * 2,
              s.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }),
              let bytes = hexDecode(s), bytes.count == privateKeyBytes
        else { return nil }
        return bytes
    }

    /// RFed answers register/unregister/announce with msgpack `true` (0xC3),
    /// or an array whose first element is `true`. Android DistroCodec.kt:44-55.
    static func isAffirmative(_ resp: Data?) -> Bool {
        guard let resp, let first = resp.first else { return false }
        if first == 0xC3 { return true }
        if (0x91...0x9F).contains(first) {
            let second = resp.index(after: resp.startIndex)
            return second < resp.endIndex && resp[second] == 0xC3
        }
        return false
    }

    /// RFed's answer that is not a yes, said as it happened (James's truth rule):
    /// nil is no answer at all (the link did not come up inside its 5 s, or the
    /// request got no response), never a refusal; an answer that is not a yes is
    /// a refusal, said with what came back. Android DistroCodec.notAYes. Until
    /// 2026-10-10 a device that got no answer printed "RFed refused the
    /// pre-signed announce".
    static func notAYes(_ request: String, _ resp: Data?) -> String {
        guard let resp else { return "RFed did not answer the \(request)" }
        return "RFed refused the \(request) (it answered \(describeAnswer(resp)))"
    }

    /// An answer for the log: RFed's refusals are msgpack `false` (destinations.rs
    /// `fail`) or nil, said as such; anything else as its size and first bytes.
    static func describeAnswer(_ resp: Data) -> String {
        if resp.count == 1 {
            if resp.first == 0xC2 { return "false" }
            if resp.first == 0xC0 { return "nil" }
        }
        let head = resp.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(resp.count) byte(s): \(head)\(resp.count > 16 ? "…" : "")"
    }

    /// A `/rfed/pull` refusal is a single error byte, raw or as msgpack uint8
    /// (`[0xCC, code]`). Anything else is a pull envelope (or garbage, which
    /// the envelope decoder rejects).
    static func pullErrorCode(_ resp: Data) -> UInt8? {
        let bytes = [UInt8](resp)
        if bytes.count == 1 { return bytes[0] }
        if bytes.count == 2 && bytes[0] == 0xCC { return bytes[1] }
        return nil
    }

    /// Idempotency key for one distro message. The same message arrives more
    /// than once — live fan-out, deferred PULL, re-ingest from a peer node —
    /// with different framings, so it keys on the message, not the bytes.
    /// Android DistroCodec.kt:86-87.
    static func seenKey(sourceHex: String, timestamp: Double) -> String {
        "\(sourceHex):\(timestamp)"
    }

    /// Append `key` unless already present, keeping the newest `cap` entries,
    /// oldest first. Android DistroCodec.kt:89-94.
    static func appendSeen(_ existing: [String], key: String, cap: Int = 500) -> [String] {
        if existing.contains(key) { return existing }
        var out = existing
        out.append(key)
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }

    /// Local message id for a distro-delivered message: hex of
    /// SHA256("distro|src|ts|content")[0..<16].
    ///
    /// Only deduplicates on THIS device (the stream and pull tiers can both
    /// deliver the same message), so it need not match Android's
    /// DistroCodec.messageId byte for byte — Kotlin's Double.toString and
    /// Swift's description differ for some timestamps.
    static func messageId(sourceHex: String, timestamp: Double, content: String) -> String {
        let digest = SHA256.hash(data: Data("distro|\(sourceHex)|\(timestamp)|\(content)".utf8))
        return hexEncode(Data(digest).prefix(16))
    }

    /// RNS identity hash of a 64-byte public key: SHA256(pub)[0..<16] as hex.
    /// Not routable — the distro's ADDRESS is its lxmf.delivery hash.
    static func identityHashHex(publicKey: Data) -> String? {
        guard publicKey.count == 64 else { return nil }
        return hexEncode(Data(SHA256.hash(data: publicKey)).prefix(16))
    }

    // MARK: - Sent-message sync (RFed SPEC §17.11)
    //
    // The receive rules every client applies (Android and the web client
    // implement the same SPEC section); the marker itself is read by
    // lxmf_rust distro::unwrap_blob (sent_to / sent_by in the unwrap JSON).

    /// 32 lowercase hex: an lxmf.delivery address as §17.11 writes it into
    /// fields 0xFC and 0xFD.
    static func isAddressHex(_ s: String) -> Bool {
        s.utf8.count == 32 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Whether a direct message just submitted also needs its sent copy.
    ///
    /// Only a message signed as the distro has one (a device-signed message
    /// is not the distro's to report), and never one addressed to the distro
    /// itself: every device already receives that by fan-out, and a copy of
    /// it would file the distro as a conversation with itself.
    static func needsSentCopy(sentAsDistro: Bool, destHex: String, distroHex: String?) -> Bool {
        guard sentAsDistro, let distroHex else { return false }
        return destHex.lowercased() != distroHex.lowercased()
    }

    /// What to do with a fan-out message that carries the sent marker
    /// (`sent_by` non-nil in the unwrap JSON).
    enum SentCopyDisposition: Equatable {
        /// Not signed by our own distro: someone else claiming the marker.
        case foreignSource
        /// This device sent it; the original is already in the chat.
        case ownEcho
        /// 0xFC is not a 32-hex address (unwrap_blob leaves sent_to nil).
        case malformedRecipient
        /// A sibling's message to `recipientHex`: file it as outgoing.
        case store(recipientHex: String)
    }

    /// Checked in the order SPEC §17.11 lists them: provenance first, so a
    /// forged copy can never be mistaken for our echo or filed; then the
    /// echo, which is dropped whatever its 0xFC says.
    static func sentCopyDisposition(sourceHex: String, distroHex: String, sentTo: String?,
                                    sentBy: String, ownDeviceHex: String) -> SentCopyDisposition {
        guard sourceHex.lowercased() == distroHex.lowercased() else { return .foreignSource }
        if !ownDeviceHex.isEmpty && sentBy.lowercased() == ownDeviceHex.lowercased() { return .ownEcho }
        // SPEC §17.11 rule 4: 32 hex, and never D itself (no copy is sent for
        // a message to D; filing one would open a chat with the distro).
        guard let to = sentTo?.lowercased(), isAddressHex(to), to != distroHex.lowercased() else {
            return .malformedRecipient
        }
        return .store(recipientHex: to)
    }

    // MARK: - Channels and the distro (RFed-spec Channel.md "Distro holders")

    /// The hash the device signs its channel posts with, its posting identity:
    /// the distro's `lxmf.delivery` hash when the device holds one
    /// (`distroHex`), otherwise the device's own (`deviceHex`). Subscribing, the
    /// stream, pulls and push registrations are the device's whichever it is.
    /// Android DistroCodec.postingHex.
    static func postingHex(deviceHex: String, distroHex: String?) -> String {
        if let distroHex, !distroHex.isEmpty { return distroHex }
        return deviceHex
    }

    /// Channel.md "Own posts": a received channel post is the user's own when
    /// its source is this device's `lxmf.delivery` hash or the hash of the
    /// distro this device holds now (`distroHex`, nil when none), whichever of
    /// the user's devices sent it. A device that gave up its distro no longer
    /// holds it, so that distro's later posts are another poster's. An empty
    /// hash (the stack is down, no distro) matches nothing.
    static func isOwnChannelPost(sourceHex: String, deviceHex: String, distroHex: String?) -> Bool {
        guard !sourceHex.isEmpty else { return false }
        if sourceHex.lowercased() == deviceHex.lowercased() { return true }
        if let distroHex { return sourceHex.lowercased() == distroHex.lowercased() }
        return false
    }

    // MARK: - Private hex helpers
    //
    // Own copies rather than Data.hexString: this file must compile alone
    // with swiftc for the codec tests.

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

/// The app's start on a device that holds a distro: its queue first, then the
/// persisted channels (DESIGN_PRINCIPLES §5, strict ordering; Android
/// DistroFirst.kt, Retichat-js _distroFirst).
///
/// RFed holds the siblings' channel joins and leaves for this device (RFed SPEC
/// §17.12; with the distro sync proof, §17.13, one no longer wakes it). Found on
/// Android in private staging, 2026-10-10: the start re-subscribed a channel the
/// distro had left on another device, the pull applied that leave 0.3 s later,
/// and a post fanned out between the two reached the device. iOS had the same
/// order: RfedChannelClient re-subscribed on rfed.channel reachability while
/// RfedDistroClient pulled after its registration, the two unsynchronised.
///
/// The pull's outcome, whatever it is, is the event the re-subscription waits
/// for: drained, stopped at its round cap, no answer, refused, malformed, the
/// stack stopped under it. Each is said, and the re-subscription goes on: no
/// timer, never forever, never silent. No distro: re-subscribed at once.
@MainActor
enum DistroFirst {
    /// How one distro pull ended (RfedDistroClient.pullOutcome).
    struct PullOutcome: Sendable, Equatable {
        /// Blobs it handled.
        let blobs: Int
        /// Why it stopped short of RFed's last answer, or nil when every round it ran was answered.
        let unfinished: String?
        /// RFed still had more when the round cap stopped it.
        let morePending: Bool
    }

    static func thenResubscribe(hasDistro: Bool,
                                pull: () async -> PullOutcome,
                                say: (_ line: String, _ warning: Bool) -> Void,
                                resubscribe: () async -> Void) async {
        if hasDistro {
            let s = said(await pull())
            say(s.line, s.warning)
        }
        await resubscribe()
    }

    nonisolated static func said(_ o: PullOutcome) -> (line: String, warning: Bool) {
        let later = "a sibling's leave still queued at RFed, if any, is applied when a later pull brings it"
        if let why = o.unfinished {
            return ("Distro pull before re-subscribing stopped after \(o.blobs) blob(s): \(why); "
                    + "re-subscribing persisted channels now; \(later)", true)
        }
        if o.morePending {
            return ("Distro pull before re-subscribing applied \(o.blobs) blob(s) and stopped at its round cap "
                    + "with more pending: re-subscribing persisted channels now; the rest is applied when a later pull brings it", true)
        }
        return ("Distro queue pulled and applied first (\(o.blobs) blob(s)): re-subscribing persisted channels", false)
    }
}
