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
//  RTNode advertising. The app delegate then starts the stack, which makes
//  both centrals again under the same identifiers, and each takes back what
//  iOS kept (centralManager(_:willRestoreState:)). Not after the user
//  force-quits Retichat: iOS restores nothing then.
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

    /// Relaunched for Bluetooth: `ids` is the launch options'
    /// `.bluetoothCentrals`, the restore identifiers of the centrals iOS
    /// kept going. If one is ours, the stack starts at launch, since it is
    /// what makes the centrals again.
    static func startsStack(restoringCentrals ids: [String]?) -> Bool {
        guard let ids else { return false }
        return ids.contains(rnodeCentral) || ids.contains(rtnodeCentral)
    }

    /// The kept RNode connections no saved RNode wants (its row gone or no
    /// longer readable): dropped, so the radio is not held by a link nothing
    /// uses. In the order given.
    static func strays(restored: [UUID], saved: Set<UUID>) -> [UUID] {
        restored.filter { !saved.contains($0) }
    }
}
