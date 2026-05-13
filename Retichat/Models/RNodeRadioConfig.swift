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

/// LoRa spreading factor (7..12).
enum LoRaSpreadingFactor: Int, CaseIterable, Codable {
    case sf7 = 7, sf8, sf9, sf10, sf11, sf12

    var label: String { "SF\(rawValue)" }
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
