//
//  DefaultEndpointManager.swift
//  Retichat
//
//  Curated default TCP endpoints shared with the Android app.
//  Keep this list in sync so fresh-start bootstrap behavior matches.
//

import Foundation
import Network

struct DefaultEndpointManager {
    static let endpoints: [(host: String, port: Int)] = [
        ("rns.noderage.org", 4242),
        ("rns.michmesh.net", 7822),
        ("world.reticulum.is", 3400),
        ("rmap.world", 4242),
        ("vjs.hu", 5858),
        ("202.61.243.41", 4965),
        ("45.77.109.86", 4965),
    ]

    static let fallbackEndpointCount = 3

    // Use the same hard cap the rest of the stack treats as a real success.
    // If a public backbone cannot accept TCP within 5 seconds, it should not
    // be chosen as one of the default startup interfaces.
    private static let probeTimeoutSecs: TimeInterval = 5.0
    private static let probeQueue = DispatchQueue(
        label: "chat.retichat.default-endpoint.probe",
        qos: .utility
    )

    private final class ProbeContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<Bool, Never>

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            continuation.resume(returning: success)
        }
    }

    /// Return a shuffled copy of the endpoint list.
    static func shuffled() -> [(host: String, port: Int)] {
        return endpoints.shuffled()
    }

    /// Pick the first endpoint, rotating from a shuffled copy.
    static func pick() -> (host: String, port: Int) {
        return endpoints.randomElement() ?? endpoints[0]
    }

    /// Probe the shuffled public endpoint list in serial order and return up to
    /// `fallbackEndpointCount` hosts that accepted a TCP connection.
    ///
    /// If fewer than three probes succeed after the full list is exhausted,
    /// pad from the same shuffled order so startup still has fallback targets
    /// once the network comes back.
    static func selectFallbackEndpoints() async -> [(host: String, port: Int)] {
        let shuffledCandidates = shuffled()
        var selected: [(host: String, port: Int)] = []

        for endpoint in shuffledCandidates {
            if await probeConnectability(of: endpoint, timeoutSecs: probeTimeoutSecs) {
                selected.append(endpoint)
                if selected.count == fallbackEndpointCount {
                    break
                }
            }
        }

        if selected.count < fallbackEndpointCount {
            for endpoint in shuffledCandidates where !selected.contains(where: { endpointKey($0) == endpointKey(endpoint) }) {
                selected.append(endpoint)
                if selected.count == fallbackEndpointCount { break }
            }
        }

        return Array(selected.prefix(fallbackEndpointCount))
    }

    private static func endpointKey(_ endpoint: (host: String, port: Int)) -> String {
        "\(endpoint.host):\(endpoint.port)"
    }

    private static func probeConnectability(of endpoint: (host: String, port: Int), timeoutSecs: TimeInterval) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
            let result = ProbeContinuationBox(continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    result.resume(true)
                case .failed(_), .cancelled:
                    result.resume(false)
                default:
                    break
                }
            }

            connection.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + timeoutSecs) {
                connection.cancel()
                result.resume(false)
            }
        }
    }
}
