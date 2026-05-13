//
//  RNodeSettingsView.swift
//  Retichat
//
//  Scan, connect, and configure an RNode over Bluetooth (Nordic UART).
//

import SwiftUI

struct RNodeSettingsView: View {

    @StateObject private var ble = RNodeBluetoothManager()

    @State private var freqMHz: String = "867.500"
    @State private var bandwidth: LoRaBandwidth = .bw125
    @State private var sf: LoRaSpreadingFactor = .sf8
    @State private var cr: LoRaCodingRate = .cr45
    @State private var txPower: Double = 17
    @State private var flowControl: Bool = false

    @State private var idEnabled: Bool = false
    @State private var idCallsign: String = ""
    @State private var idIntervalMinutes: Double = 60

    var body: some View {
        Form {
            statusSection
            radioSection
            idBeaconSection

            Section("Devices") {
                deviceList
            }

            if let stats = ble.lastStats {
                statsSection(stats)
            }
        }
        .navigationTitle("RNode (Bluetooth)")
        .toolbar { toolbar }
        .onAppear { applyConfigToManager() }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("State")
                Spacer()
                Text(stateLabel).foregroundStyle(.secondary)
            }
            switch ble.state {
            case .connected(_, let handle):
                Text("Handle: \(handle)").font(.caption).foregroundStyle(.secondary)
            case .error(let msg):
                Text(msg).font(.caption).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var radioSection: some View {
        Section("Radio") {
            HStack {
                Text("Frequency")
                Spacer()
                TextField("MHz", text: $freqMHz)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                Text("MHz").foregroundStyle(.secondary)
            }
            Picker("Bandwidth", selection: $bandwidth) {
                ForEach(LoRaBandwidth.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Spreading Factor", selection: $sf) {
                ForEach(LoRaSpreadingFactor.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Coding Rate", selection: $cr) {
                ForEach(LoRaCodingRate.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("TX power")
                    Spacer()
                    Text("\(Int(txPower)) dBm").foregroundStyle(.secondary)
                }
                Slider(value: $txPower, in: 0...22, step: 1)
            }
            Toggle("Hardware flow control", isOn: $flowControl)
        }
    }

    @ViewBuilder
    private var idBeaconSection: some View {
        Section("ID Beacon") {
            Toggle("Enable", isOn: $idEnabled)
            if idEnabled {
                TextField("Callsign", text: $idCallsign)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Interval")
                        Spacer()
                        Text("\(Int(idIntervalMinutes)) min").foregroundStyle(.secondary)
                    }
                    Slider(value: $idIntervalMinutes, in: 5...360, step: 5)
                }
                Button("Send ID Beacon Now") { ble.sendIDBeaconNow() }
                    .disabled(!isConnected)
            }
        }
    }

    private var deviceList: some View {
        Group {
            if ble.discovered.isEmpty {
                Text(ble.state == .scanning ? "Scanning…" : "No devices yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.discovered) { dev in
                    Button {
                        applyConfigToManager()
                        ble.connect(dev.id, name: dev.name)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(dev.name).foregroundStyle(.primary)
                                Text(dev.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(dev.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isConnected || isConnecting)
                }
            }
        }
    }

    private func statsSection(_ s: RnsRNodeStats) -> some View {
        Section("Telemetry") {
            row("Online",   s.online != 0 ? "yes" : "no")
            row("Detected", s.detected != 0 ? "yes" : "no")
            if s.frequency_set != 0 { row("Frequency", "\(s.frequency) Hz") }
            if s.bandwidth_set != 0 { row("Bandwidth", "\(s.bandwidth) Hz") }
            if s.txpower_set   != 0 { row("TX power",  "\(s.txpower) dBm") }
            if s.sf_set        != 0 { row("SF",        "\(s.sf)") }
            if s.cr_set        != 0 { row("CR",        "4/\(s.cr)") }
            if s.rssi_set      != 0 { row("Last RSSI", "\(s.rssi) dBm") }
            if s.snr_set       != 0 { row("Last SNR",  String(format: "%.1f dB", s.snr)) }
            row("RX packets", "\(s.rx_packets)")
            row("TX packets", "\(s.tx_packets)")
            row("Airtime (short/long)", String(format: "%.2f%% / %.2f%%", s.airtime_short, s.airtime_long))
            row("Channel load (s/l)",   String(format: "%.2f%% / %.2f%%", s.channel_load_short, s.channel_load_long))
            row("Battery", "\(s.battery_percent)%")
            if s.firmware_maj > 0 { row("Firmware", "\(s.firmware_maj).\(s.firmware_min)") }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            switch ble.state {
            case .scanning:
                Button("Stop") { ble.stopScanning() }
            case .connected, .connecting:
                Button("Disconnect", role: .destructive) { ble.disconnect() }
            default:
                Button("Scan") {
                    applyConfigToManager()
                    ble.startScanning()
                }
            }
        }
    }

    // MARK: - Helpers

    private var isConnected: Bool {
        if case .connected = ble.state { return true }
        return false
    }
    private var isConnecting: Bool {
        if case .connecting = ble.state { return true }
        return false
    }

    private var stateLabel: String {
        switch ble.state {
        case .poweredOff:   return "Bluetooth off"
        case .unauthorized: return "Bluetooth unauthorized"
        case .unsupported:  return "Bluetooth unsupported"
        case .idle:         return "Idle"
        case .scanning:     return "Scanning"
        case .connecting:   return "Connecting…"
        case .pairing:      return "Pairing…"
        case .paired:       return "Paired"
        case .connected:    return "Connected"
        case .error(let m): return "Error: \(m)"
        }
    }

    private func applyConfigToManager() {
        let freqHz = UInt64((Double(freqMHz) ?? 867.5) * 1_000_000)
        var cfg = RNodeRadioConfig(
            frequency: freqHz,
            bandwidth: bandwidth,
            txPower: UInt8(txPower.rounded()),
            spreadingFactor: sf,
            codingRate: cr,
            flowControl: flowControl,
            shortTermAirtimeLimit: nil,
            longTermAirtimeLimit: nil,
            idBeacon: nil
        )
        if idEnabled, !idCallsign.isEmpty {
            cfg.idBeacon = .init(
                intervalSeconds: UInt64(idIntervalMinutes * 60),
                callsign: idCallsign
            )
        }
        ble.radioConfig = cfg
    }
}

#Preview {
    NavigationStack { RNodeSettingsView() }
}
