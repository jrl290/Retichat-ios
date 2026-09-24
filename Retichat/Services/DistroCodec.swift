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
