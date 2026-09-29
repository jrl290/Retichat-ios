
// NSEPropagationAppLinksTests.swift
//
// Focused source-level guard for the Notification Service Extension's
// propagation pull path: the NSE's pull must go through the core's sync, and
// the core must run that sync over an AppLinks-held `lxmf.propagation` link
// that it retries when the link comes up.
//
// Where that behaviour lives (2026-09-29). This test was added in bd48b92
// (2026-05-25) asserting an NSE-level design: NotificationService.swift
// registering its own AppLinks status callback, priming lxmf.propagation with
// `client.appLinkOpen`, routing status into `handlePropagationAppLinkStatus`
// and retrying `beginPropagationSync` on ACTIVE. That NSE code was never
// committed (bd48b92 does not touch NotificationService/, and `git log -S`
// finds none of those strings in it at any commit), so those four checks
// failed from the day they were written. The behaviour went into the core
// instead: LXMF-rust 7dc62a4 (2026-05-16) made the router own the
// propagation link through AppLinks. The NSE reaches it with
// `client.sync(nodeHash:)` → `lxmf_client_sync` → `sync_from_propagation_node`
// → `router_request_messages` → `request_messages_from_propagation_node`.
// The checks below pin that chain, one link each; each fails if its link is
// removed or bypassed.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/NSEPropagationAppLinksTests.swift
//
// It reads Retichat-ios and its sibling LXMF-rust (the path retichat-ffi's
// Cargo.toml builds against, ../../../LXMF-rust from rust/retichat-ffi).

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

/// Retichat-ios root (this file is Retichat-ios/tests/<name>.swift).
let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
/// The workspace root, where the sibling LXMF-rust lives.
let workspaceRoot = iosRoot.deletingLastPathComponent()

func source(_ base: URL, _ components: [String]) throws -> String {
    let url = components.reduce(base) { $0.appendingPathComponent($1) }
    return try String(contentsOf: url, encoding: .utf8)
}

/// The text between the first `start` and the next `end` after it, or "".
func region(_ text: String, from start: String, to end: String) -> String {
    guard let s = text.range(of: start),
          let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return "" }
    return String(text[s.upperBound..<e.lowerBound])
}

func testNSEPullGoesThroughTheCoreSync() {
    do {
        let nse = try source(iosRoot, ["NotificationService", "NotificationService.swift"])
        check(nse.contains("client.sync(nodeHash: data)"),
              "NSE pulls propagation through the core's sync (client.sync(nodeHash:))")
        check(nse.contains("NSEDelivery.semaphore.wait(timeout:"),
              "NSE waits for the core's sync-complete callback before it finishes")

        let lxmfClient = try source(iosRoot, ["Retichat", "Services", "LxmfClient.swift"])
        check(region(lxmfClient, from: "func sync(nodeHash: Data) -> Bool", to: "\n    }\n")
                .contains("lxmf_client_sync(handle,"),
              "LxmfClient.sync(nodeHash:) calls the core's lxmf_client_sync")
    } catch {
        check(false, "reads the NSE and LxmfClient sources", String(describing: error))
    }
}

func testCoreRunsTheSyncOverAppLinks() {
    do {
        let cffi = try source(workspaceRoot, ["LXMF-rust", "src", "cffi.rs"])
        check(region(cffi, from: "pub extern \"C\" fn lxmf_client_sync(", to: "\n}\n")
                .contains("c.sync_from_propagation_node(hash)"),
              "lxmf_client_sync runs the client's sync_from_propagation_node")

        let client = try source(workspaceRoot, ["LXMF-rust", "src", "client.rs"])
        check(region(client, from: "pub fn sync_from_propagation_node(", to: "\n    }\n")
                .contains("lxmf::router_request_messages(self.router_handle"),
              "sync_from_propagation_node asks the router to request messages")

        let router = try source(workspaceRoot, ["LXMF-rust", "src", "lxm_router.rs"])
        // The router's own propagation callback, registered in its constructor
        // (not the app-level register_app_link_status_callback helper).
        check(region(router, from: "let router_for_status_cb = Arc::downgrade(&router);",
                     to: "rns_app_links::APP_LINK_ACTIVE => {")
                .contains("AppLinks::register_status_callback(Arc::new("),
              "the router registers its AppLinks status callback")
        check(region(router, from: "fn open_persistent_propagation_link(&mut self)", to: "\n\t}\n")
                .contains("AppLinks::open_persistent(&node_hash, APP_NAME, &[\"propagation\"])"),
              "the router primes lxmf.propagation via AppLinks (open_persistent)")

        // The status callback's ACTIVE branch, up to the DISCONNECTED branch.
        let active = region(router, from: "rns_app_links::APP_LINK_ACTIVE => {",
                            to: "rns_app_links::APP_LINK_DISCONNECTED => {")
        check(active.contains("router.outbound_propagation_link = Some(handle);"),
              "an ACTIVE status for the propagation node routes its link into the sync",
              active.isEmpty ? "ACTIVE branch not found" : "")
        check(active.contains("LXMRouter::PR_PATH_REQUESTED | LXMRouter::PR_LINK_ESTABLISHING")
                && active.contains("router.request_messages_from_propagation_node(identity, max_messages);"),
              "the router retries a waiting propagation sync when AppLinks becomes active",
              active.isEmpty ? "ACTIVE branch not found" : "")
    } catch {
        check(false, "reads the LXMF-rust sources next to Retichat-ios", String(describing: error))
    }
}

testNSEPullGoesThroughTheCoreSync()
testCoreRunsTheSyncOverAppLinks()

if failures.isEmpty {
    print("all NSE propagation AppLinks tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}
