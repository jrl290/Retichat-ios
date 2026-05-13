//
//  DefaultEndpointManager.swift
//  Retichat
//
//  Shuffled default TCP endpoints matching the Android app.
//

import Foundation
import Network

struct DefaultEndpointManager {
    static let endpoints: [(host: String, port: Int)] = [
        ("162.19.248.199", 4242),
        ("193.26.158.230", 4965),
        ("213.235.65.180", 4440),
        ("213.89.12.80", 4242),
        ("217.154.184.223", 45823),
        ("217.70.19.114", 4242),
        ("23.188.56.190", 9050),
        ("37.193.84.9", 4242),
        ("37.221.212.76", 4242),
        ("45.59.114.96", 7822),
        ("45.77.109.86", 4965),
        ("62.151.179.77", 45657),
        ("62.183.96.32", 4242),
        ("75.133.206.221", 4242),
        ("77.221.159.41", 4242),
        ("77.37.166.237", 4242),
        ("82.165.27.170", 443),
        ("82.22.20.33", 9500),
        ("82.223.44.241", 4242),
        ("87.106.8.245", 4242),
        ("91.207.113.250", 4242),
        ("93.40.0.250", 4242),
        ("93.95.227.8", 49952),
        ("94.180.116.248", 4242),
        ("aspark.uber.space", 44860),
        ("dfw.us.g00n.cloud", 6969),
        ("intr.cx", 4242),
        ("istanbul.reserve.network", 9034),
        ("phantom.mobilefabrik.com", 4242),
        ("reticulum.betweentheborders.com", 4242),
        ("reticulum.lazynoda.es", 4242),
        ("rmap.world", 4242),
        ("rns.beleth.net", 4242),
        ("rns.derps.me", 34242),
        ("rns.dismail.de", 7822),
        ("rns.michmesh.net", 7822),
        ("rns.nittedal.town", 4242),
        ("rns.noderage.org", 4242),
        ("rns.one-big.network", 4242),
        ("rns.pawgslayers.club", 4242),
        ("rns.simplyequipped.com", 4242),
        ("rns.soon.it", 4242),
        ("rns.stoppedcold.com", 4242),
        ("rns.wiegandtech.net", 4242),
        ("rns.yggdrasil.michmesh.net", 7822),
        ("rns01.powerglitch.ro", 4242),
        ("sydney.reticulum.au", 4242),
        ("vjs.hu", 5858),
        ("vps001.vanheusden.com", 4242),
        ("world.reticulum.is", 3400),
    ]

    static let fallbackEndpointCount = 3

    private static let probeCandidateCount = 12
    private static let probeTimeoutSecs: TimeInterval = 1.5
    private static let probeQueue = DispatchQueue(
        label: "chat.retichat.default-endpoint.probe",
        qos: .utility,
        attributes: .concurrent
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

    /// Probe a randomized pool of public endpoints and return up to
    /// `fallbackEndpointCount` hosts that accepted a TCP connection.
    ///
    /// If the current network is offline or not enough probes succeed
    /// inside the timeout budget, the returned list is padded from the
    /// same shuffled pool so startup still has fallback targets once the
    /// network comes back.
    static func selectFallbackEndpoints() async -> [(host: String, port: Int)] {
        let shuffledCandidates = shuffled()
        let probeCandidates = Array(shuffledCandidates.prefix(min(probeCandidateCount, shuffledCandidates.count)))
        let reachableKeys = await withTaskGroup(of: (String, Bool).self) { group in
            for endpoint in probeCandidates {
                let key = endpointKey(endpoint)
                group.addTask {
                    (key, await probeConnectability(of: endpoint, timeoutSecs: probeTimeoutSecs))
                }
            }

            var successes = Set<String>()
            for await (key, success) in group where success {
                successes.insert(key)
            }
            return successes
        }

        var selected = probeCandidates.filter { reachableKeys.contains(endpointKey($0)) }
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
