//
//  RNodeInterfaceEditorView.swift
//  Retichat
//
//  Editor for an RNode (Bluetooth) interface row in Settings.
//  - Top: name + paired peripheral (with "Scan & Pair" sheet).
//  - Middle: radio config (frequency, BW, SF, CR, TX power, flow control).
//  - Bottom: ID beacon controls.
//
//  Scanning/connecting is delegated to a private `RNodeBluetoothManager`
//  spawned on-demand from the Scan sheet — the editor itself only mutates
//  the persisted `RNodeInterfaceProfile`.
//

import SwiftUI

struct RNodeInterfaceEditorView: View {

    @Binding var name: String
    @Binding var profile: RNodeInterfaceProfile
    let isEditing: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var showScanner = false
    @State private var freqMHzText: String = ""
    @State private var idEnabled: Bool = false
    @State private var idCallsign: String = ""
    @State private var idIntervalMinutes: Double = 60

    var body: some View {
        Form {
            Section("Interface") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
            }

            Section("Bluetooth Device") {
                if profile.peripheralUUID != nil {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(profile.peripheralName.isEmpty ? "RNode" : profile.peripheralName)
                                .foregroundColor(.primary)
                            if let uuid = profile.peripheralUUID {
                                Text(uuid.uuidString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Change") { showScanner = true }
                    }
                } else {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan & Pair", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }

            radioSection
            idBeaconSection
        }
        .navigationTitle(isEditing ? "Edit RNode" : "Add RNode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    flushFormToProfile()
                    onSave()
                }
                .disabled(name.isEmpty)
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                RNodeScannerView { picked in
                    profile.peripheralUUID = picked.id
                    profile.peripheralName = picked.name
                    showScanner = false
                } onCancel: {
                    showScanner = false
                }
            }
        }
        .onAppear { loadFormFromProfile() }
        .onChange(of: freqMHzText)              { _, _ in flushFormToProfile() }
        .onChange(of: idEnabled)                { _, _ in flushFormToProfile() }
        .onChange(of: idCallsign)               { _, _ in flushFormToProfile() }
        .onChange(of: idIntervalMinutes)        { _, _ in flushFormToProfile() }
    }

    @ViewBuilder
    private var radioSection: some View {
        Section("Radio") {
            HStack {
                Text("Frequency")
                Spacer()
                TextField("MHz", text: $freqMHzText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                Text("MHz").foregroundStyle(.secondary)
            }
            Picker("Bandwidth", selection: $profile.radio.bandwidth) {
                ForEach(LoRaBandwidth.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Spreading Factor", selection: $profile.radio.spreadingFactor) {
                ForEach(LoRaSpreadingFactor.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Coding Rate", selection: $profile.radio.codingRate) {
                ForEach(LoRaCodingRate.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("TX power")
                    Spacer()
                    Text("\(Int(profile.radio.txPower)) dBm").foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(profile.radio.txPower) },
                        set: { profile.radio.txPower = UInt8($0.rounded()) }
                    ),
                    in: 0...22, step: 1
                )
            }
            Toggle("Hardware flow control", isOn: $profile.radio.flowControl)
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
            }
        }
    }

    // MARK: - Form ↔ profile sync

    private func loadFormFromProfile() {
        freqMHzText = String(format: "%.3f", Double(profile.radio.frequency) / 1_000_000)
        if let beacon = profile.radio.idBeacon {
            idEnabled = true
            idCallsign = beacon.callsign
            idIntervalMinutes = Double(beacon.intervalSeconds) / 60.0
        } else {
            idEnabled = false
            idCallsign = ""
            idIntervalMinutes = 60
        }
    }

    private func flushFormToProfile() {
        if let mhz = Double(freqMHzText) {
            profile.radio.frequency = UInt64(mhz * 1_000_000)
        }
        if idEnabled, !idCallsign.isEmpty {
            profile.radio.idBeacon = .init(
                intervalSeconds: UInt64(idIntervalMinutes * 60),
                callsign: idCallsign
            )
        } else {
            profile.radio.idBeacon = nil
        }
    }
}

// MARK: - Scanner sheet

/// Lightweight scan-only view that lists discovered RNode-like peripherals
/// and returns the selected one. Uses its own `RNodeBluetoothManager` so it
/// can be torn down cleanly when the sheet closes.
struct RNodeScannerView: View {
    let onPick: (RNodeDiscoveredPeripheral) -> Void
    let onCancel: () -> Void

    @StateObject private var ble = RNodeBluetoothManager()
    @State private var pairingTarget: RNodeDiscoveredPeripheral?

    var body: some View {
        List {
            Section {
                switch ble.state {
                case .scanning:     Text("Scanning…").foregroundStyle(.secondary)
                case .poweredOff:   Text("Bluetooth is off").foregroundStyle(.red)
                case .unauthorized: Text("Bluetooth permission denied").foregroundStyle(.red)
                case .unsupported:  Text("Bluetooth unsupported on this device").foregroundStyle(.red)
                case .pairing:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pairing with \(pairingTarget?.name ?? "RNode")…").bold()
                        Text("Enter the PIN displayed on the RNode when iOS prompts you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .paired(_, let name):
                    Text("Paired with \(name)").foregroundStyle(.green)
                case .error(let m): Text(m).foregroundStyle(.red)
                default:            Text("Tap Scan to begin").foregroundStyle(.secondary)
                }
            }
            if !ble.discovered.isEmpty {
                Section("Devices") {
                    ForEach(ble.discovered) { dev in
                        Button {
                            pairingTarget = dev
                            ble.stopScanning()
                            ble.pair(id: dev.id, name: dev.name)
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
                        .disabled({
                            if case .pairing = ble.state { return true } else { return false }
                        }())
                    }
                }
            }
        }
        .navigationTitle("Scan for RNode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    ble.stopScanning()
                    onCancel()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if case .scanning = ble.state {
                    Button("Stop") { ble.stopScanning() }
                } else if case .pairing = ble.state {
                    EmptyView()
                } else {
                    Button("Scan") { ble.startScanning() }
                }
            }
        }
        .onAppear { ble.startScanning() }
        .onDisappear { ble.stopScanning() }
        .onChange(of: ble.state) { _, newState in
            if case .paired(let id, let name) = newState {
                onPick(RNodeDiscoveredPeripheral(id: id, name: name, rssi: pairingTarget?.rssi ?? 0))
            }
        }
    }
}
