//
//  RNodeRadioConfig.swift
//  Retichat
//
//  Swift-side mirror of the C ABI RnsRNodeRadioConfig struct, plus the LoRa
//  parameter enums used to build it.
//

import Foundation

/// LoRa coding rate (4/5 .. 4/8).
enum LoRaCodingRate: Int, CaseIterable, Codable {
    case cr45 = 5
    case cr46 = 6
    case cr47 = 7
    case cr48 = 8

    var label: String {
        switch self {
        case .cr45: return "4/5"
        case .cr46: return "4/6"
        case .cr47: return "4/7"
        case .cr48: return "4/8"
        }
    }
}

/// LoRa spreading factor (5..12, the range RNodeInterface accepts in RNS
/// 1.5.2 and Reticulum-rust).
enum LoRaSpreadingFactor: Int, CaseIterable, Codable {
    case sf5 = 5, sf6, sf7, sf8, sf9, sf10, sf11, sf12

    var label: String { "SF\(rawValue)" }

    /// Shown under the picker for SF5 and SF6. An SX127x takes SF6 only in
    /// implicit-header mode, which RNS never selects, and RNode firmware
    /// (1.85) clamps SF5 there to SF6 but reports back the SF5 it was sent,
    /// so neither RNS nor this app can see the difference.
    var radioCaveat: String? {
        guard rawValue < LoRaSpreadingFactor.sf7.rawValue else { return nil }
        return "SF5 and SF6 need an SX126x or SX128x radio. An SX127x RNode cannot use SF5 "
            + "(its firmware substitutes SF6 and still reports SF5)."
    }
}

/// Common LoRa bandwidth selections (Hz). RNode supports the standard LoRa
/// bandwidths; we expose the commonly used subset.
enum LoRaBandwidth: UInt32, CaseIterable, Codable {
    case bw7_8     = 7800
    case bw10_4    = 10400
    case bw15_6    = 15600
    case bw20_8    = 20800
    case bw31_25   = 31250
    case bw41_7    = 41700
    case bw62_5    = 62500
    case bw125     = 125000
    case bw250     = 250000
    case bw500     = 500000

    var label: String {
        let khz = Double(rawValue) / 1000.0
        return String(format: "%.1f kHz", khz)
    }
}

/// Pure-Swift radio configuration. Convert to the C ABI shape with
/// `withCConfig(_:)`.
struct RNodeRadioConfig: Codable, Equatable {
    /// Carrier frequency in Hz (e.g. 915000000 for 915 MHz).
    var frequency: UInt64
    var bandwidth: LoRaBandwidth
    /// TX power in dBm (RNode HW dependent — usually 0..22).
    var txPower: UInt8
    var spreadingFactor: LoRaSpreadingFactor
    var codingRate: LoRaCodingRate
    var flowControl: Bool

    /// Short-term airtime limit (percent 0..100), nil to disable.
    var shortTermAirtimeLimit: Float?
    /// Long-term airtime limit (percent 0..100), nil to disable.
    var longTermAirtimeLimit: Float?

    /// Optional periodic ID beacon.
    var idBeacon: IDBeacon?

    struct IDBeacon: Codable, Equatable {
        var intervalSeconds: UInt64
        var callsign: String
    }

    static let `default` = RNodeRadioConfig(
        frequency: 867_500_000,
        bandwidth: .bw125,
        txPower: 17,
        spreadingFactor: .sf8,
        codingRate: .cr45,
        flowControl: false,
        shortTermAirtimeLimit: nil,
        longTermAirtimeLimit: nil,
        idBeacon: nil
    )

    // MARK: - Frequency text (MHz)

    /// Carrier frequencies RNodeInterface accepts, in Hz (FREQ_MIN/FREQ_MAX
    /// in RNS 1.5.2 and Reticulum-rust): anything outside fails the
    /// interface's config validation.
    static let frequencyRange: ClosedRange<UInt64> = 137_000_000...3_000_000_000

    /// Decimal places the frequency is shown and entered with, in MHz
    /// (4: 100 Hz resolution).
    static let frequencyDecimals = 4

    /// What `frequencyHz(fromMegahertz:)` accepts, for the editor to show.
    static var frequencyRequirement: String {
        "\(frequencyRange.lowerBound / 1_000_000) to \(frequencyRange.upperBound / 1_000_000) MHz, "
            + "at most \(frequencyDecimals) decimal places"
    }

    /// `hz` in MHz with `frequencyDecimals` places, e.g. "868.1234". Integer
    /// arithmetic, rounded to the nearest 100 Hz, so it round-trips through
    /// `frequencyHz(fromMegahertz:)`.
    static func megahertzText(forHz hz: UInt64) -> String {
        let units = (hz + 50) / 100
        return String(format: "%llu.%04llu", units / 10_000, units % 10_000)
    }

    /// Hz for MHz text such as "868.1234" (a comma is taken as the decimal
    /// point, as the decimal pad types it in many locales). Built from the
    /// digits, never from a binary floating-point product: UInt64(256.0001 *
    /// 1_000_000) is 256000099. nil unless the text is a plain number with at
    /// most `frequencyDecimals` places, inside `frequencyRange`.
    static func frequencyHz(fromMegahertz text: String) -> UInt64? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ".", omittingEmptySubsequences: false)
        let digits = Set("0123456789")
        guard parts.count <= 2,
              let whole = parts.first, !whole.isEmpty, whole.allSatisfy(digits.contains),
              let mhz = UInt64(whole), mhz <= frequencyRange.upperBound / 1_000_000 else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard fraction.count <= frequencyDecimals, fraction.allSatisfy(digits.contains),
              let subMHz = UInt64(fraction + String(repeating: "0", count: 6 - fraction.count))
        else { return nil }
        let hz = mhz * 1_000_000 + subMHz
        return frequencyRange.contains(hz) ? hz : nil
    }

    /// Build the C ABI `RnsRNodeRadioConfig` and pass it to `body`. The
    /// callsign byte buffer's lifetime is bounded by the closure.
    func withCConfig<R>(_ body: (RnsRNodeRadioConfig) -> R) -> R {
        let callsignBytes: [UInt8] = idBeacon?.callsign.utf8.map { $0 } ?? []
        return callsignBytes.withUnsafeBufferPointer { buf in
            let cfg = RnsRNodeRadioConfig(
                frequency: frequency,
                bandwidth: bandwidth.rawValue,
                txpower: txPower,
                sf: UInt8(spreadingFactor.rawValue),
                cr: UInt8(codingRate.rawValue),
                flow_control: flowControl ? 1 : 0,
                st_alock_set: shortTermAirtimeLimit != nil ? 1 : 0,
                st_alock_pct: shortTermAirtimeLimit ?? 0,
                lt_alock_set: longTermAirtimeLimit != nil ? 1 : 0,
                lt_alock_pct: longTermAirtimeLimit ?? 0,
                id_beacon_set: idBeacon != nil ? 1 : 0,
                id_interval_secs: idBeacon?.intervalSeconds ?? 0,
                id_callsign: idBeacon != nil ? buf.baseAddress : nil,
                id_callsign_len: UInt32(callsignBytes.count)
            )
            return body(cfg)
        }
    }
}
