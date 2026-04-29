//
//  RNodeInterfaceCoordinator.swift
//  Retichat
//
//  Lifecycle owner for *saved* RNode interfaces, run alongside TCP interfaces
//  during the Reticulum service lifetime.
//
//  Responsibilities:
//    - Walk all enabled `InterfaceConfigEntity` rows of type RNode.
//    - Maintain a long-lived CBCentralManager that connects to each saved
//      peripheral by UUID (no re-scan needed — the system caches).
//    - On connection: discover the Nordic UART service, subscribe to TX,
//      and call `rns_rnode_iface_register` with the row's saved
//      `RNodeInterfaceProfile`.
//    - On disconnect / failure: schedule an exponential-backoff reconnect.
//    - On `stop()`: deregister all interfaces and drop BLE links.
//
//  Started by ChatRepository.finishStartService(); stopped by
//  ChatRepository.stopService() (and implicitly restarted on every Apply).
//
//  Independent from the per-screen `RNodeBluetoothManager` used by Settings'
//  scanner/editor — that one is short-lived and UI-driven; this one is the
//  background service for production use.
//

import Foundation
import CoreBluetooth
import Combine
import os.log

/// Public per-slot lifecycle state, used by the Settings UI to render the
/// row's status indicator. Follows the project-wide convention:
///   - .idle:        grey  (after reset / before first try)
///   - .connecting,
///     .configuring: yellow (in-progress)
///   - .ready:       green  (configured and operational)
///   - .failed:      red    (attempt made and failed)
enum RNodeSlotStatus: Equatable {
    case idle
    case connecting
    case configuring
    case ready
    case failed
}

/// Nordic UART Service UUIDs as used by RNode firmware.
private enum NUS {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txChar  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // peripheral -> central, notify
    static let rxChar  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // central -> peripheral, write w/o response
}

/// 20-byte BLE write chunk. NUS firmware on common RNodes expects writes ≤ 20.
private let kMaxWriteChunk = 20

/// Per-slot heap context handed to Rust as `user_data`. Allocated on slot
/// registration, freed on deregistration. We pass an `Unmanaged` reference
/// so the lifetime is explicit.
private final class TxContext {
    weak var coordinator: RNodeInterfaceCoordinator?
    let slotID: String
    init(coordinator: RNodeInterfaceCoordinator, slotID: String) {
        self.coordinator = coordinator
        self.slotID = slotID
    }
}

/// Per-row state held by the coordinator.
private final class RNodeSlot {
    let id: String                  // InterfaceConfigEntity.id
    let name: String                // FFI interface name
    let peripheralUUID: UUID
    let profile: RNodeInterfaceProfile

    var peripheral: CBPeripheral?
    var rxChar: CBCharacteristic?
    /// Cached write type to use for this peripheral. Defaults to
    /// `.withoutResponse` for performance but falls back to `.withResponse`
    /// when the RX characteristic doesn't advertise that property.
    var rxWriteType: CBCharacteristicWriteType = .withoutResponse
    var ifaceHandle: UInt64 = 0
    /// Owned by us; held while the iface is registered, released on dereg.
    var txContext: Unmanaged<TxContext>?
    var connecting: Bool = false
    /// Set true once `setNotifyValue(true)` is confirmed by the firmware;
    /// at that point we kick off the FFI register on a background thread.
    var subscribed: Bool = false
    /// True while a background `rns_rnode_iface_register` call is in flight.
    /// Inbound notification bytes that arrive during this window are buffered
    /// in `pendingInboundBytes` and drained once the handle is available.
    var registerInFlight: Bool = false
    var pendingInboundBytes: [Data] = []
    var backoffSeconds: Int = 1     // doubles up to 60
    var pendingReconnect: DispatchWorkItem?

    init(id: String, name: String, peripheralUUID: UUID, profile: RNodeInterfaceProfile) {
        self.id = id
        self.name = name
        self.peripheralUUID = peripheralUUID
        self.profile = profile
    }
}

/// Background queue used to drive blocking FFI calls (the RNode DETECT/init
/// handshake sleeps for several seconds inside `rns_rnode_iface_register`).
/// MUST NOT be the same as the `CBCentralManager` delegate queue, otherwise
/// inbound BLE notifications cannot be delivered while register is blocked,
/// producing a deadlock that surfaces as "Could not detect RNode device".
private let rnodeFFIQueue = DispatchQueue(
    label: "com.retichat.rnode.ffi",
    qos: .userInitiated
)

final class RNodeInterfaceCoordinator: NSObject, ObservableObject {

    static let shared = RNodeInterfaceCoordinator()

    /// Per-slot lifecycle status keyed by `InterfaceConfigEntity.id`.
    /// Always mutated on the main actor so SwiftUI views observing this
    /// object update without thread-confinement warnings.
    @Published private(set) var slotStatuses: [String: RNodeSlotStatus] = [:]

    /// Read the current status for a saved RNode row. Returns `.idle` if the
    /// coordinator hasn't seen the row yet (e.g. before service start, or
    /// before Apply for a freshly added row).
    func status(forID id: String) -> RNodeSlotStatus {
        slotStatuses[id] ?? .idle
    }

    /// Hop to the main actor and publish a status change. Safe to call from
    /// any of our internal queues.
    private func setStatus(_ status: RNodeSlotStatus, for slotID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.slotStatuses[slotID] != status {
                self.slotStatuses[slotID] = status
            }
        }
    }

    private func clearStatus(for slotID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.slotStatuses.removeValue(forKey: slotID)
        }
    }

    private let log = Logger(subsystem: "com.retichat", category: "RNodeCoord")
    private let queue = DispatchQueue(label: "com.retichat.rnode.coord", qos: .userInitiated)

    private var central: CBCentralManager?
    /// Slots keyed by peripheral UUID for fast lookup from delegate callbacks.
    private var slots: [UUID: RNodeSlot] = [:]
    private var started = false
    /// Slots discovered before BLE was powered on; connect once it is.
    private var pendingConnects: [UUID] = []

    // MARK: - Public API

    /// Spin up the coordinator with the given saved RNode interface rows.
    /// Idempotent: a no-op if already started — call `stop()` first to
    /// reload after settings changes (Apply does this via service restart).
    func start(with rows: [(id: String, name: String, configJSON: String?)]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.started else { return }
            self.started = true

            // Build slots from rows that have a paired peripheral UUID.
            for row in rows {
                guard let p = RNodeInterfaceProfile(jsonString: row.configJSON),
                      let uuid = p.peripheralUUID else {
                    self.log.info("RNode row '\(row.name, privacy: .public)' has no paired peripheral — skipping auto-connect")
                    continue
                }
                let slot = RNodeSlot(id: row.id, name: row.name, peripheralUUID: uuid, profile: p)
                self.slots[uuid] = slot
                self.pendingConnects.append(uuid)
                // Visible state until BLE actually starts connecting.
                self.setStatus(.connecting, for: slot.id)
            }

            if self.slots.isEmpty {
                self.log.info("No RNode interfaces to start")
                return
            }

            // Lazily create the CBCentralManager on our queue.
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue, options: nil)
            } else if self.central?.state == .poweredOn {
                self.flushPendingConnects()
            }
            self.log.info("RNodeInterfaceCoordinator started with \(self.slots.count) slot(s)")
        }
    }

    /// Tear down all RNode interfaces and BLE links.
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.started else { return }
            self.started = false

            for slot in self.slots.values {
                slot.pendingReconnect?.cancel()
                slot.pendingReconnect = nil
                self.deregisterInterface(slot: slot)
                if let p = slot.peripheral {
                    self.central?.cancelPeripheralConnection(p)
                }
                self.clearStatus(for: slot.id)
            }
            self.slots.removeAll()
            self.pendingConnects.removeAll()
            self.log.info("RNodeInterfaceCoordinator stopped")
        }
    }

    /// Stop a single slot (used by deleteInterface in ChatRepository so the
    /// coordinator releases its CBPeripheral and Rust handle for that row).
    /// Safe to call with an unknown id.
    func stopSlot(id: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let (uuid, slot) = self.slots.first(where: { $0.value.id == id }) else { return }
            slot.pendingReconnect?.cancel()
            slot.pendingReconnect = nil
            self.deregisterInterface(slot: slot)
            if let p = slot.peripheral {
                self.central?.cancelPeripheralConnection(p)
            }
            self.slots.removeValue(forKey: uuid)
            self.clearStatus(for: slot.id)
            self.log.info("RNodeInterfaceCoordinator stopped slot id=\(id, privacy: .public)")
        }
    }

    // MARK: - Private

    /// Must be called on `queue`.
    private func flushPendingConnects() {
        guard let central = central, central.state == .poweredOn else { return }
        let uuids = pendingConnects
        pendingConnects.removeAll()
        let peripherals = central.retrievePeripherals(withIdentifiers: uuids)
        for p in peripherals {
            guard let slot = slots[p.identifier], slot.peripheral == nil else { continue }
            slot.peripheral = p
            p.delegate = self
            connect(slot: slot)
        }
        // Any UUID we asked for but the system doesn't know about: requeue
        // for retry later (user may need to re-pair via Scan & Pair).
        let known = Set(peripherals.map(\.identifier))
        for uuid in uuids where !known.contains(uuid) {
            log.warning("RNode peripheral \(uuid) unknown to system — re-pair via Scan & Pair")
            if let slot = slots[uuid] {
                scheduleReconnect(slot: slot, after: 30)
            }
        }
    }

    /// Must be called on `queue`.
    private func connect(slot: RNodeSlot) {
        guard let central = central, let peripheral = slot.peripheral else { return }
        guard !slot.connecting else { return }
        slot.connecting = true
        log.info("Connecting to RNode '\(slot.name, privacy: .public)' (\(slot.peripheralUUID))")
        setStatus(.connecting, for: slot.id)
        central.connect(peripheral, options: nil)
    }

    /// Must be called on `queue`.
    private func scheduleReconnect(slot: RNodeSlot, after seconds: Int? = nil) {
        let delay = seconds ?? slot.backoffSeconds
        slot.backoffSeconds = min(slot.backoffSeconds * 2, 60)
        slot.pendingReconnect?.cancel()
        let work = DispatchWorkItem { [weak self, weak slot] in
            guard let self = self, let slot = slot, self.started else { return }
            // If we already have a peripheral we previously connected to, reuse it;
            // otherwise re-resolve via retrievePeripherals.
            if slot.peripheral == nil, let central = self.central, central.state == .poweredOn {
                if let p = central.retrievePeripherals(withIdentifiers: [slot.peripheralUUID]).first {
                    slot.peripheral = p
                    p.delegate = self
                }
            }
            if slot.peripheral != nil {
                self.connect(slot: slot)
            } else {
                self.scheduleReconnect(slot: slot)
            }
        }
        slot.pendingReconnect = work
        log.info("RNode '\(slot.name, privacy: .public)' reconnect in \(delay)s")
        queue.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }

    /// Must be called on `queue`. Resets state after a disconnect.
    private func handleDisconnect(slot: RNodeSlot, error: Error?) {
        slot.connecting = false
        slot.subscribed = false
        slot.registerInFlight = false
        slot.pendingInboundBytes.removeAll()
        deregisterInterface(slot: slot)
        slot.rxChar = nil
        if let err = error {
            log.warning("RNode '\(slot.name, privacy: .public)' disconnected: \(err.localizedDescription, privacy: .public)")
            setStatus(.failed, for: slot.id)
        } else {
            log.info("RNode '\(slot.name, privacy: .public)' disconnected")
            setStatus(.idle, for: slot.id)
        }
        if started {
            scheduleReconnect(slot: slot)
        }
    }

    /// Bytes from Rust (KISS-framed) to BLE. Runs on whatever thread Rust
    /// happens to call us on; we hop to `queue` for the BLE writes.
    private static let cSendCallback: RnsRNodeSendFn = { user_data, data, len in
        guard let user_data = user_data, let data = data, len > 0 else { return 1 }
        let ctx = Unmanaged<TxContext>.fromOpaque(user_data).takeUnretainedValue()
        guard let coord = ctx.coordinator else { return 0 }
        let slotID = ctx.slotID
        let buf = UnsafeBufferPointer(start: data, count: Int(len))
        let bytes = Array(buf)
        coord.queue.async {
            coord.log.info("TX -> '\(slotID, privacy: .public)' \(bytes.count) bytes: \(bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)\(bytes.count > 16 ? " ..." : "")")
            coord.writeBytes(bytes, slotID: slotID)
        }
        return 1
    }

    /// Must be called on `queue`.
    private func writeBytes(_ bytes: [UInt8], slotID: String) {
        guard let slot = slots.values.first(where: { $0.id == slotID }) else { return }
        guard let peripheral = slot.peripheral, let rx = slot.rxChar else {
            log.error("writeBytes: slot '\(slot.name, privacy: .public)' has no active peripheral/RX char")
            return
        }
        if peripheral.state != .connected {
            log.error("writeBytes: peripheral state is \(peripheral.state.rawValue) (not .connected) for '\(slot.name, privacy: .public)' — skipping \(bytes.count) bytes")
            return
        }
        var idx = 0
        var chunkCount = 0
        while idx < bytes.count {
            let end = min(idx + kMaxWriteChunk, bytes.count)
            let chunk = Data(bytes[idx..<end])
            peripheral.writeValue(chunk, for: rx, type: slot.rxWriteType)
            idx = end
            chunkCount += 1
        }
        log.info("writeBytes: '\(slot.name, privacy: .public)' wrote \(bytes.count) bytes in \(chunkCount) chunk(s) via \(slot.rxWriteType == .withoutResponse ? "NORESP" : "RESP", privacy: .public)")
    }

    /// Two-phase RNode bring-up:
    ///   1. `rns_rnode_iface_create` (fast, on coord queue) returns the handle
    ///      and spawns the Rust read loop. We assign `slot.ifaceHandle` and
    ///      from this point on `didUpdateValueFor` can feed RX bytes.
    ///   2. `rns_rnode_iface_configure` (blocking ~2-4s, on `rnodeFFIQueue`)
    ///      runs the DETECT/init handshake. While it blocks the FFI thread,
    ///      the BLE delegate queue (which is `self.queue`) stays free to
    ///      deliver inbound notifications, which we feed straight into Rust
    ///      via the handle.
    /// Must be called on `queue`.
    private func startRegisterInterface(slot: RNodeSlot) {
        guard slot.ifaceHandle == 0, !slot.registerInFlight else { return }
        slot.registerInFlight = true

        let ctx = TxContext(coordinator: self, slotID: slot.id)
        let unmanaged = Unmanaged.passRetained(ctx)
        slot.txContext = unmanaged
        let userData = unmanaged.toOpaque()
        let name = slot.name
        let radio = slot.profile.radio

        // Phase 1: synchronous create on coord queue.
        let handle: UInt64 = name.withCString { namePtr in
            radio.withCConfig { cfg in
                var cfg = cfg
                return rns_rnode_iface_create(
                    namePtr,
                    RNodeInterfaceCoordinator.cSendCallback,
                    userData,
                    &cfg
                )
            }
        }
        if handle == 0 {
            let err = lastFFIError() ?? "unknown error"
            log.error("rns_rnode_iface_create('\(name, privacy: .public)') failed: \(err, privacy: .public)")
            unmanaged.release()
            slot.txContext = nil
            slot.registerInFlight = false
            setStatus(.failed, for: slot.id)
            if let p = slot.peripheral {
                central?.cancelPeripheralConnection(p)
            }
            return
        }
        slot.ifaceHandle = handle
        log.info("RNode interface '\(name, privacy: .public)' created (handle=\(handle)); running configure")
        setStatus(.configuring, for: slot.id)

        // Phase 2: blocking configure on dedicated FFI queue.
        let slotID = slot.id
        rnodeFFIQueue.async { [weak self] in
            let rc = rns_rnode_iface_configure(handle)
            self?.queue.async { [weak self] in
                guard let self = self else { return }
                guard let slot = self.slots.values.first(where: { $0.id == slotID }) else {
                    // Slot torn down while configuring — clean up.
                    _ = rns_rnode_iface_deregister(handle)
                    return
                }
                slot.registerInFlight = false
                if rc != 0 {
                    let err = self.lastFFIError() ?? "unknown error"
                    self.log.error("rns_rnode_iface_configure('\(name, privacy: .public)') failed: \(err, privacy: .public)")
                    self.deregisterInterface(slot: slot)
                    self.setStatus(.failed, for: slot.id)
                    if let p = slot.peripheral {
                        self.central?.cancelPeripheralConnection(p)
                    }
                    return
                }
                slot.backoffSeconds = 1
                self.setStatus(.ready, for: slot.id)
                self.log.info("RNode interface '\(name, privacy: .public)' configured and ready")
            }
        }
    }

    /// Must be called on `queue`. Deregisters the Rust interface and frees
    /// the TX context.
    private func deregisterInterface(slot: RNodeSlot) {
        if slot.ifaceHandle != 0 {
            _ = rns_rnode_iface_deregister(slot.ifaceHandle)
            slot.ifaceHandle = 0
        }
        if let ctx = slot.txContext {
            ctx.release()
            slot.txContext = nil
        }
    }

    private func lastFFIError() -> String? {
        guard let cstr = rns_last_error() else { return nil }
        defer { rns_free_string(cstr) }
        return String(cString: cstr)
    }
}

// MARK: - CBCentralManagerDelegate

extension RNodeInterfaceCoordinator: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.info("BLE powered on; flushing pending RNode connects")
            flushPendingConnects()
        case .poweredOff:
            log.warning("BLE powered off")
        case .unauthorized:
            log.error("BLE unauthorized — RNode interfaces will not connect")
        case .unsupported:
            log.error("BLE unsupported on this device")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let slot = slots[peripheral.identifier] else { return }
        log.info("BLE connected: '\(slot.name, privacy: .public)'")
        peripheral.delegate = self
        peripheral.discoverServices([NUS.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let slot = slots[peripheral.identifier] else { return }
        slot.connecting = false
        log.warning("RNode '\(slot.name, privacy: .public)' connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        setStatus(.failed, for: slot.id)
        scheduleReconnect(slot: slot)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let slot = slots[peripheral.identifier] else { return }
        handleDisconnect(slot: slot, error: error)
    }
}

// MARK: - CBPeripheralDelegate

extension RNodeInterfaceCoordinator: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let slot = slots[peripheral.identifier] else { return }
        if let error = error {
            log.error("discoverServices error on '\(slot.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == NUS.service }) else {
            log.error("'\(slot.name, privacy: .public)' missing Nordic UART service")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([NUS.txChar, NUS.rxChar], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let slot = slots[peripheral.identifier] else { return }
        if let error = error {
            log.error("discoverCharacteristics error on '\(slot.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard let chars = service.characteristics else { return }
        // Detect by properties — some RNode firmwares ship with the standard
        // NUS UUIDs swapped, so trust .notify/.write properties not the UUID order.
        let tx = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        let rx = chars.first {
            $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write)
        }
        guard let tx = tx, let rx = rx else {
            log.error("'\(slot.name, privacy: .public)' missing UART characteristics")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        slot.rxChar = rx
        slot.rxWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        self.log.info("'\(slot.name, privacy: .public)' RX writeType=\(slot.rxWriteType == .withoutResponse ? "withoutResponse" : "withResponse", privacy: .public)")
        // Gate register on the firmware confirming the TX subscription —
        // we don't want to start writing DETECT bytes that the device may drop
        // because notifications aren't yet active.
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let slot = slots[peripheral.identifier] else { return }
        if let error = error {
            // Most common cause: the user hasn't paired the device yet (the
            // RNode firmware enforces SECMODE_ENC_WITH_MITM on the UART
            // characteristics). Don't keep hammering BLE — back off hard and
            // let the next service start try again after the user pairs via
            // the Settings editor.
            log.error("setNotify failed on '\(slot.name, privacy: .public)': \(error.localizedDescription, privacy: .public) — pairing required?")
            deregisterInterface(slot: slot)
            setStatus(.failed, for: slot.id)
            central?.cancelPeripheralConnection(peripheral)
            scheduleReconnect(slot: slot, after: 60)
            return
        }
        // Subscription confirmed; only act on the TX characteristic (the
        // notify one). Now it's safe to start the FFI register handshake.
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else { return }
        guard !slot.subscribed else { return }
        slot.subscribed = true
        log.info("'\(slot.name, privacy: .public)' TX notifications subscribed; starting register")
        startRegisterInterface(slot: slot)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate),
              let data = characteristic.value, !data.isEmpty,
              let slot = slots[peripheral.identifier] else { return }
        log.info("RX <- '\(slot.name, privacy: .public)' \(data.count) bytes: \(data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)\(data.count > 16 ? " ..." : "") (handle=\(slot.ifaceHandle), inFlight=\(slot.registerInFlight))")
        if slot.ifaceHandle != 0 {
            let handle = slot.ifaceHandle
            data.withUnsafeBytes { buf in
                if let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    _ = rns_rnode_iface_feed(handle, base, UInt32(data.count))
                }
            }
        } else if slot.registerInFlight {
            // DETECT/init handshake response — buffer until register returns
            // the handle. Cap at a reasonable size to bound memory if something
            // goes wrong.
            if slot.pendingInboundBytes.count < 256 {
                slot.pendingInboundBytes.append(data)
            }
        }
    }
}
