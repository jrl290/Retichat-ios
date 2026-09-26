import Foundation

// MARK: - Distro pull for a push (2026-09-26)
//
// RFed pushes a device for a distro message the way it pushes for a message
// to the device's own address (RFed SPEC §17.3), but a distro message is not
// in the propagation node's store: it waits in RFed's deferred queue, and only
// /rfed/pull on rfed.distro.register hands it over. Until 2026-09-26 the NSE
// only synced from the propagation node, found nothing, and suppressed the
// notification: a distro message showed no push on iOS.
//
// The pull drains RFed's queue, so every blob is saved in the App Group for
// the app before anything else (RfedDistroClient.importNSEBlobs ingests them
// as a pull of its own: dedupe, sent copies and transfers are decided there).
// The NSE unwraps them only to show the newest.

enum NSEDistroPull {

    /// A distro message to show.
    struct Shown {
        let senderHash: String
        let title: String
        let content: String
        let timestamp: Double
    }

    struct Result {
        /// Blobs pulled (and saved for the app).
        var pulled = 0
        /// The messages among them to show: not sent copies, transfers or
        /// delivery notifications.
        var shown: [Shown] = []
        /// This device has a distro but the pull did not complete: a message
        /// may be waiting, so the push must not be suppressed.
        var failed = false
        /// This device has no distro (or the app has not shared it yet).
        var noDistro = false
    }

    /// At most this many rounds, as the app's pull (RfedDistroClient).
    private static let roundsMax = 8

    /// Pull, save and unwrap. Blocking: call from the NSE's own thread.
    /// `deadline` bounds the link requests; each round's timeout is what is
    /// left of it (never more than 10 s).
    static func run(identityHandle: UInt64, deadline: Date) -> Result {
        var result = Result()
        guard let key = PendingNotification.readSharedDistroKey(),
              let destHex = PendingNotification.readDistroPullDestination(),
              let dest = hexData(destHex), dest.count == 16 else {
            result.noDistro = true
            return result
        }
        let distroHandle = key.withUnsafeBytes { raw -> UInt64 in
            retichat_identity_from_bytes(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(key.count))
        }
        guard distroHandle != 0 else {
            NSLog("[NSE-Distro] shared distro key did not load")
            result.failed = true
            return result
        }
        defer { _ = retichat_identity_destroy(distroHandle) }

        for round in 1...roundsMax {
            let left = deadline.timeIntervalSinceNow
            guard left > 1 else {
                NSLog("[NSE-Distro] no time left for round %d", round)
                result.failed = true
                break
            }
            guard let response = pullRequest(dest: dest, identityHandle: identityHandle,
                                             timeoutSecs: min(left, 10)) else {
                NSLog("[NSE-Distro] pull round %d: RFed not reachable", round)
                result.failed = true
                break
            }
            guard let (blobs, more) = NSEDistroPullDecoder.decode(response) else {
                NSLog("[NSE-Distro] pull round %d: refused or malformed (%d bytes)", round, response.count)
                result.failed = true
                break
            }
            // Saved before anything else: the pull has drained RFed's queue.
            if !PendingNotification.saveNSEDistroBlobs(blobs) {
                result.failed = true
            }
            result.pulled += blobs.count
            for blob in blobs {
                if let shown = unwrapToShow(blob, distroHandle: distroHandle) { result.shown.append(shown) }
            }
            NSLog("[NSE-Distro] pull round %d: %d blob(s), more=%d", round, blobs.count, more ? 1 : 0)
            if !more { break }
        }
        return result
    }

    // MARK: - Request

    private static func pullRequest(dest: Data, identityHandle: UInt64, timeoutSecs: Double) -> Data? {
        let payload = Data([0xC0])   // msgpack nil: a pull carries no data
        return dest.withUnsafeBytes { destBuf in
            payload.withUnsafeBytes { payBuf in
                "rfed".withCString { app in
                    "distro,register".withCString { aspects in
                        "/rfed/pull".withCString { path in
                            var outLen: UInt32 = 0
                            guard let ptr = retichat_link_request(
                                destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(dest.count),
                                app, aspects, identityHandle, path,
                                payBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(payload.count),
                                timeoutSecs, &outLen) else { return nil }
                            let data = Data(bytes: ptr, count: Int(outLen))
                            lxmf_free_bytes(ptr, outLen)
                            return data
                        }
                    }
                }
            }
        }
    }

    // MARK: - Unwrap

    /// retichat_distro_unwrap's JSON (the app decodes the same fields).
    private struct Unwrapped: Decodable {
        let source_hash: String
        let timestamp: Double
        let title: String?
        let content: String?
        let is_delivery_notification: Bool
        let distro_transfer_key: String?
        let sent_by: String?
    }

    private static func unwrapToShow(_ blob: Data, distroHandle: UInt64) -> Shown? {
        var outLen: UInt32 = 0
        let ptr = blob.withUnsafeBytes { raw in
            retichat_distro_unwrap(distroHandle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                   UInt32(blob.count), &outLen)
        }
        guard let ptr else { return nil }
        let json = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)
        guard !json.isEmpty, let m = try? JSONDecoder().decode(Unwrapped.self, from: json) else { return nil }
        // Sent copies are the user's own messages (SPEC §17.11), a transfer
        // is an offer the app acts on, a delivery notification has no text.
        if m.sent_by != nil || !(m.distro_transfer_key ?? "").isEmpty || m.is_delivery_notification {
            return nil
        }
        return Shown(senderHash: m.source_hash.lowercased(), title: m.title ?? "",
                     content: m.content ?? "", timestamp: m.timestamp)
    }

    private static func hexData(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

// BEGIN NSEDistroPullDecoder
// Foundation only: tests/NSEDistroPullTests.swift compiles this block on its own.

/// The `/rfed/pull` response: msgpack [ [[bin distro_hash, bin blob], …], bool more ].
enum NSEDistroPullDecoder {

    /// The blobs and the more-pending flag; nil for an error code (a bare
    /// integer) or anything malformed.
    static func decode(_ data: Data) -> ([Data], Bool)? {
        var r = Reader(bytes: [UInt8](data))
        guard r.arrayCount() == 2, let pairs = r.arrayCount() else { return nil }
        var blobs: [Data] = []
        for _ in 0..<pairs {
            guard r.arrayCount() == 2, r.bin() != nil, let blob = r.bin() else { return nil }
            blobs.append(blob)
        }
        guard let more = r.bool() else { return nil }
        return (blobs, more)
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func uint(_ n: Int) -> Int? {
            guard i + n <= bytes.count else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(bytes[i]); i += 1 }
            return v
        }

        mutating func arrayCount() -> Int? {
            guard let t = byte() else { return nil }
            switch t {
            case 0x90...0x9F: return Int(t & 0x0F)
            case 0xDC: return uint(2)
            case 0xDD: return uint(4)
            default: return nil
            }
        }

        mutating func bin() -> Data? {
            guard let t = byte() else { return nil }
            let n: Int?
            switch t {
            case 0xC4: n = uint(1)
            case 0xC5: n = uint(2)
            case 0xC6: n = uint(4)
            default: n = nil
            }
            guard let n, i + n <= bytes.count else { return nil }
            defer { i += n }
            return Data(bytes[i..<i + n])
        }

        mutating func bool() -> Bool? {
            switch byte() {
            case 0xC2: return false
            case 0xC3: return true
            default: return nil
            }
        }
    }
}
// END NSEDistroPullDecoder
