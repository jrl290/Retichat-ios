//
//  HeldSends.swift
//  Retichat
//
//  Sends made before the stack has finished starting, held in the order they
//  were made until it has. Pure (no FFI, no SwiftData), so it compiles
//  standalone with swiftc for tests/HeldSendsTests.swift
//  (DESIGN_PRINCIPLES.md §10).
//
//  ChatRepository decides what a send is and when the gate opens: the last
//  step of finishStartService, once everything a send depends on is in
//  place (§5). This only keeps the order and hands each send back once.
//

struct HeldSends<Send> {
    /// False until the stack has finished starting, and again once it stops.
    /// While false, a send is held rather than handed to the router.
    private(set) var isOpen = false
    private var held: [Send] = []

    var count: Int { held.count }

    /// Hold a send made while the gate is closed.
    mutating func hold(_ send: Send) {
        held.append(send)
    }

    /// Open the gate and take everything held, oldest first. Each send is
    /// handed back exactly once: the next open() returns only what was held
    /// after this one.
    mutating func open() -> [Send] {
        isOpen = true
        let released = held
        held.removeAll()
        return released
    }

    /// Close the gate (the stack stopped). Held sends are kept for the next
    /// open(): a message typed across a restart still goes, and in order.
    mutating func close() {
        isOpen = false
    }
}
