//
//  FallbackBackbones.swift
//  Retichat
//
//  Which public fallback backbones generateConfig writes into the stack
//  config. Foundation only and free of the network, so
//  tests/FallbackBackbonesTests.swift runs both branches as they are.
//

import Foundation

enum FallbackBackbones {
    /// The fallback backbones for a generated config.
    ///
    /// Only when the user left "Default TCP" on AND configured no interface
    /// of their own, as the setting documents and Android's StackRuntime
    /// does (`useDefault = interfaces.isEmpty() && isDefaultTcpEnabled`).
    /// Otherwise none: a first launch with the setting off once dialled
    /// three public backbones before the user could add an interface.
    ///
    /// - probed: the endpoints startService's probe found reachable (empty
    ///   when it skipped the probe or found none).
    /// - pool: the unprobed pool to pick from when `probed` is empty; called
    ///   only when fallbacks are wanted.
    static func select(defaultTcpEnabled: Bool,
                       hasConfiguredInterfaces: Bool,
                       probed: [(host: String, port: Int)],
                       pool: () -> [(host: String, port: Int)]) -> [(host: String, port: Int)] {
        guard defaultTcpEnabled, !hasConfiguredInterfaces else { return [] }
        return probed.isEmpty ? pool() : probed
    }
}
