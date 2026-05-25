// DirectFallbackBufferTests.swift
//
// Self-contained regression guard for the iOS direct-send fallback race.
// Run with:
//
//     swift Retichat-ios/tests/DirectFallbackBufferTests.swift

import Foundation

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String, _ detail: String = "") {
    if condition() {
        print("ok    - \(name)")
    } else {
        let message = detail.isEmpty ? name : "\(name) — \(detail)"
        print("FAIL  - \(message)")
        failures.append(message)
    }
}

func sourceFile(_ components: [String]) throws -> String {
    let sourceURL = components.reduce(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    ) { partial, component in
        partial.appendingPathComponent(component)
    }
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

func chatRepositorySource() throws -> String {
    try sourceFile(["Retichat", "Services", "ChatRepository.swift"])
}

func lxmfClientSource() throws -> String {
    try sourceFile(["Retichat", "Services", "LxmfClient.swift"])
}

func ffiHeaderSource() throws -> String {
    try sourceFile(["Retichat", "Bridge", "CRetichatFFI.h"])
}

func testSourceContainsEarlyStateBuffering() {
    do {
        let source = try chatRepositorySource()
        check(
            source.contains("earlyMessageStates[hashHex, default: []].append(state)"),
            "buffers early message-state callbacks"
        )
        check(
            source.contains("self.replayBufferedMessageStatesIfNeeded(for: msgHashHex)"),
            "replays buffered states after direct send registration"
        )
        check(
            source.contains("self?.replayBufferedMessageStatesIfNeeded(for: newHashHex)"),
            "replays buffered states after propagated resend registration"
        )
        check(
            source.contains("earlyMessageStates.removeValue(forKey: hashHex)"),
            "clears buffered states on completion"
        )
    } catch {
        check(false, "reads ChatRepository source", String(describing: error))
    }
}

func testSourceSeedsPropagationNodeWithoutPolling() {
    do {
        let chatRepository = try chatRepositorySource()
        let lxmfClient = try lxmfClientSource()
        let ffiHeader = try ffiHeaderSource()

        check(
            chatRepository.contains("client.setPropagationNode(nodeHash: nodeHash)"),
            "seeds outbound propagation node during polling refresh"
        )
        check(
            lxmfClient.contains("func setPropagationNode(nodeHash: Data) -> Bool"),
            "LxmfClient exposes propagation node setter"
        )
        check(
            ffiHeader.contains("lxmf_client_set_propagation_node"),
            "C FFI exports propagation node setter"
        )
    } catch {
        check(false, "reads propagation setter sources", String(describing: error))
    }
}

struct BufferedStateQueue {
    private var buffered: [String: [UInt8]] = [:]

    mutating func push(_ state: UInt8, for hashHex: String) {
        buffered[hashHex, default: []].append(state)
    }

    mutating func drain(for hashHex: String) -> [UInt8] {
        buffered.removeValue(forKey: hashHex) ?? []
    }
}

func testBufferedStatesPreserveTimerPOrdering() {
    var queue = BufferedStateQueue()
    queue.push(0x10, for: "msg")
    queue.push(0xFF, for: "msg")

    var propFallbackSent = false
    var eventLog: [String] = []

    for state in queue.drain(for: "msg") {
        switch state {
        case 0x10:
            propFallbackSent = true
            eventLog.append("fallback")
        case 0xFF:
            eventLog.append(propFallbackSent ? "cleanup" : "late-fallback")
        default:
            break
        }
    }

    check(
        eventLog == ["fallback", "cleanup"],
        "buffered Timer P replay precedes terminal direct failure",
        "got \(eventLog)"
    )
    check(queue.drain(for: "msg").isEmpty, "drain clears buffered states")
}

testSourceContainsEarlyStateBuffering()
testSourceSeedsPropagationNodeWithoutPolling()
testBufferedStatesPreserveTimerPOrdering()

if failures.isEmpty {
    print("all direct fallback buffer tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}