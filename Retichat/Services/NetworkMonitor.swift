//
//  NetworkMonitor.swift
//  Retichat
//
//  System network connectivity monitor using NWPathMonitor.
//  Replaces Android's ConnectivityManager callback.
//

import Foundation
import Network
import Combine

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected = true
    @Published var connectionType: NWInterface.InterfaceType?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    var onConnect: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wasConnected = self?.isConnected ?? false
            let connected = path.status == .satisfied

            DispatchQueue.main.async {
                self?.isConnected = connected
                if path.usesInterfaceType(.wifi) {
                    self?.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self?.connectionType = .cellular
                } else {
                    self?.connectionType = nil
                }
            }

            // Trigger reconnect flush when network comes back
            if !wasConnected && connected {
                self?.onConnect?()
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
