// NSERatchetMirrorTests.swift
//
// The NSE decrypts propagated messages with the app's ratchets, from a file
// in the App Group. Until 2026-09-27 the app copied its ratchet file there
// at start and after scheduling the publish, but its first announce of a run
// rotated a ratchet after those copies, so every propagated DM to it showed
// only "New message" until the next launch; and the NSE's own stack, able to
// announce (path responses), could rotate a ratchet only it held.
// Now (Reticulum-rust PARITY-AUDIT-1.5.2.md A29): the app's stack mirrors
// every write of its ratchet file into the NSE's ratchet directory from
// before anything can announce, the app copies the files once, before its
// stack starts, and the NSE starts with frozen (read-only) ratchets.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/nse-ratchet-mirror \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/NSERatchetMirrorTests.swift && \
//     /private/tmp/claude-501/nse-ratchet-mirror
//
// The ratchet copy runs for real against scratch directories (never the App
// Group). The app and NSE wiring needs UIKit, SwiftUI and the FFI, so it is
// asserted on the source, like NSEDeliveryHandOffTests.swift.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if !ok { failures.append(what); print("FAIL: \(what)") }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
        check(false, "source \(path) is readable")
        return ""
    }
    return text
}

/// Offset of `needle` in `haystack` at or after `from`, or nil.
func offset(of needle: String, in haystack: String, from: String.Index? = nil) -> String.Index? {
    haystack.range(of: needle, range: (from ?? haystack.startIndex)..<haystack.endIndex)?.lowerBound
}

func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// The body of `func name(` up to the next `\n    func ` / `\n    private func `.
func functionBody(_ name: String, in text: String) -> String {
    guard let start = text.range(of: name) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    nonisolated ", "\n    @discardableResult"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

// MARK: - App: mirror before the first announce, one copy before the start

func testTheAppMirrorsBeforeAnythingCanAnnounce() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let body = functionBody("func continueStartService(", in: repo)
    guard let mirror = offset(of: "ratchetsMirrorDir: PendingNotification.nseRatchetsDir()", in: body),
          let start = offset(of: "LxmfClient.start(config: config)", in: body) else {
        check(false, "continueStartService configures the mirror and starts the client")
        return
    }
    check(mirror < start, "the mirror is in the start config: in place before registration, so before any announce")
    let finish = functionBody("func finishStartService(", in: repo)
    check(finish.contains(".publish(refreshSecs:"), "the publish (the first announce) is in finishStartService, after the start returned")

    let client = source("Retichat/Services/LxmfClient.swift")
    let startBody = functionBody("static func start(config: LxmfClientConfig)", in: client)
    check(startBody.contains("lxmf_client_start_with_ratchets("), "LxmfClient.start uses the start that applies the mirror and freeze")
    check(startBody.contains("withOptionalCString(config.ratchetsMirrorDir)"), "the mirror dir reaches the FFI")
    check(startBody.contains("config.ratchetsFrozen ? 1 : 0"), "the freeze reaches the FFI")
    check(!client.contains("lxmf_client_start("), "no start without the ratchet options is left in Swift")

    let header = source("Retichat/Bridge/CRetichatFFI.h")
    check(header.contains("uint64_t lxmf_client_start_with_ratchets("), "the header declares the start with ratchets")
    check(header.contains("const char *ratchets_mirror_dir,\n                                         int32_t ratchets_frozen);"),
          "with the mirror dir and the freeze last, as in LXMF-rust cffi.rs")
    check(header.contains("int32_t lxmf_client_set_ratchets_mirror_dir(uint64_t client, const char *dir);")
          && header.contains("int32_t lxmf_client_set_ratchets_frozen(uint64_t client, int32_t frozen);"),
          "the header declares the runtime setters")
}

func testOnlyTheCopyBeforeTheStartRemains() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(occurrences(of: "syncRatchetsToAppGroup(", in: repo) == 1,
          "one ratchet copy: the ones after the publish and after a propagation-node change raced the mirror")
    let body = functionBody("func continueStartService(", in: repo)
    guard let queue = offset(of: "ffiQueueRef.async {", in: body),
          let copy = offset(of: "PendingNotification.syncRatchetsToAppGroup(from: storagePath)", in: body),
          let start = offset(of: "LxmfClient.start(config: config)", in: body) else {
        check(false, "the copy is in continueStartService")
        return
    }
    check(queue < copy && copy < start, "the copy runs on ffiQueue (behind any shutdown) before the stack starts")
    let nse = source("NotificationService/NotificationService.swift")
    check(!nse.contains("syncRatchetsToAppGroup"), "the NSE never copies ratchets")
}

func testTheRatchetDirectoryExistsBeforeTheFirstMirrorWrite() {
    let pending = source("Retichat/Services/PendingNotification.swift")
    let body = functionBody("static func nseRatchetsDir()", in: pending)
    check(body.contains("createDirectory(at: dir, withIntermediateDirectories: true)"),
          "nseRatchetsDir creates the directory, and the app calls it for the start config")
    check(body.contains("\"lxmf_storage\"") && body.contains("\"lxmf\"") && body.contains("\"ratchets\""),
          "it is the NSE's ratchet directory (storage lxmf_storage, router's /lxmf, ratchets)")
    let nse = source("NotificationService/NotificationService.swift")
    check(nse.contains("let storage = configDir + \"/lxmf_storage\""), "the NSE's LXMF storage is nse_reticulum/lxmf_storage")
}

func testTheCopyIsAtomicAndCopiesOnlyRatchetFiles() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("nse-ratchet-copy-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let storage = base.appendingPathComponent("lxmf_storage")
    let src = storage.appendingPathComponent("lxmf").appendingPathComponent("ratchets")
    let dst = base.appendingPathComponent("nse_ratchets")
    try? fm.createDirectory(at: src, withIntermediateDirectories: true)
    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)

    let newer = Data((0..<200).map { UInt8($0) })
    try? newer.write(to: src.appendingPathComponent("57eba637.ratchets"))
    try? Data([1]).write(to: src.appendingPathComponent("57eba637.ratchets.tmp"))
    try? Data([9, 9]).write(to: dst.appendingPathComponent("57eba637.ratchets"))

    PendingNotification.syncRatchetsToAppGroup(from: storage.path, to: dst.path)

    check((try? Data(contentsOf: dst.appendingPathComponent("57eba637.ratchets"))) == newer, "the NSE's file is replaced with the app's")
    let left = (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
    check(left == ["57eba637.ratchets"], "only .ratchets files, and no temporary file left behind (\(left))")

    let source = source("Retichat/Services/PendingNotification.swift")
    let body = functionBody("static func syncRatchetsToAppGroup(", in: source)
    check(body.contains("rename(tmp.path, dst.path)") && !body.contains("removeItem(at: dst)"),
          "the copy renames over the NSE's file: never a moment without one")
}

// MARK: - NSE: frozen from the start

func testTheNSEStartsWithFrozenRatchets() {
    let nse = source("NotificationService/NotificationService.swift")
    let body = functionBody("private func startStack()", in: nse)
    guard let config = offset(of: "let config = LxmfClientConfig(", in: body),
          let frozen = offset(of: "ratchetsFrozen: true", in: body),
          let start = offset(of: "LxmfClient.start(config: config)", in: body) else {
        check(false, "startStack starts the client with ratchetsFrozen: true")
        return
    }
    check(config < frozen && frozen < start,
          "frozen in the start config: before the ratchets load and before the destination is registered (anything can announce)")
    check(!body.contains("ratchetsMirrorDir"), "the NSE mirrors nothing")
    check(!nse.contains("lxmf_client_set_ratchets_frozen"), "the NSE never unfreezes")
}

// MARK: - Rename: Return saves

func testReturnInTheRenameFieldSaves() {
    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    guard let field = offset(of: "TextField(isGroup ? \"Name\" : providedName, text: $renameText)", in: view),
          let submit = offset(of: ".onSubmit {", in: view, from: field),
          let button = offset(of: "Button(\"Save\") {", in: view, from: field) else {
        check(false, "the rename field has an onSubmit")
        return
    }
    check(submit < button, "the onSubmit belongs to the rename field")
    let handler = String(view[submit..<button])
    check(handler.contains("guard !renameUnchanged else { return }"), "Return is ignored when Save is disabled (renameUnchanged)")
    check(handler.contains("applyRename()"), "Return saves with the Save button's applyRename")
    let save = String(view[button...].prefix(300))
    check(save.contains("applyRename()") && save.contains(".disabled(renameUnchanged)"), "the Save button is unchanged")
}

@main
enum NSERatchetMirrorTests {
    static func main() {
        testTheAppMirrorsBeforeAnythingCanAnnounce()
        testOnlyTheCopyBeforeTheStartRemains()
        testTheRatchetDirectoryExistsBeforeTheFirstMirrorWrite()
        testTheCopyIsAtomicAndCopiesOnlyRatchetFiles()
        testTheNSEStartsWithFrozenRatchets()
        testReturnInTheRenameFieldSaves()
        if failures.isEmpty {
            print("all NSE ratchet mirror tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
