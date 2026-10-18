// RfedLinkPushThreadTests.swift
//
// Self-contained Swift test script — no XCTest target required.
// Run with:
//
//     swift Retichat-ios/tests/RfedLinkPushThreadTests.swift
//
// Exits with status 0 on success, 1 on any failure.
//
// What it covers
// ──────────────
// An rfed.link `/lxmf/delivery` push runs on a link worker thread, and rfed
// waits for its answer. Until 2026-10-18 the handler read the LXMF client
// with `DispatchQueue.main.sync`, so a busy main thread held every push: on
// staging a SwiftUI update that never finished left them all unanswered and
// rfed deferred them (16:55 and 17:00). The handler reads the client from a
// lock-protected copy instead, kept in step with `lxmfClient`.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "PASS" : "FAIL"): \(what)")
    if !ok { failures += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let src = try! String(contentsOf: here.appendingPathComponent("../Retichat/Services/ChatRepository.swift"), encoding: .utf8)

let push = src.components(separatedBy: "nonisolated private func onLxmfPush(_ data: Data) -> Bool {").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
check(!push.isEmpty, "onLxmfPush is found")
check(!push.contains("DispatchQueue.main.sync"), "the /lxmf/delivery push never waits on the main thread")
check(push.contains("pushClient.get()"), "the push reads the client from its lock-protected copy")

let decl = src.components(separatedBy: "private(set) var lxmfClient: LxmfClient?").dropFirst().first?.prefix(120) ?? ""
check(decl.contains("didSet { pushClient.set(lxmfClient) }"), "the copy follows every change of lxmfClient")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
