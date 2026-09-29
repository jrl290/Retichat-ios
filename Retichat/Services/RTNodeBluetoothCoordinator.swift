//
//  RTNodeBluetoothCoordinator.swift
//  Retichat
//
//  Bluetooth link to any RTNode in range, with no configuration: the Prns
//  native protocol, from the dialer's (GATT central's) side.
//
//  Retichat is only ever the central. It advertises nothing and hosts no
//  GATT service, so no phone can connect to it; it dials RTNodes only
//  (their advertisement carries the Prns peripheral-only flag).
//
//  The protocol lives in Reticulum-rust (`interfaces::prns_ble`, the
//  `rns_prns_ble_*` C API): which advertisement to dial, the handshake,
//  fragments, and one Reticulum interface per RTNode. This class is the
//  radio: it scans when the engine asks, reports each advertisement,
//  connects when the engine hands back a link, discovers the service,
//  subscribes, performs the writes it is asked for, and reports every event.
//  It keeps no timers and never re-dials on its own: the engine decides.
//
//  Started by ChatRepository.finishStartService() after the delivery
//  destination is published, and only when the Nearby RTNode switch is on
//  (off by default); stopped by ChatRepository.stopService() before the
//  stack shuts down. Both on ChatRepository's ffiQueue. The CBCentralManager,
//  which is what asks for Bluetooth permission, is created in start() and
//  nowhere else, so a user who never turns the switch on is never asked.
//

import Foundation
import CoreBluetooth
import Combine
import os.log

/// What the Nearby RTNode card in Settings shows.
enum RTNodeBluetoothStatus: Equatable {
    /// The switch is off, or the stack is not running.
    case off
    /// Scanning for an RTNode.
    case searching
    /// Dialling or handshaking with one.
    case connecting
    /// Linked; the RTNode's Bluetooth identity, first 8 hex digits.
    case connected(String)
    /// Bluetooth is off, not permitted or unsupported, or the engine failed.
    case unavailable(String)
}

/// The Prns service and its characteristics (Reticulum-rust
/// `interfaces/prns_ble/wire.rs`).
nonisolated enum PrnsBluetoothUUID {
    static let service = CBUUID(string: "37145B00-442D-4A94-917F-8F42C5DA28E3")
    static let control = CBUUID(string: "37145B00-442D-4A94-917F-8F42C5DA28E7")
    static let data = CBUUID(string: "37145B00-442D-4A94-917F-8F42C5DA28E8")
}

nonisolated final class RTNodeBluetoothCoordinator: NSObject, ObservableObject, @unchecked Sendable {

    static let shared = RTNodeBluetoothCoordinator()

    /// What Settings shows; changed on the main actor only.
    @MainActor @Published private(set) var status: RTNodeBluetoothStatus = .off

    private let log = Logger(subsystem: "com.retichat", category: "RTNodeBLE")
    private let queue = DispatchQueue(label: "com.retichat.rtnode.ble", qos: .userInitiated)

    /// One dial or connection, under the engine's link id.
    private final class Node {
        let link: UInt64
        let peripheral: CBPeripheral
        var control: CBCharacteristic?
        var data: CBCharacteristic?

        init(link: UInt64, peripheral: CBPeripheral) {
            self.link = link
            self.peripheral = peripheral
        }
    }

    // Confined to `queue`.
    private var central: CBCentralManager?
    private var running = false
    /// The engine's last word on scanning (it wants to from the start).
    private var scanWanted = false
    private var nodes: [UInt64: Node] = [:]

    // Confined to the caller of start/stop (ChatRepository's ffiQueue).
    private var engineRunning = false

    // MARK: - Lifecycle (ChatRepository's ffiQueue)

    /// `storageDir` keeps the phone's Bluetooth identity (`ble_identity`);
    /// `endpointHost` is the Prns endpoint host byte: iOS 1, iPadOS 2,
    /// macOS 0.
    func start(storageDir: String, endpointHost: UInt8) {
        guard !engineRunning else { return }
        var identity = [UInt8](repeating: 0, count: 16)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let rc = storageDir.withCString { dir in
            rns_prns_ble_start(dir, 1, endpointHost,
                               Self.scanCallback, Self.writeCallback,
                               Self.disconnectCallback, Self.stateCallback,
                               context, &identity)
        }
        guard rc == 0 else {
            let why = Self.lastError()
            say("Bluetooth did not start: \(why)")
            publish(.unavailable("Bluetooth did not start: \(why)"))
            return
        }
        engineRunning = true
        say("started, Bluetooth identity \(Self.hex(identity))")
        queue.async { [self] in
            running = true
            scanWanted = true
            if let central {
                bluetoothStateChanged(central)
            } else {
                // No power alert: Bluetooth being off is shown in Settings.
                central = CBCentralManager(delegate: self, queue: queue,
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
        }
    }

    /// Closes the link and removes the RTNode's interface. Blocks until the
    /// engine has let go of it, so the stack can shut down after.
    func stop() {
        queue.sync { [self] in
            running = false
            if central?.state == .poweredOn { central?.stopScan() }
        }
        if engineRunning {
            rns_prns_ble_stop()
            engineRunning = false
        }
        queue.sync { [self] in
            for node in nodes.values {
                central?.cancelPeripheralConnection(node.peripheral)
            }
            nodes.removeAll()
        }
        publish(.off)
        say("stopped")
    }

    // MARK: - Engine callbacks (any thread; hop to `queue`)

    private static let scanCallback: RnsPrnsBleScanFn = { context, on in
        guard let context else { return }
        let me = Unmanaged<RTNodeBluetoothCoordinator>.fromOpaque(context).takeUnretainedValue()
        me.queue.async {
            me.scanWanted = on != 0
            me.applyScan()
        }
    }

    private static let writeCallback: RnsPrnsBleWriteFn = { context, link, characteristic, data, len in
        guard let context else { return }
        let me = Unmanaged<RTNodeBluetoothCoordinator>.fromOpaque(context).takeUnretainedValue()
        let bytes = data.map { Data(bytes: $0, count: Int(len)) } ?? Data()
        me.queue.async { me.write(link: link, characteristic: characteristic, bytes: bytes) }
    }

    private static let disconnectCallback: RnsPrnsBleDisconnectFn = { context, link in
        guard let context else { return }
        let me = Unmanaged<RTNodeBluetoothCoordinator>.fromOpaque(context).takeUnretainedValue()
        me.queue.async {
            // The engine has already forgotten the link: no link_closed.
            guard let node = me.nodes.removeValue(forKey: link) else { return }
            me.central?.cancelPeripheralConnection(node.peripheral)
            me.publishIdle()
        }
    }

    private static let stateCallback: RnsPrnsBleStateFn = { context, link, state, peer, name in
        guard let context else { return }
        let me = Unmanaged<RTNodeBluetoothCoordinator>.fromOpaque(context).takeUnretainedValue()
        let peerHex = peer.map { p in RTNodeBluetoothCoordinator.hex((0..<16).map { p[$0] }) }
        let interface = name.map { String(cString: $0) }
        me.queue.async { me.linkState(link: link, state: state, peer: peerHex, interface: interface) }
    }

    // MARK: - Queue-confined work

    private func write(link: UInt64, characteristic: UInt8, bytes: Data) {
        guard let node = nodes[link],
              let target = characteristic == 0 ? node.control : node.data else {
            // Link gone or not set up: the write cannot happen.
            _ = rns_prns_ble_link_write_done(link, 0)
            return
        }
        // With response: RTNode's characteristics are write-with-response,
        // and the response is what paces the next fragment.
        node.peripheral.writeValue(bytes, for: target, type: .withResponse)
    }

    private func linkState(link: UInt64, state: Int32, peer: String?, interface: String?) {
        guard nodes[link] != nil else { return }
        switch state {
        case 1:
            say("link \(link): settled with RTNode \(peer ?? "?"), interface \(interface ?? "?")")
            publish(.connected(String((peer ?? "").prefix(8))))
        case 0, 3:
            publish(.connecting)
        default:
            break
        }
    }

    private func applyScan() {
        guard let central, central.state == .poweredOn else { return }
        if running && scanWanted {
            // Duplicates: after a failed dial the engine pauses that node,
            // and only a later advertisement can bring it back (foreground;
            // iOS coalesces sightings in the background).
            central.scanForPeripherals(withServices: [PrnsBluetoothUUID.service],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            central.stopScan()
        }
    }

    private func bluetoothStateChanged(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            applyScan()
            publishIdle()
        case .poweredOff:
            dropAll()
            publish(.unavailable("Bluetooth is off"))
        case .unauthorized:
            dropAll()
            publish(.unavailable("Bluetooth is not allowed for Retichat"))
        case .unsupported:
            dropAll()
            publish(.unavailable("This device has no Bluetooth LE"))
        default:
            // Resetting or unknown: the next state change says what next.
            dropAll()
        }
    }

    /// Bluetooth went away and took every connection with it.
    private func dropAll() {
        for node in nodes.values {
            _ = rns_prns_ble_link_closed(node.link)
        }
        nodes.removeAll()
    }

    private func node(for peripheral: CBPeripheral) -> Node? {
        nodes.values.first { $0.peripheral.identifier == peripheral.identifier }
    }

    /// The connection or the attempt is gone: tell the engine.
    private func closed(_ node: Node) {
        nodes.removeValue(forKey: node.link)
        _ = rns_prns_ble_link_closed(node.link)
        publishIdle()
    }

    /// Setting the link up failed: drop the connection and tell the engine.
    private func fail(_ node: Node, _ why: String) {
        say("link \(node.link): \(why)")
        central?.cancelPeripheralConnection(node.peripheral)
        closed(node)
    }

    private func publishIdle() {
        guard nodes.isEmpty else { return }
        publish(running ? .searching : .off)
    }

    /// In the order called: the main queue is serial.
    private func publish(_ status: RTNodeBluetoothStatus) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                if self.status != status { self.status = status }
            }
        }
    }

    /// To stdout, where the app's other diagnostics and Rust's [PRNS-BLE]
    /// lines go, and to the unified log.
    private func say(_ message: String) {
        print("[RTNodeBLE] \(message)")
        log.notice("\(message, privacy: .public)")
    }

    private static func lastError() -> String {
        guard let c = rns_last_error() else { return "unknown error" }
        defer { rns_free_string(c) }
        return String(cString: c)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CBCentralManagerDelegate

nonisolated extension RTNodeBluetoothCoordinator: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothStateChanged(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running,
              node(for: peripheral) == nil,
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let link = manufacturer.withUnsafeBytes { raw in
            peripheral.identifier.uuidString.withCString { address in
                rns_prns_ble_sighted(address, raw.bindMemory(to: UInt8.self).baseAddress,
                                     UInt32(manufacturer.count))
            }
        }
        guard link != 0 else { return }
        nodes[link] = Node(link: link, peripheral: peripheral)
        peripheral.delegate = self
        say("link \(link): dialling RTNode \(peripheral.identifier.uuidString), RSSI \(RSSI.intValue)")
        publish(.connecting)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard node(for: peripheral) != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverServices([PrnsBluetoothUUID.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let node = node(for: peripheral) else { return }
        say("link \(node.link): connect failed: \(error?.localizedDescription ?? "no error given")")
        closed(node)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let node = node(for: peripheral) else { return }
        say("link \(node.link): disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        closed(node)
    }
}

// MARK: - CBPeripheralDelegate

nonisolated extension RTNodeBluetoothCoordinator: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let node = node(for: peripheral) else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == PrnsBluetoothUUID.service }) else {
            fail(node, "service discovery: \(error?.localizedDescription ?? "no Prns service")")
            return
        }
        peripheral.discoverCharacteristics([PrnsBluetoothUUID.control, PrnsBluetoothUUID.data], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let node = node(for: peripheral) else { return }
        node.control = service.characteristics?.first { $0.uuid == PrnsBluetoothUUID.control }
        node.data = service.characteristics?.first { $0.uuid == PrnsBluetoothUUID.data }
        guard error == nil, let control = node.control, node.data != nil else {
            fail(node, "characteristic discovery: \(error?.localizedDescription ?? "control or data characteristic missing")")
            return
        }
        // Control, then data, as Prns dialers do; the Hello only after both
        // subscriptions are confirmed, since the Welcome is a notification.
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let node = node(for: peripheral) else { return }
        if let error {
            fail(node, "subscribe: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else { return }
        if characteristic.uuid == PrnsBluetoothUUID.control, let data = node.data {
            peripheral.setNotifyValue(true, for: data)
        } else if characteristic.uuid == PrnsBluetoothUUID.data {
            // One ATT PDU's worth: a larger with-response write would become
            // an ATT long write, which Prns peers do not handle.
            let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
            if rns_prns_ble_link_ready(node.link, UInt32(maxWrite)) != 0 {
                fail(node, "link_ready: \(Self.lastError())")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let node = node(for: peripheral), error == nil, let value = characteristic.value else { return }
        let which: UInt8 = characteristic.uuid == PrnsBluetoothUUID.control ? 0 : 1
        value.withUnsafeBytes { raw in
            _ = rns_prns_ble_link_received(node.link, which, raw.bindMemory(to: UInt8.self).baseAddress,
                                           UInt32(value.count))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let node = node(for: peripheral) else { return }
        if let error {
            say("link \(node.link): write failed: \(error.localizedDescription)")
        }
        _ = rns_prns_ble_link_write_done(node.link, error == nil ? 1 : 0)
    }
}
