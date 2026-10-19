//
//  LocalNetworkPermission.swift
//  Retichat
//
//  What the built-in Local network interface (AutoInterface, James
//  2026-10-19) needs from iOS: the Local Network permission, and multicast.
//
//  iOS has no call that asks for Local Network access; it asks the first
//  time the app does something on the local network. Settings' switch, the
//  first time it's turned on, browses for Reticulum's Bonjour service
//  (_reticulum._tcp, declared in NSBonjourServices), which makes iOS ask
//  then rather than at some later restart. A browse refused with
//  kDNSServiceErr_PolicyDenied means Don't Allow, now or earlier: the switch
//  goes off and the card links to iOS Settings. The browse proves nothing
//  when nobody answers it, so it never holds the switch back.
//
//  AutoInterface finds its peers by IPv6 multicast, which iOS on a device
//  allows only with Apple's com.apple.developer.networking.multicast
//  entitlement, granted on request. Until Retichat carries it the interface
//  is offered on Mac Catalyst and the simulator only (multicastAvailable);
//  with it, the build sets MULTICAST_ENTITLEMENT.
//

import Combine
import Foundation
import Network
import dnssd

@MainActor
final class LocalNetworkPermission: ObservableObject {
    static let shared = LocalNetworkPermission()

    enum Status: Equatable {
        /// Not checked, or nothing refused it.
        case unknown
        /// iOS refused local network access (Don't Allow, now or earlier).
        case denied
    }

    @Published private(set) var status: Status = .unknown

    /// Whether the Local network interface can work on this build: always on
    /// Mac Catalyst and the simulator, on a device only with the multicast
    /// entitlement.
    nonisolated static var multicastAvailable: Bool {
        #if targetEnvironment(macCatalyst) || targetEnvironment(simulator) || MULTICAST_ENTITLEMENT
        return true
        #else
        return false
        #endif
    }

    private var browser: NWBrowser?

    /// Browse for Reticulum's Bonjour service: makes iOS ask for Local
    /// Network access if it hasn't yet, and sets `status` to `.denied` if it
    /// is refused. Runs until `stop()`; a second call restarts it.
    func check() {
        stop()
        status = .unknown
        let browser = NWBrowser(for: .bonjour(type: "_reticulum._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            guard case .waiting(let error) = state, Self.isPolicyDenied(error) else { return }
            Task { @MainActor in self?.status = .denied }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        }
        return false
    }
}
