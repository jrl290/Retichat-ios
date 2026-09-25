//
//  OutboundAttempts.swift
//  Retichat
//
//  The delivery attempts of one outbound 1:1 message: the DIRECT attempt and
//  the propagated copy that follows it. Pure (no FFI, no SwiftData), so it
//  compiles standalone with swiftc for tests/OutboundAttemptsTests.swift
//  (DESIGN_PRINCIPLES.md §10).
//
//  The copy is a clone of the DIRECT message (message_clone_propagated keeps
//  its content, fields, attachments and packed timestamp), so it has the same
//  LXMF message hash and the recipient drops whichever of the two arrives
//  second. Until 2026-09-24 the copy was built as a new message, with a new
//  timestamp and so a new hash, and a recipient that got both showed the
//  message twice.
//
//  Sharing the hash means both attempts report under it, and the router's
//  state callback carries only (hash, state): a FAILED cannot be traced to
//  one attempt. So this counts the attempts in flight. Each ends with one
//  terminal report — DIRECT: DELIVERED or FAILED; the copy: SENT (the node
//  holds it) or FAILED — and the message has failed only when none is left
//  and none succeeded. Success is sticky: nothing shows failed or
//  propagating after SENT or DELIVERED.
//
//  ChatRepository feeds it the router's states for the message and does what
//  each Step says; it owns the handles, the bubble and the FFI calls.
//

struct OutboundAttempts {

    /// What the bubble should show. ChatRepository maps it to DeliveryState.
    enum Shown: Equatable {
        case propagating, sent, delivered, failed
    }

    /// What ChatRepository does after one state, in this order: write
    /// `show`, start the copy, complete.
    struct Step: Equatable {
        /// The bubble's new state; nil leaves it as it is.
        var show: Shown? = nil
        /// Clone the DIRECT message and submit the copy. If it cannot be
        /// cloned or submitted, report that with copyNotStarted().
        var startCopy = false
        /// No attempt is left to hear from: drop the pending entry and
        /// release the DIRECT handle.
        var complete = false
    }

    /// Attempts started whose terminal report has not arrived.
    private(set) var inFlight = 1
    /// The propagated copy was started. There is one per message, whichever
    /// of 0x10 and the DIRECT attempt's failure asked for it first.
    private(set) var copyStarted = false
    /// SENT or DELIVERED was reported: the message is not failed whatever
    /// the other attempt does.
    private(set) var succeeded = false
    /// Complete was returned; every later report is ignored.
    private(set) var isComplete = false

    /// False for a message sent PROPAGATED from the start (a distro
    /// recipient, or no path to the peer): that one attempt is all there is.
    private let mayCopy: Bool

    /// `direct`: the first attempt went DIRECT, so a propagated copy may
    /// follow it.
    init(direct: Bool) {
        mayCopy = direct
    }

    /// 0x10 PROP_FALLBACK_REQUESTED: AppLinks Timer P fired while the DIRECT
    /// attempt still runs. The copy runs beside it — two attempts in flight.
    mutating func propagationRequested() -> Step {
        guard !isComplete, mayCopy, !copyStarted else { return Step() }
        copyStarted = true
        inFlight += 1
        return Step(show: unlessSucceeded(.propagating), startCopy: true)
    }

    /// 0xFD REJECTED, 0xFE CANCELLED, 0xFF FAILED. Before a copy exists it
    /// can only be the DIRECT attempt's, and the copy takes its place (still
    /// one attempt in flight). After, it is one attempt ending, whichever.
    mutating func failed() -> Step {
        guard !isComplete else { return Step() }
        if mayCopy && !copyStarted {
            copyStarted = true
            return Step(show: unlessSucceeded(.propagating), startCopy: true)
        }
        return attemptEnded()
    }

    /// The copy could not be cloned or submitted, so no report will come
    /// for it: it ended, failed.
    mutating func copyNotStarted() -> Step {
        guard !isComplete, copyStarted else { return Step() }
        return attemptEnded()
    }

    /// 0x04 SENT: the propagation node accepted the copy (or the only,
    /// PROPAGATED, attempt). A DELIVERED after completion still reaches the
    /// bubble: ChatRepository updates the row by hash for an unknown hash.
    mutating func sent() -> Step {
        guard !isComplete else { return Step() }
        succeeded = true
        var step = attemptEnded()
        step.show = .sent
        return step
    }

    /// 0x08 DELIVERED: the recipient proved it, from either attempt. There
    /// is nothing left worth waiting for.
    mutating func delivered() -> Step {
        guard !isComplete else { return Step() }
        succeeded = true
        isComplete = true
        return Step(show: .delivered, complete: true)
    }

    private mutating func attemptEnded() -> Step {
        inFlight = max(0, inFlight - 1)
        guard inFlight == 0 else { return Step() }
        isComplete = true
        return Step(show: unlessSucceeded(.failed), complete: true)
    }

    private func unlessSucceeded(_ shown: Shown) -> Shown? {
        succeeded ? nil : shown
    }
}
