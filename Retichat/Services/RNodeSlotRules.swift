//
//  RNodeSlotRules.swift
//  Retichat
//
//  The retry and status rules RNodeInterfaceCoordinator follows for a saved
//  RNode's link. Pure (no CoreBluetooth, no FFI), so
//  tests/RNodeSlotRulesTests.swift can check them.
//

import Foundation

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

/// What a slot shows after its link drops, and whether the drop schedules
/// the backoff reconnect.
struct RNodeDisconnectOutcome: Equatable {
    let status: RNodeSlotStatus
    let scheduleBackoff: Bool
}

enum RNodeSlotRules {
    /// A saved peripheral the system does not know (re-pair via Scan & Pair).
    static let unknownPeripheralRetrySeconds = 30

    /// The TX subscription was refused, most often an unpaired radio: back
    /// off hard rather than hammer Bluetooth.
    static let subscribeFailedRetrySeconds = 60

    /// The next reconnect wait after one of `seconds`: doubling, up to a minute.
    static func nextBackoff(after seconds: Int) -> Int { min(seconds * 2, 60) }

    /// The link dropped (didDisconnectPeripheral). `droppedAfterFailure`: the
    /// coordinator cancelled it because something failed, and has shown
    /// .failed; the drop keeps that rather than show .idle (CoreBluetooth
    /// reports a cancelled connection without an error). `failureScheduledRetry`:
    /// that failure chose its own retry (60 s after a refused subscription),
    /// which the backoff must not replace.
    static func afterDisconnect(error: Bool, droppedAfterFailure: Bool, failureScheduledRetry: Bool) -> RNodeDisconnectOutcome {
        if droppedAfterFailure {
            return RNodeDisconnectOutcome(status: .failed, scheduleBackoff: !failureScheduledRetry)
        }
        return RNodeDisconnectOutcome(status: error ? .failed : .idle, scheduleBackoff: true)
    }
}
