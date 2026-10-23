//
//  BluetoothRestoration.swift
//  Retichat
//
//  Bluetooth state restoration for the two long-lived centrals: the saved
//  RNodes' (RNodeInterfaceCoordinator) and the nearby RTNode's
//  (RTNodeBluetoothCoordinator).
//
//  A central made with a restore identifier keeps its connections, pending
//  connects and scan going after iOS ends the suspended app, and iOS
//  relaunches the app in the background when something happens on one: a
//  notification from a connected radio, a pending connect completing, an
//  RTNode advertising. The relaunched app must make the central again under
//  the same identifier within 15 s, or bluetoothd gives up ("Session
//  Resurrected by not live") and drops the radio. Each coordinator then
//  takes back what iOS kept (centralManager(_:willRestoreState:)). Not after
//  the user force-quits Retichat: iOS restores nothing then.
//
//  The centrals are made by the stack's start. A SwiftUI app's delegate gets
//  no launch options on a Bluetooth relaunch, and its application state is
//  the same as on the user's launch (both seen on an iPad, 2026-10-23), so
//  nothing says which launch it is: the app delegate starts the stack at
//  every launch that has a Bluetooth radio to restore.
//
//  Pure (no CoreBluetooth, no UIKit), so tests/BluetoothRestorationTests.swift
//  can check it.
//

import Foundation

nonisolated enum BluetoothRestoration {
    /// The saved RNodes' central (RNodeInterfaceCoordinator).
    static let rnodeCentral = "com.retichat.rnode.central"

    /// The nearby RTNode's central (RTNodeBluetoothCoordinator).
    static let rtnodeCentral = "com.retichat.rtnode.central"

    /// Posted by a coordinator when iOS hands its central's state back: the
    /// app was relaunched for Bluetooth, and the app delegate keeps it
    /// running while the radio's link comes back.
    static let restored = Notification.Name("BluetoothRestoration.restored")

    /// Whether the app delegate starts the stack at launch rather than when
    /// the app comes up: with an enabled saved RNode or the Nearby RTNode
    /// switch on, this launch may be iOS's relaunch for that radio, which
    /// must find its central made again in time.
    static func startsStackAtLaunch(savedRNode: Bool, rtnodeSwitchOn: Bool) -> Bool {
        savedRNode || rtnodeSwitchOn
    }

    /// The kept RNode connections no saved RNode wants (its row gone or no
    /// longer readable): dropped, so the radio is not held by a link nothing
    /// uses. In the order given.
    static func strays(restored: [UUID], saved: Set<UUID>) -> [UUID] {
        restored.filter { !saved.contains($0) }
    }
}
