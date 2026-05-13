//
//  RNodeInterfaceProfile.swift
//  Retichat
//
//  Persistable profile for a saved RNode (Bluetooth) interface row.
//  Stored as a JSON string in `InterfaceConfigEntity.configJSON`.
//

import Foundation

/// Saved configuration for an RNode interface entry.
///
/// `peripheralUUID` may be nil when the user hasn't paired with a specific
/// peripheral yet — in that case the editor shows a "Scan & Pick" action.
struct RNodeInterfaceProfile: Codable, Equatable {
    var peripheralUUID: UUID?
    var peripheralName: String
    var radio: RNodeRadioConfig

    static let `default` = RNodeInterfaceProfile(
        peripheralUUID: nil,
        peripheralName: "",
        radio: .default
    )

    // MARK: - JSON helpers

    var jsonString: String? {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    init(peripheralUUID: UUID? = nil, peripheralName: String = "", radio: RNodeRadioConfig = .default) {
        self.peripheralUUID = peripheralUUID
        self.peripheralName = peripheralName
        self.radio = radio
    }

    init?(jsonString: String?) {
        guard let s = jsonString, let data = s.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(RNodeInterfaceProfile.self, from: data) else { return nil }
        self = decoded
    }
}
