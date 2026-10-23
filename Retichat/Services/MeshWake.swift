//
//  MeshWake.swift
//  Retichat
//
//  This device as its own RFed Notify relay, so RFed can wake it over the
//  mesh as well as through APNs (James, 2026-10-23: "have rfed send the
//  notify ping directly to the requesting device as well. Then RTNode would
//  be able to push those notifications to wake Retichat at low power").
//
//  RFed wakes a device through every relay it registered (RFed-spec
//  Notify.md). One the device hosts itself, `rfed.notify` under its own
//  identity, gets the wake as one encrypted packet over whatever reaches the
//  device. Through a Bluetooth RTNode or RNode that packet wakes a suspended
//  Retichat, or relaunches it (BluetoothRestoration.swift), with no internet
//  needed; APNs cannot reach a phone without it. The wake names no message,
//  so the app fetches as for a push: the distro pull and a propagation sync.
//
//  Only with a Bluetooth radio configured (a saved, enabled RNode or the
//  Nearby RTNode switch on): over Wi-Fi or cellular a suspended app's
//  sockets are down, so the wake could not arrive, and RFed would spend a
//  packet, or a path request, on every wake for nothing. Registered for the
//  device's LXMF wakes (direct messages and its distro); channel wakes stay
//  with APNs for now.
//
//  Pure (no FFI, no UIKit), so tests/MeshWakeTests.swift can check it.
//

import Foundation

nonisolated enum MeshWake {
    /// Posted, on a Transport thread, for each wake that reaches this
    /// device's `rfed.notify`; `userInfo[payloadKey]` is the payload.
    static let received = Notification.Name("MeshWake.received")
    static let payloadKey = "payload"

    /// Whether the device hosts its own relay and registers it with RFed.
    static func wanted(savedRNode: Bool, rtnodeSwitchOn: Bool) -> Bool {
        savedRNode || rtnodeSwitchOn
    }

    /// What a wake says (RFed-spec Notify.md "Wake packet"): who it is for,
    /// and, when RFed knows them, the sender and the channel.
    struct Wake: Equatable {
        var receiver: Data
        var sender: Data?
        var channel: Data?
    }

    /// The wake in `payload`: a msgpack map with string keys and 16-byte bin
    /// values, `receiver` required. Keys it does not know are skipped, so a
    /// field RFed adds later does not stop the wake. Nil for anything else,
    /// as a bridge drops it.
    static func parse(_ payload: Data) -> Wake? {
        var reader = Reader(bytes: [UInt8](payload))
        guard let count = reader.mapCount() else { return nil }
        var fields: [String: Data] = [:]
        for _ in 0..<count {
            guard let key = reader.string() else { return nil }
            if let value = reader.bin() {
                fields[key] = value
            } else if !reader.skip() {
                return nil
            }
        }
        guard reader.atEnd, let receiver = fields["receiver"], receiver.count == 16 else { return nil }
        func hash(_ key: String) -> Data? { fields[key].flatMap { $0.count == 16 ? $0 : nil } }
        return Wake(receiver: receiver, sender: hash("sender"), channel: hash("channel"))
    }

    /// Enough msgpack for a wake: map, str and bin headers, and skipping the
    /// scalars a later field might hold.
    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        var atEnd: Bool { at == bytes.count }

        mutating func byte() -> UInt8? {
            guard at < bytes.count else { return nil }
            defer { at += 1 }
            return bytes[at]
        }

        mutating func length(_ size: Int) -> Int? {
            guard at + size <= bytes.count else { return nil }
            let n = bytes[at..<(at + size)].reduce(0) { $0 << 8 | Int($1) }
            at += size
            return n
        }

        mutating func take(_ n: Int) -> Data? {
            guard n >= 0, at + n <= bytes.count else { return nil }
            defer { at += n }
            return Data(bytes[at..<(at + n)])
        }

        mutating func mapCount() -> Int? {
            guard let b = byte() else { return nil }
            switch b {
            case 0x80...0x8f: return Int(b & 0x0f)
            case 0xde: return length(2)
            default: return nil
            }
        }

        mutating func string() -> String? {
            let start = at
            guard let b = byte() else { return nil }
            let n: Int?
            switch b {
            case 0xa0...0xbf: n = Int(b & 0x1f)
            case 0xd9: n = length(1)
            case 0xda: n = length(2)
            default: n = nil
            }
            guard let n, let data = take(n), let s = String(data: data, encoding: .utf8) else {
                at = start
                return nil
            }
            return s
        }

        /// A bin value, or nil with nothing read when the next value is not one.
        mutating func bin() -> Data? {
            let start = at
            guard let b = byte() else { return nil }
            let n: Int?
            switch b {
            case 0xc4: n = length(1)
            case 0xc5: n = length(2)
            default: n = nil
            }
            guard let n, let data = take(n) else {
                at = start
                return nil
            }
            return data
        }

        /// Skip one nil, bool, int, float or str; false for anything else.
        mutating func skip() -> Bool {
            if string() != nil { return true }
            guard let b = byte() else { return false }
            switch b {
            case 0x00...0x7f, 0xe0...0xff, 0xc0, 0xc2, 0xc3: return true
            case 0xcc, 0xd0: return take(1) != nil
            case 0xcd, 0xd1: return take(2) != nil
            case 0xce, 0xd2, 0xca: return take(4) != nil
            case 0xcf, 0xd3, 0xcb: return take(8) != nil
            default: return false
            }
        }
    }
}
