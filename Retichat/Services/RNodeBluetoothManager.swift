//
//  RNodeBluetoothManager.swift
//  Retichat
//
//  Native CoreBluetooth bridge that owns I/O for an RNode device over the
//  Nordic UART BLE service. KISS framing, RNode command codec, and radio
//  configuration all live in Rust — this class only shuttles raw bytes
//  between CoreBluetooth and `rns_rnode_iface_*`.
//
//  Lifecycle:
//    - `startScanning()`  — begin discovering RNodes (filter by NUS service).
//    - `connect(_:)`      — connect to a discovered peripheral. On success:
//        1. discover Nordic UART service + TX/RX characteristics
//        2. subscribe to TX notifications
//        3. call `rns_rnode_iface_register` (which spawns the read loop and
//           runs the DETECT/init handshake)
//    - `disconnect()`     — call `rns_rnode_iface_deregister`, drop the link.
//
//  Threading: all CoreBluetooth callbacks run on a private serial queue. The
//  Rust read loop is on its own thread; outbound byte writes from Rust come
//  in via `cSendCallback` and are dispatched onto the BLE queue.
//

import Foundation
import Combine
import CoreBluetooth
import os.log

/// Nordic UART Service UUIDs used by RNode firmware.
private enum NordicUART {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txChar  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // peripheral -> central, notify
    static let rxChar  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // central -> peripheral, write w/o response
}

/// Maximum bytes per BLE write. NUS implementations on common RNode firmware
/// expect ≤ 20 bytes per write.
private let kMaxWriteChunk = 20

enum RNodeBluetoothState: Equatable {
    case poweredOff
    case unauthorized
    case unsupported
    case idle
    case scanning
    case connecting(peripheralID: UUID)
    case pairing(peripheralID: UUID)
    case paired(peripheralID: UUID, name: String)
    case connected(peripheralID: UUID, handle: UInt64)
    case error(String)
}

struct RNodeDiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

final class RNodeBluetoothManager: NSObject, ObservableObject, @unchecked Sendable {

    @Published private(set) var state: RNodeBluetoothState = .idle
    @Published private(set) var discovered: [RNodeDiscoveredPeripheral] = []
    @Published private(set) var lastStats: RnsRNodeStats?

    /// Most recent radio config used. Persist via `UserPreferences` if desired.
    var radioConfig: RNodeRadioConfig = .default

    private let log = Logger(subsystem: "com.retichat", category: "RNodeBLE")

    private let bleQueue = DispatchQueue(label: "com.retichat.rnode.ble", qos: .userInitiated)
    private var central: CBCentralManager!

    private var connectingPeripheral: CBPeripheral?
    private var activePeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic? // central -> peripheral writes
    private var ifaceHandle: UInt64 = 0
    private var ifaceName: String = ""
    /// Cache of CBPeripherals seen during the current scan, keyed by UUID.
    /// Needed because `retrievePeripherals(withIdentifiers:)` only returns
    /// devices that have been previously connected/bonded — a brand new
    /// scanned peripheral isn't "known" yet until we connect to it once.
    private var discoveredCache: [UUID: CBPeripheral] = [:]
    /// When true, we are doing a one-shot pair flow (connect+enable-notify to
    /// trigger the system PIN dialog). The Rust FFI is NOT registered, and
    /// we disconnect once notifications are enabled (= pairing complete).
    private var isPairOnly: Bool = false
    private var pairingName: String = ""

    /// Polling task that reads stats every second while connected.
    private var statsTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue, options: nil)
    }

    // MARK: - Public API

    func startScanning() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.central.state == .poweredOn else {
                self.log.warning("startScanning ignored: BLE not powered on (state=\(self.central.state.rawValue))")
                return
            }
            self.publishDiscovered([])
            self.publishState(.scanning)
            self.central.scanForPeripherals(
                withServices: [NordicUART.service],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            self.log.info("BLE scanning started")
        }
    }

    func stopScanning() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            // Don't transition state if we're connected/connecting.
            DispatchQueue.main.async {
                if case .scanning = self.state { self.state = .idle }
            }
        }
    }

    func connect(_ id: UUID, name: String) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard let peripheral = self.central.retrievePeripherals(withIdentifiers: [id]).first else {
                self.log.error("connect: peripheral \(id) not retrievable")
                self.publishState(.error("peripheral not available"))
                return
            }
            self.central.stopScan()
            self.connectingPeripheral = peripheral
            self.ifaceName = "rnode-\(name)-\(id.uuidString.prefix(8))"
            self.publishState(.connecting(peripheralID: id))
            peripheral.delegate = self
            self.central.connect(peripheral, options: nil)
            self.log.info("BLE connecting to \(name) (\(id.uuidString))")
        }
    }

    /// One-shot pair flow: connect to the peripheral, enable notifications on
    /// the Nordic UART TX characteristic (which iOS treats as an encrypted
    /// write to the CCCD descriptor and triggers the system PIN dialog), then
    /// disconnect. After this, the device is bonded and `retrievePeripherals`
    /// will return it for future auto-connects by the coordinator.
    func pair(id: UUID, name: String) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            let peripheral = self.discoveredCache[id]
                ?? self.central.retrievePeripherals(withIdentifiers: [id]).first
                ?? self.central.retrieveConnectedPeripherals(withServices: [NordicUART.service]).first(where: { $0.identifier == id })
            guard let peripheral = peripheral else {
                self.log.error("pair: peripheral \(id) not retrievable")
                self.publishState(.error("peripheral not available"))
                return
            }
            self.central.stopScan()
            self.isPairOnly = true
            self.pairingName = name
            self.connectingPeripheral = peripheral
            self.publishState(.pairing(peripheralID: id))
            peripheral.delegate = self
            self.central.connect(peripheral, options: nil)
            self.log.info("BLE pairing with \(name) (\(id.uuidString))")
        }
    }

    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.statsTask?.cancel()
            self.statsTask = nil
            if self.ifaceHandle != 0 {
                _ = rns_rnode_iface_deregister(self.ifaceHandle)
                self.ifaceHandle = 0
            }
            if let p = self.activePeripheral {
                self.central.cancelPeripheralConnection(p)
            }
            self.activePeripheral = nil
            self.rxCharacteristic = nil
            self.connectingPeripheral = nil
            self.publishState(.idle)
            DispatchQueue.main.async { self.lastStats = nil }
        }
    }

    /// Send the RNode ID beacon callsign immediately (if configured).
    func sendIDBeaconNow() {
        bleQueue.async { [weak self] in
            guard let self = self, self.ifaceHandle != 0 else { return }
            _ = rns_rnode_iface_id_beacon_now(self.ifaceHandle)
        }
    }

    // MARK: - Publish helpers (always dispatch to main for @Published)

    private func publishState(_ s: RNodeBluetoothState) {
        DispatchQueue.main.async { self.state = s }
    }
    private func publishDiscovered(_ d: [RNodeDiscoveredPeripheral]) {
        DispatchQueue.main.async { self.discovered = d }
    }

    // MARK: - Outbound bytes (Rust -> BLE)

    /// Trampoline for the C send callback. Runs on the Rust read-loop thread;
    /// hops to the BLE queue to perform the actual writes.
    private static let cSendCallback: RnsRNodeSendFn = { user_data, data, len in
        guard let user_data = user_data, let data = data, len > 0 else { return 1 }
        let mgr = Unmanaged<RNodeBluetoothManager>.fromOpaque(user_data).takeUnretainedValue()
        let buf = UnsafeBufferPointer(start: data, count: Int(len))
        let bytes = Array(buf) // copy off the Rust-owned buffer before queue hop
        mgr.bleQueue.async {
            mgr.writeBytes(bytes)
        }
        return 1
    }

    private func writeBytes(_ bytes: [UInt8]) {
        guard let peripheral = activePeripheral, let rx = rxCharacteristic else {
            log.error("writeBytes: no active peripheral / RX characteristic")
            return
        }
        var idx = 0
        while idx < bytes.count {
            let end = min(idx + kMaxWriteChunk, bytes.count)
            let chunk = Data(bytes[idx..<end])
            peripheral.writeValue(chunk, for: rx, type: .withoutResponse)
            idx = end
        }
    }

    // MARK: - Stats poller

    private func startStatsPolling() {
        statsTask?.cancel()
        let handle = ifaceHandle
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, handle != 0 else { return }
                var stats = RnsRNodeStats()
                let rc = rns_rnode_iface_get_stats(handle, &stats)
                if rc == 0 {
                    let s = stats
                    await MainActor.run { self.lastStats = s }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension RNodeBluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOff:    publishState(.poweredOff)
        case .unauthorized:  publishState(.unauthorized)
        case .unsupported:   publishState(.unsupported)
        case .poweredOn:
            DispatchQueue.main.async {
                if case .error = self.state { self.state = .idle }
                else if self.state == .poweredOff { self.state = .idle }
            }
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "RNode"
        let rssi = RSSI.intValue
        discoveredCache[id] = peripheral
        DispatchQueue.main.async {
            if let idx = self.discovered.firstIndex(where: { $0.id == id }) {
                self.discovered[idx] = RNodeDiscoveredPeripheral(id: id, name: name, rssi: rssi)
            } else {
                self.discovered.append(RNodeDiscoveredPeripheral(id: id, name: name, rssi: rssi))
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([NordicUART.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "connect failed"
        publishState(.error(msg))
        connectingPeripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        statsTask?.cancel()
        statsTask = nil
        if ifaceHandle != 0 {
            _ = rns_rnode_iface_deregister(ifaceHandle)
            ifaceHandle = 0
        }
        activePeripheral = nil
        rxCharacteristic = nil
        DispatchQueue.main.async { self.lastStats = nil }
        // If we just completed a pair-only flow we already published .paired;
        // do not overwrite that with .idle/.error.
        if case .paired = self.state { return }
        if let error = error {
            publishState(.error(error.localizedDescription))
        } else {
            publishState(.idle)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RNodeBluetoothManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            publishState(.error(error.localizedDescription))
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == NordicUART.service }) else {
            publishState(.error("Nordic UART service missing"))
            return
        }
        peripheral.discoverCharacteristics([NordicUART.txChar, NordicUART.rxChar], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            publishState(.error(error.localizedDescription))
            return
        }
        guard let chars = service.characteristics else { return }
        // Standard Nordic UART has TX = 0x0002 (notify) and RX = 0x0003 (write
        // without response), but some RNode firmwares ship with these swapped.
        // Pick by *properties* instead of trusting the UUID order.
        let notifyChar = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        let writeChar = chars.first {
            $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write)
        }
        guard let tx = notifyChar, let rx = writeChar else {
            publishState(.error("RNode UART characteristics missing"))
            return
        }
        // setNotifyValue triggers a write to the CCCD descriptor; because the
        // RNode firmware marks the TX characteristic SECMODE_ENC_WITH_MITM,
        // iOS prompts the user for the PIN displayed on the radio here.
        peripheral.setNotifyValue(true, for: tx)
        rxCharacteristic = rx
        if !isPairOnly {
            registerInterface(peripheralID: peripheral.identifier)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else { return }
        if let error = error {
            // Most likely the user cancelled the PIN dialog or entered the
            // wrong code: iOS reports an authentication error here.
            log.error("setNotify failed: \(error.localizedDescription, privacy: .public)")
            publishState(.error("Pairing failed: \(error.localizedDescription)"))
            isPairOnly = false
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if isPairOnly {
            // Pairing complete — OS bonded the device. Drop the link; the
            // coordinator will reconnect on next service start.
            let id = peripheral.identifier
            let name = pairingName
            log.info("Pairing complete with \(name, privacy: .public) (\(id.uuidString))")
            publishState(.paired(peripheralID: id, name: name))
            isPairOnly = false
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate),
              let data = characteristic.value, !data.isEmpty else { return }
        let handle = ifaceHandle
        guard handle != 0 else { return }
        data.withUnsafeBytes { buf in
            if let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                _ = rns_rnode_iface_feed(handle, base, UInt32(data.count))
            }
        }
    }

    /// Run on `bleQueue` (called from the characteristics-discovery delegate).
    private func registerInterface(peripheralID: UUID) {
        guard ifaceHandle == 0 else { return }
        let unmanaged = Unmanaged.passUnretained(self)
        let userData = unmanaged.toOpaque()

        let handle: UInt64 = ifaceName.withCString { namePtr in
            radioConfig.withCConfig { cfg in
                var cfg = cfg
                return rns_rnode_iface_register(namePtr, RNodeBluetoothManager.cSendCallback, userData, &cfg)
            }
        }
        if handle == 0 {
            let err = lastError() ?? "unknown error"
            log.error("rns_rnode_iface_register failed: \(err)")
            publishState(.error("RNode register failed: \(err)"))
            if let p = activePeripheral { central.cancelPeripheralConnection(p) }
            return
        }
        ifaceHandle = handle
        publishState(.connected(peripheralID: peripheralID, handle: handle))
        startStatsPolling()
        log.info("RNode interface registered: \(self.ifaceName, privacy: .public) handle=\(handle)")
    }

    private func lastError() -> String? {
        guard let cstr = rns_last_error() else { return nil }
        defer { rns_free_string(cstr) }
        return String(cString: cstr)
    }
}
