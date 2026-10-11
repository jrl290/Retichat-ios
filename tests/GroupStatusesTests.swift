// GroupStatusesTests.swift
//
// Member statuses and keys (RFed-spec Group.md, "Member statuses and keys (2026-10-06)"), every
// rule, through the Swift layer: GroupStatusEngine with the group rule (DeliveryPolicy) in front of
// it, the native layer behind FakeGroupNative (real Ed25519 over real packed messages) and the
// store in memory (tests/GroupStatusFixtures.swift). It mirrors Retichat-android's GroupStatusesTest
// and the web's `group_statuses.test.mjs`, with their names where the rule is the same; the
// vectors' own outcomes are in tests/GroupStatusVectorsTests.swift. Messages are made here, signed
// by the vectors' identities: whoever signs a message may be someone else than its source, which
// is how a forgery is made. The wiring (ChatRepository, GroupChatManager, the NSE) needs SwiftData
// and the FFI, so it is asserted on the source, at the end.
//
// Run from the workspace root with:
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/group-statuses \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/GroupStatuses.swift \
//     Retichat-ios/Retichat/Services/GroupEnvelopes.swift \
//     Retichat-ios/tests/GroupStatusFixtures.swift \
//     Retichat-ios/tests/GroupStatusesTests.swift && \
//     /private/tmp/claude-501/group-statuses

import CryptoKit
import Foundation

let V = Vectors.load()
let bothForms = [false, true]

@MainActor
func rig(me: String = "frank", switched: Bool = false, holds: [String] = []) -> GroupRig {
    GroupRig(V, me: me, switched: switched, holds: holds)
}

/// A creator that has created the group and accepted it.
@MainActor
func creatorRig(switched: Bool = false, holds: [String] = []) -> GroupRig {
    let r = GroupRig(V, me: V.creator, switched: switched, holds: holds)
    r.hold(accepted: true)
    return r
}

@MainActor
func maker() -> MessageMaker { MessageMaker(V) }

func hex(_ name: String) -> String { V.hashOf(name) }

// MARK: - Verdict: what an accept or leave is worth

@MainActor
func verdictVerifiedCountsForgedIsIgnoredUnverifiableCountsUntilTheSwitchAndIsHeldFromItUncheckedIsNeverCounted() {
    let validated = DeliveryPolicy.Signature.validated, invalid = DeliveryPolicy.Signature.invalid
    let unknown = DeliveryPolicy.Signature.sourceUnknown
    checkEqual(GroupStatuses.verdict(signature: validated, switched: false), .count, "verified counts before the switch")
    checkEqual(GroupStatuses.verdict(signature: validated, switched: true), .count, "and from it")
    checkEqual(GroupStatuses.verdict(signature: invalid, switched: false), .ignore, "forged is ignored before the switch")
    checkEqual(GroupStatuses.verdict(signature: invalid, switched: true), .ignore, "and from it")
    checkEqual(GroupStatuses.verdict(signature: unknown, switched: false), .count, "unverifiable counts until the switch")
    checkEqual(GroupStatuses.verdict(signature: unknown, switched: true), .hold, "and is held from it")
    checkEqual(GroupStatuses.verdict(signature: 7, switched: false), .ignore, "a code the router never reports is not counted")
    checkEqual(GroupStatuses.verdict(signature: -1, switched: true), .ignore, "nor a negative one")
}

@MainActor
func theLimitsAgreeACreatorKeepsAndPassesOnAPackedMessageOfAtMost96BytesPlusThePayloadLimit() {
    checkEqual(GroupStatuses.statusPayloadLimit, 2048, "the payload limit")
    checkEqual(GroupStatuses.packedHeaderLength, 96, "destination, source, signature")
    checkEqual(GroupStatuses.statusPackedLimit, 2144, "the packed limit")
    checkEqual(GroupStatuses.heldLimit, 128, "held in all")
    checkEqual(GroupStatuses.heldPerMember, 4, "held for one member of one group")
}

// MARK: - Receiving an accept or leave

@MainActor
func aKeyedAcceptFromASourceNobodyHoldsAKeyForIsVerifiedByTheKeyItCarriesRememberedAndCountsBeforeAndAfterTheSwitchInEitherForm() {
    for switched in bothForms {
        for retichat in bothForms {
            let r = rig(switched: switched, holds: ["creator"])
            r.hold()
            checkEqual(r.receive(maker().msg("alice", retichat: retichat)), true, "it counts (switched \(switched), retichat \(retichat))")
            checkEqual(r.status("alice"), MemberStatus.accepted, "alice is accepted")
            checkEqual(r.native.remembered, [hex("alice")], "the key it carries is remembered, once the rule has kept it")
            checkEqual(r.store.heldRows.count, 0, "nothing is held: it is verified")
            checkEqual(r.store.lines.map { "\(V.nameOf($0.member)) \($0.joined)" }, ["alice true"], "said once")
            checkEqual(r.store.allowed, [hex("alice")], "a member of a group the user joined passes the filter")
        }
    }
}

@MainActor
func aKeyedLeaveFromASourceNobodyHoldsAKeyForIsVerifiedRememberedAndFinalALaterAcceptOfTheSameMemberKeyedOrNotIsDroppedUnproved() {
    let r = rig(holds: ["creator"])
    r.hold()
    let m = maker()
    checkEqual(r.receive(m.msg("bob", action: GroupAction.leave)), true, "the leave counts")
    checkEqual(r.status("bob"), MemberStatus.left, "bob left")
    checkEqual(r.native.remembered, [hex("bob")], "and his key is remembered")
    check(r.receive(m.msg("bob")) == nil, "a later keyed accept is dropped by the rule")
    check(r.receive(m.msg("bob", key: false)) == nil, "so is a keyless one")
    checkEqual(r.status("bob"), MemberStatus.left, "a leave is final")
    checkEqual(r.dropped, ["accept from bob", "accept from bob"], "both dropped, said")
}

@MainActor
func aForgedAcceptOrLeaveCarryingItsSendersRealKeyIsDroppedUnprovedAndTheMembersOwnMessageStillCounts() {
    let r = rig(holds: ["creator"])
    r.hold()
    let m = maker()
    check(r.receive(m.msg("carol", signer: "mallory")) == nil, "an accept signed by someone else under carol's name is dropped")
    check(r.receive(m.msg("carol", action: GroupAction.leave, signer: "mallory")) == nil, "so is a leave")
    checkEqual(r.status("carol"), MemberStatus.invited, "carol is untouched")
    check(r.native.remembered.isEmpty, "no key is remembered from a message the rule dropped")
    checkEqual(r.receive(m.msg("carol")), true, "carol's own accept still counts")
    checkEqual(r.status("carol"), MemberStatus.accepted, "and she is accepted")
}

@MainActor
func aKeyThatDoesNotBindIsNoKeyCountsBeforeTheSwitchIsHeldFromItAndIsCountedOrDroppedWhenTheRealKeyArrives() {
    // Dave's accept carrying mallory's key under dave's hash: the key does not derive dave's destination.
    let before = rig(holds: ["creator"])
    before.hold()
    checkEqual(before.receive(maker().msg("dave", keyOf: "mallory", keyEntryHash: "dave")), true, "unverifiable counts before the switch")
    checkEqual(before.status("dave"), MemberStatus.accepted, "dave is accepted")
    check(before.native.remembered.isEmpty, "the key that does not bind is never remembered")

    // From the switch it is held, and counted when the real key arrives and verifies...
    let after = rig(switched: true, holds: ["creator"])
    after.hold()
    checkEqual(after.receive(maker().msg("dave", keyOf: "mallory", keyEntryHash: "dave")), false, "held from the switch")
    checkEqual(after.status("dave"), MemberStatus.invited, "dave is still invited")
    checkEqual(after.store.heldRows.count, 1, "one held")
    after.native.know(V.identities["dave"]!)
    after.engine.decideHeld(source: hex("dave"))
    checkEqual(after.status("dave"), MemberStatus.accepted, "dave's real key arrived: it verifies and counts")
    checkEqual(after.store.heldRows.count, 0, "nothing is held any more")

    // ...and dropped when it was signed by someone else.
    let forged = rig(switched: true, holds: ["creator"])
    forged.hold()
    forged.receive(maker().msg("dave", signer: "mallory", keyOf: "mallory", keyEntryHash: "dave"))
    forged.native.know(V.identities["dave"]!)
    forged.engine.decideHeld(source: hex("dave"))
    checkEqual(forged.status("dave"), MemberStatus.invited, "its signature does not verify with dave's key: dropped")
    checkEqual(forged.store.heldRows.count, 0, "and no longer held")
}

@MainActor
func aKeylessAcceptOrLeaveCountsBeforeTheSwitchAndIsHeldFromItUntilItsSendersKeyArrives() {
    let before = rig(holds: ["creator"])
    before.hold()
    checkEqual(before.receive(maker().msg("erin", key: false, retichat: false)), true, "a client from before this change: counts")
    checkEqual(before.status("erin"), MemberStatus.accepted, "erin is accepted")

    let after = rig(switched: true, holds: ["creator"])
    after.hold()
    checkEqual(after.receive(maker().msg("erin", key: false, retichat: false)), false, "from the switch it is held")
    checkEqual(after.status("erin"), MemberStatus.invited, "erin is still invited")
    checkEqual(after.store.heldRows.map { "\(V.nameOf($0.srcHex)) \($0.action)" }, ["erin accept"], "held with what its signature covers")
    check(after.store.lines.isEmpty, "nothing is said until it counts")
    // Nothing else is decided by the key of someone else.
    after.native.know(V.identities["dave"]!)
    after.engine.decideHeld(source: hex("dave"))
    checkEqual(after.store.heldRows.count, 1, "the key of another member decides nothing")
    after.native.know(V.identities["erin"]!)
    after.engine.decideHeld(source: hex("erin"))
    checkEqual(after.status("erin"), MemberStatus.accepted, "erin's key is here: counted")
    checkEqual(after.store.heldRows.count, 0, "nothing is held")
}

@MainActor
func aKeyAlreadyHeldDecidesWhetherOrNotTheMessageCarriesOne() {
    // Held key, no key carried: verified.
    let r = rig(holds: ["creator", "alice"])
    r.hold()
    checkEqual(r.receive(maker().msg("alice", key: false)), true, "verified by the held key alone")
    // Held key, forged message that carries its sender's real key: invalid under the held key too.
    let forged = rig(holds: ["creator", "carol"])
    forged.hold()
    check(forged.receive(maker().msg("carol", signer: "mallory")) == nil, "the held key decides: forged")
    check(forged.native.remembered.isEmpty, "and nothing is remembered")
}

@MainActor
func aKeyedMessageDecidesAMembersOlderHeldAcceptFirstSoTheyCountInTheOrderTheyCameFromTheSwitch() {
    let r = rig(switched: true, holds: ["creator"])
    r.hold()
    let m = maker()
    checkEqual(r.receive(m.msg("erin", key: false)), false, "the old client's accept is held")
    checkEqual(r.receive(m.msg("erin", action: GroupAction.leave)), true, "a keyed leave verifies")
    // The held accept was decided before the leave: erin joined, then left, and a leave is final.
    checkEqual(r.status("erin"), MemberStatus.left, "left, for good")
    checkEqual(r.store.lines.map { $0.joined }, [true, false], "they counted in the order they came")
    checkEqual(r.store.heldRows.count, 0, "nothing is held")
}

@MainActor
func aMessageItsSourceSignedDecidesWhatWasHeldForThatSourcesKeyBeforeItself() {
    let r = rig(switched: true, holds: ["creator"])
    r.hold()
    let m = maker()
    r.receive(m.msg("bob", key: false))
    checkEqual(r.status("bob"), MemberStatus.invited, "held")
    // A message bob signed (validated: his key arrived with it) shows his key is here.
    r.receive(m.msg("bob", action: GroupAction.leave))
    checkEqual(r.store.lines.map { $0.joined }, [true, false], "the held accept counted before the leave")
}

@MainActor
func onlyAListedMembersOwnAcceptOrLeaveCountsAndNoKeyIsRememberedFromAMessageTheRuleDropped() {
    let r = rig(holds: ["creator"])
    r.hold()
    let m = maker()
    check(r.receive(m.msg("mallory")) == nil, "a sender no list names is dropped")
    check(r.receive(m.msg("alice", sender: "bob")) == nil, "a message that names another member is dropped")
    check(r.native.remembered.isEmpty, "no key is remembered from either")
    checkEqual(r.dropped, ["accept from mallory", "accept from alice"], "said")
    checkEqual(r.statuses().values.filter { $0 == MemberStatus.accepted }.count, 2, "only the creator and the user are accepted")
}

@MainActor
func theCreatorsAcceptIsNotNeededAMembersAcceptInAPendingGroupCountsAndIsRecordedTheUsersAcceptStillAllowsEveryMemberAndNobodyBeforeIt() {
    let r = rig(holds: ["creator"])
    r.hold(accepted: false)
    checkEqual(r.receive(maker().msg("alice")), true, "an accept in a pending group counts")
    checkEqual(r.status("alice"), MemberStatus.accepted, "and is recorded")
    check(r.store.allowed.isEmpty, "but lets nobody through the privacy filter: the members pass from the user's accept")
    // The user accepts the group: from then on a member's accept lets it through.
    r.store.chats[r.chatId] = GroupChatInfo(id: r.chatId, creatorHex: hex("creator"), groupStatus: "active")
    r.receive(maker().msg("bob"))
    checkEqual(r.store.allowed, [hex("bob")], "in a joined group a member's accept allows it")
}

@MainActor
func aStampedAcceptIsVerifiedUnderItsCarriedKeyLikeAnyOtherTheStampIsNotSigned() {
    let r = rig(holds: ["creator"])
    r.hold()
    checkEqual(r.receive(maker().msg("alice", stamp: true)), true, "a stamped accept counts")
    checkEqual(r.status("alice"), MemberStatus.accepted, "verified: the stamp is not part of what is signed")
    let u = r.native.unpack(maker().msg("alice", stamp: true))
    checkEqual(u?.signature, DeliveryPolicy.Signature.validated, "validated")
}

// MARK: - The creator

@MainActor
func theCreatorKeepsEachMembersNewestCountedMessageAsReceivedAndAnswersEachKeyedAcceptWithTheOthersCopiesByMemberHash() {
    let r = creatorRig()
    let m = maker()
    let alice = m.msg("alice"), bob = m.msg("bob"), dave = m.msg("dave")
    r.receive(alice)
    checkEqual(r.answeredNames(), ["alice"], "alice's keyed accept is answered")
    checkEqual(r.answers[0].statuses, [], "with nothing: nobody else has answered (an empty answer is valid)")
    r.receive(bob)
    r.receive(dave)
    checkEqual(r.answeredNames(), ["alice", "bob", "dave"], "each keyed accept is answered, to its sender alone")
    // The answer holds the others' copies exactly as received, by member hash ascending, never the recipient's own.
    let expectedForDave = [alice, bob].sorted { (a: Data, b: Data) in hex(V.nameOf(Data(a[16..<32]).hexString)) < hex(V.nameOf(Data(b[16..<32]).hexString)) }
    checkEqual(r.answers[2].statuses, expectedForDave, "the others' copies as received, by hash ascending")
    checkEqual(r.answers[2].statuses.contains(dave), false, "never the recipient's own")
}

@MainActor
func aStatusAnswersTheAcceptThatJustCountedARepeatedAcceptAnotherMessageIsAnsweredAgainAndIsTheNewestCopy() {
    let r = creatorRig()
    let m = maker()
    let first = m.msg("alice"), second = m.msg("alice")
    r.receive(first)
    r.receive(second)
    checkEqual(r.answeredNames(), ["alice", "alice"], "a repeated accept is answered again")
    checkEqual(r.store.copy(chatId: r.chatId, memberHex: hex("alice"))?.packed, second, "and is the newest copy")
}

@MainActor
func aLeaveIsKeptAsTheCopyAndIsFinalNothingReplacesItALaterAcceptIsDroppedAndNeitherIsAnswered() {
    let r = creatorRig()
    let m = maker()
    r.receive(m.msg("bob", action: GroupAction.leave))
    let leave = r.store.copy(chatId: r.chatId, memberHex: hex("bob"))
    checkEqual(leave?.action, GroupAction.leave, "the leave is the copy")
    check(r.answers.isEmpty, "a leave is never answered")
    check(r.receive(m.msg("bob")) == nil, "a later accept is dropped")
    checkEqual(r.store.copy(chatId: r.chatId, memberHex: hex("bob"))?.packed, leave?.packed, "nothing replaces the leave")
    check(r.answers.isEmpty, "and is not answered")
}

@MainActor
func theCreatorsOwnCopyIsNeverSentInAnAnswerNorTheRecipientsEvenIfOneWereKept() {
    let r = creatorRig()
    let m = maker()
    let alice = m.msg("alice")
    // A copy kept for the creator itself and for the recipient (nothing keeps them; the answer must not carry them anyway).
    r.store.putCopy(chatId: r.chatId, memberHex: hex("creator"), action: GroupAction.accept, packed: Data(repeating: 1, count: 120))
    r.store.putCopy(chatId: r.chatId, memberHex: hex("bob"), action: GroupAction.accept, packed: Data(repeating: 2, count: 120))
    r.receive(alice)
    checkEqual(r.answers.count, 1, "alice is answered")
    checkEqual(r.answers[0].statuses, [Data(repeating: 2, count: 120)], "bob's copy only: neither the creator's own nor alice's")
}

@MainActor
func onlyAKeyedAcceptIsAnsweredNotAKeylessOneALeaveAForgedOneANonMembersOrAnotherGroupsHeldKeyOrNot() {
    for holds in [[], ["alice", "bob", "carol", "dave", "erin", "mallory"]] {
        let r = creatorRig(holds: holds)
        let m = maker()
        r.receive(m.msg("bob", key: false, retichat: false))
        r.receive(m.msg("alice", action: GroupAction.leave))
        r.receive(m.msg("carol", signer: "mallory"))
        r.receive(m.msg("mallory"))
        r.receive(m.msg("dave", groupId: String(repeating: "ab", count: 16)))
        check(r.answers.isEmpty, "none of these is answered (holding \(holds.count) keys)")
        r.receive(m.msg("erin"))
        checkEqual(r.answeredNames(), ["erin"], "a keyed accept is (holding \(holds.count) keys)")
    }
}

@MainActor
func theOldClientsUnverifiedAcceptIsTheCopyUntilAKeyedOneReplacesItAndAHeldAcceptIsKeptOnceItCounts() {
    let r = creatorRig()
    let m = maker()
    let old = m.msg("erin", key: false, retichat: false)
    r.receive(old)
    checkEqual(r.store.copy(chatId: r.chatId, memberHex: hex("erin"))?.packed, old, "the unverified accept counts, so it is the copy")
    check(r.answers.isEmpty, "and is not answered: it carries no key")
    let keyed = m.msg("erin")
    r.receive(keyed)
    checkEqual(r.store.copy(chatId: r.chatId, memberHex: hex("erin"))?.packed, keyed, "a keyed one replaces it")
    checkEqual(r.answeredNames(), ["erin"], "and is answered")

    // From the switch a keyless accept is held, and is the copy once its key arrives and it counts.
    let held = creatorRig(switched: true)
    let heldOld = m.msg("dave", key: false, retichat: false)
    held.receive(heldOld)
    check(held.store.copy(chatId: held.chatId, memberHex: hex("dave")) == nil, "a held accept is no copy yet")
    held.native.know(V.identities["dave"]!)
    held.engine.decideHeld(source: hex("dave"))
    checkEqual(held.store.copy(chatId: held.chatId, memberHex: hex("dave"))?.packed, heldOld, "kept once it counts")
}

@MainActor
func aCopyIsKeptOnlyForAListedMemberThatHasNotLeftAndNeverOverTheLimitTheAcceptStillCounts() {
    let r = creatorRig()
    let m = maker()
    let big = m.msg("alice", content: Data(repeating: 0x61, count: 3000))
    check(big.count > GroupStatuses.statusPackedLimit, "it is over the limit")
    checkEqual(r.receive(big), true, "the accept still counts")
    check(r.store.copy(chatId: r.chatId, memberHex: hex("alice")) == nil, "but no copy of it is kept")
    checkEqual(r.status("alice"), MemberStatus.accepted, "alice is accepted")
}

@MainActor
func onlyTheCreatorAnswersAMemberThatGetsAnAcceptSendsNothingAGroupWhoseCreatorIsNotRecordedHeldBeforeThisChangeNeitherKeepsNorAnswers() {
    let member = rig(me: "alice", holds: ["creator"])
    member.hold(accepted: true)
    member.receive(maker().msg("bob"))
    check(member.answers.isEmpty, "a member sends nothing")
    check(member.store.copyRows.isEmpty, "and keeps no copy")

    let legacy = GroupRig(V, me: V.creator)
    legacy.hold(accepted: true, creatorRecorded: false)
    legacy.receive(maker().msg("bob"))
    check(legacy.answers.isEmpty, "a group whose creator is not recorded answers nothing")
    check(legacy.store.copyRows.isEmpty, "and keeps nothing")
    checkEqual(legacy.status("bob"), MemberStatus.accepted, "the accept itself counts")
}

@MainActor
func nothingReplacesALeaveCopyEvenIfTheMemberRowStillSaysInvitedAndACopyOverTheLimitIsNeverKept() {
    let r = creatorRig()
    r.store.putCopy(chatId: r.chatId, memberHex: hex("alice"), action: GroupAction.leave, packed: Data(repeating: 9, count: 120))
    // The row still says invited (a leave copy kept before the row moved, or a row that never moved).
    r.receive(maker().msg("alice"))
    checkEqual(r.store.copy(chatId: r.chatId, memberHex: hex("alice"))?.action, GroupAction.leave, "the leave copy stays")
    checkEqual(r.store.copy(chatId: r.chatId, memberHex: hex("alice"))?.packed, Data(repeating: 9, count: 120), "byte for byte")
}

@MainActor
func theHeldStoreIsBoundedAMessageIsHeldOnceFourForAMemberAndOneHundredTwentyEightInAllAreHeldTheRestDroppedAndThoseHeldStay() {
    let r = rig(switched: true, holds: ["creator"])
    r.hold()
    let m = maker()
    let first = m.msg("alice", key: false)
    r.receive(first)
    r.receive(first)
    checkEqual(r.store.heldRows.count, 1, "a message is held once")
    for _ in 0..<6 { r.receive(m.msg("alice", key: false)) }
    checkEqual(r.store.heldRows.count, 4, "four for a member of a group, the rest dropped")
    check(r.store.heldRows.first?.packed == first, "and those held stay")
    check(r.logs.contains { $0.contains("4 are held for this member already") }, "the drop is said")
    // 128 in all, across groups.
    let many = rig(switched: true, holds: ["creator"])
    for index in 0..<40 {
        let gid = String(format: "%032x", index + 1)
        many.hold(groupId: gid)
        for _ in 0..<4 { many.receive(m.msg("alice", key: false, groupId: gid)) }
    }
    checkEqual(many.store.heldRows.count, 128, "128 in all")
    check(many.logs.contains { $0.contains("128 are held already") }, "the drop is said")
}

@MainActor
func whatIsHeldForAGroupThatIsGoneIsReleasedWithoutEffectAndAKeyForSeveralSourcesDecidesThemAllInOrder() {
    let r = rig(switched: true, holds: ["creator"])
    r.hold()
    let m = maker()
    r.receive(m.msg("alice", key: false))
    r.receive(m.msg("bob", key: false))
    r.receive(m.msg("carol", key: false))
    checkEqual(r.store.heldRows.count, 3, "three held")
    r.native.know(V.identities["alice"]!)
    r.native.know(V.identities["bob"]!)
    r.native.know(V.identities["carol"]!)
    // The group goes (the user left and deleted it): what was held for it is released without effect.
    r.store.chats[r.chatId] = nil
    r.engine.decideHeld()
    checkEqual(r.store.heldRows.count, 0, "released")
    check(r.store.lines.isEmpty, "with no effect")

    let both = rig(switched: true, holds: ["creator"])
    both.hold()
    both.receive(m.msg("alice", key: false))
    both.receive(m.msg("bob", key: false))
    both.native.know(V.identities["alice"]!)
    both.native.know(V.identities["bob"]!)
    both.engine.decideHeld()
    checkEqual(both.store.lines.map { V.nameOf($0.member) }, ["alice", "bob"], "decided in the order they came")
}

@MainActor
func theEngineKeepsNoCopyForAMemberThatLeftOrOverTheLimitAndRemembersNoKeyFromAnythingButAnAcceptOrLeaveOrFromItself() {
    // What reaches the engine directly (the group rule would have dropped it): a member the row says left, and a copy over the limit.
    let r = creatorRig()
    let m = maker()
    r.store.memberRows[r.chatId] = r.store.members(chatId: r.chatId).map { $0.hash == hex("bob") ? (hash: $0.hash, status: MemberStatus.left) : $0 }
    let chat = r.store.chats[r.chatId]!
    func arrival(_ name: String, _ packed: Data) -> GroupArrival {
        let u = r.native.receipt(packed)!
        return GroupArrival(msgId: u.hash.hexString, src: hex(name), chat: chat, action: GroupAction.accept, timestamp: u.timestamp,
                            signature: u.signature, senderKey: u.senderKey, packed: packed)
    }
    r.engine.takeDirect(arrival("bob", m.msg("bob")))
    check(r.store.copy(chatId: r.chatId, memberHex: hex("bob")) == nil, "no copy is kept for a member that left")
    let big = m.msg("alice", content: Data(repeating: 0x61, count: 3000))
    checkEqual(r.engine.takeDirect(arrival("alice", big)), true, "an accept over the limit still counts")
    check(r.store.copy(chatId: r.chatId, memberHex: hex("alice")) == nil, "but no copy of it is kept")
    // A member's key is remembered from an accept or a leave it carries, and from nothing else, and never this device's own.
    let key = V.identities["alice"]!.publicKey
    let v = DeliveryPolicy.Signature.validated
    r.engine.onKept(src: hex("alice"), action: GroupAction.invite, signature: v, senderKey: key)
    r.engine.onKept(src: hex("alice"), action: nil, signature: v, senderKey: key)
    r.engine.onKept(src: hex("alice"), action: GroupAction.relayRequest, signature: v, senderKey: key)
    check(r.native.remembered.isEmpty, "no key is remembered from an invite, a post or a relay request")
    r.engine.onKept(src: r.selfHex, action: GroupAction.accept, signature: v, senderKey: V.identities["creator"]!.publicKey)
    check(r.native.remembered.isEmpty, "never this device's own")
    r.engine.onKept(src: hex("alice"), action: GroupAction.accept, signature: v, senderKey: key)
    checkEqual(r.native.remembered, [hex("alice")], "from an accept it is")
    r.engine.onKept(src: hex("bob"), action: GroupAction.leave, signature: v, senderKey: key)
    check(r.logs.contains { $0.contains("Ignored mismatched member key") }, "a key that does not produce the member's destination is ignored, said")
}

// MARK: - Receiving a status

@MainActor
func listing(_ m: MessageMaker) -> [Data] { [m.msg("alice"), m.msg("bob", action: GroupAction.leave), m.msg("erin", key: false, retichat: false)] }

@MainActor
func theLateAcceptorTheAcceptsItsClientNeverSawComeBackInTheCreatorsAnswerToItsOwnAcceptAndApplyUnderTheNormalRules() {
    let r = rig(holds: ["creator"])
    r.hold(accepted: true)
    let m = maker()
    checkEqual(r.receive(m.status(to: "frank", elements: listing(m))) == nil, true, "a status is not an accept")
    checkEqual(r.lastTally, StatusTally(elements: 3, counted: 3, held: 0, skipped: 0), "all three counted")
    checkEqual(r.status("alice"), MemberStatus.accepted, "alice accepted")
    checkEqual(r.status("bob"), MemberStatus.left, "bob left")
    checkEqual(r.status("erin"), MemberStatus.accepted, "erin accepted (unverified, before the switch)")
    checkEqual(Set(r.store.allowed), Set([hex("alice"), hex("erin")]), "the members who accepted pass the filter, from the user's accept")
}

@MainActor
func aStatusCountsOnlyFromTheGroupsCreatorWhoseSignatureShowsItEachOtherSourceIsDroppedUnproved() {
    func fresh() -> GroupRig {
        let r = rig(holds: ["creator", "dave"])
        r.hold(accepted: true)
        return r
    }
    let m = maker()
    let elements = [m.msg("alice")]
    // From the creator, signed by it: counts.
    let ok = fresh()
    ok.receive(m.status(to: "frank", elements: elements))
    checkEqual(ok.lastTally?.counted, 1, "the creator's status counts")
    // From a member who is not the creator, though signed by it: dropped, even though its element is genuine.
    let notCreator = fresh()
    notCreator.receive(m.status(to: "frank", elements: elements, from: "dave"))
    check(notCreator.lastTally == nil && notCreator.status("alice") == MemberStatus.invited, "a status from another member is dropped")
    // From the creator, signed by someone else: forged.
    let forged = fresh()
    forged.receive(m.status(to: "frank", elements: elements, signer: "mallory"))
    check(forged.lastTally == nil && forged.status("alice") == MemberStatus.invited, "a forged status is dropped")
    // From the creator, whose key is not held: not proven.
    let unproven = rig(holds: [])
    unproven.hold(accepted: true)
    unproven.receive(m.status(to: "frank", elements: elements))
    check(unproven.lastTally == nil && unproven.status("alice") == MemberStatus.invited, "a status nobody can verify is dropped")
}

@MainActor
func aStatusCountsOnlyInAGroupTheUserHasAcceptedAPendingGroupsAGroupNotHeldAndOneTheUserLeftAreDroppedUnprovedAndNothingIsApplied() {
    let m = maker()
    let pending = rig(holds: ["creator"])
    pending.hold(accepted: false)
    pending.receive(m.status(to: "frank", elements: [m.msg("alice")]))
    check(pending.lastTally == nil && pending.status("alice") == MemberStatus.invited, "a pending group takes no status")
    let none = rig(holds: ["creator"])
    none.receive(m.status(to: "frank", elements: [m.msg("alice")]))
    check(none.lastTally == nil && none.dropped == ["status from creator"], "a group not held takes none")
    // The engine itself reads nothing for a group the user has not accepted, whatever reaches it.
    let direct = rig(holds: ["creator"])
    let chat = direct.hold(accepted: false)
    let tally = direct.engine.takeStatuses(chat: chat, elements: [m.msg("alice")])
    checkEqual(tally, StatusTally(elements: 1, counted: 0, held: 0, skipped: 1), "the engine skips every element")
    checkEqual(direct.status("alice"), MemberStatus.invited, "and applies nothing")
}

@MainActor
func eachElementIsCheckedOnItsOwnAFailingOneIsSkippedAndTheRestApplyTheCreatorPassesOnOnlyWhatMembersSigned() {
    let r = rig(holds: ["creator", "carol"])
    r.hold(accepted: true)
    let m = maker()
    let other = String(repeating: "cd", count: 16)
    let elements: [Data] = [
        m.msg("alice"),                                       // genuine
        m.msg("carol", signer: "mallory"),                    // carol's name, mallory's signature: forged under carol's held key
        Data(repeating: 7, count: 200),                       // not an LXMF message
        m.msg("dave", groupId: other),                        // another group's
        m.msg("mallory"),                                     // nobody the group lists
        m.msg("bob", action: GroupAction.leave),              // genuine
    ]
    r.receive(m.status(to: "frank", elements: elements))
    checkEqual(r.lastTally, StatusTally(elements: 6, counted: 2, held: 0, skipped: 4), "two counted, four skipped")
    checkEqual(r.status("alice"), MemberStatus.accepted, "alice's counted")
    checkEqual(r.status("bob"), MemberStatus.left, "bob's counted")
    checkEqual(r.status("carol"), MemberStatus.invited, "the forged one changed nothing")
    check(r.logs.contains { $0.contains("its signature does not verify") }, "the forgery is said")
    check(r.logs.contains { $0.contains("about another group") }, "the other group's is said")
    check(r.native.remembered.contains(hex("alice")) && !r.native.remembered.contains(hex("mallory")), "only a counted element's key is remembered")
}

@MainActor
func anElementIsAboutThisStatusesGroupAloneAndOneOverTheSizeLimitIsSkippedWhileTheSameMessageDirectlyIsNot() {
    let r = rig(holds: ["creator"])
    r.hold(accepted: true)
    let m = maker()
    let big = m.msg("alice", content: Data(repeating: 0x61, count: 3000))
    let direct = rig(holds: ["creator"])
    direct.hold(accepted: true)
    checkEqual(direct.receive(big), true, "the same message directly counts (an accept's size is the creator's choice to keep or not)")
    r.receive(m.status(to: "frank", elements: [big]))
    checkEqual(r.lastTally, StatusTally(elements: 1, counted: 0, held: 0, skipped: 1), "as an element it is skipped")
    check(r.logs.contains { $0.contains("is not the size of an accept or leave") }, "said")
    checkEqual(r.status("alice"), MemberStatus.invited, "alice is untouched")
}

@MainActor
func anElementAppliesWithTheNormalRulesALeaveStaysFinalAndOrderDoesNotMatterWhetherTheElementsTheDirectMessagesOrBothComeFirst() {
    let m = maker()
    let accept = m.msg("bob"), leave = m.msg("bob", action: GroupAction.leave)
    for elements in [[accept, leave], [leave, accept]] {
        let r = rig(holds: ["creator"])
        r.hold(accepted: true)
        r.receive(m.status(to: "frank", elements: elements))
        checkEqual(r.status("bob"), MemberStatus.left, "left, whichever order the elements come in")
    }
    // The element first, then the direct message, and the direct message first, then the element.
    let a = rig(holds: ["creator"])
    a.hold(accepted: true)
    a.receive(m.status(to: "frank", elements: [leave]))
    check(a.receive(m.msg("bob")) == nil, "a direct accept after an element's leave is dropped")
    checkEqual(a.status("bob"), MemberStatus.left, "final")
    let b = rig(holds: ["creator"])
    b.hold(accepted: true)
    b.receive(m.msg("bob", action: GroupAction.leave))
    b.receive(m.status(to: "frank", elements: [accept]))
    checkEqual(b.lastTally, StatusTally(elements: 1, counted: 0, held: 0, skipped: 1), "an element's accept after a direct leave is skipped")
    checkEqual(b.status("bob"), MemberStatus.left, "final")
}

@MainActor
func anUnverifiableElementCountsUntilTheSwitchAndIsHeldFromItAForgedOneUnderAHeldKeyIsSkippedEitherWay() {
    let m = maker()
    let keyless = m.msg("erin", key: false, retichat: false)
    for switched in bothForms {
        let r = rig(switched: switched, holds: ["creator"])
        r.hold(accepted: true)
        r.receive(m.status(to: "frank", elements: [keyless]))
        checkEqual(r.lastTally, StatusTally(elements: 1, counted: switched ? 0 : 1, held: switched ? 1 : 0, skipped: 0),
                   "an unverifiable element \(switched ? "is held from" : "counts until") the switch")
        checkEqual(r.status("erin"), switched ? MemberStatus.invited : MemberStatus.accepted, "erin's status")
        checkEqual(r.store.heldRows.count, switched ? 1 : 0, "held")
        let forged = rig(switched: switched, holds: ["creator", "carol"])
        forged.hold(accepted: true)
        forged.receive(m.status(to: "frank", elements: [m.msg("carol", signer: "mallory")]))
        checkEqual(forged.lastTally, StatusTally(elements: 1, counted: 0, held: 0, skipped: 1), "a forged one under a held key is skipped, switched \(switched)")
    }
}

@MainActor
func aStatusReadsAtMostAsManyElementsAsTheGroupHasMembersAnEmptyOneOrOneWithNoKeyTenChangesNothingAndTheSameStatusTwiceIsOne() {
    let m = maker()
    let r = rig(holds: ["creator"])
    r.hold(accepted: true)
    // 7 members: 20 elements, 7 read, each a signature check.
    let many = (0..<20).map { _ in m.msg("alice") }
    r.receive(m.status(to: "frank", elements: many))
    checkEqual(r.lastTally?.elements, 20, "twenty were sent")
    checkEqual((r.lastTally?.counted ?? 0) + (r.lastTally?.skipped ?? 0), 20, "every one is counted or skipped")
    check(r.native.unpacked <= 8, "no more than the member list's length were unpacked")
    // Empty, and no key 10: nothing changes.
    let empty = rig(holds: ["creator"])
    empty.hold(accepted: true)
    empty.receive(m.status(to: "frank", elements: []))
    checkEqual(empty.lastTally, StatusTally(elements: 0, counted: 0, held: 0, skipped: 0), "an empty status")
    empty.receive(m.status(to: "frank", elements: nil))
    checkEqual(empty.lastTally, StatusTally(elements: 0, counted: 0, held: 0, skipped: 0), "a status with no key 10")
    check(empty.store.lines.isEmpty, "changes nothing")
    // The same status twice is one: the second changes nothing and says nothing.
    let twice = rig(holds: ["creator"])
    twice.hold(accepted: true)
    let status = m.status(to: "frank", elements: [m.msg("alice")])
    twice.receive(status)
    twice.receive(status)
    checkEqual(twice.store.lines.count, 1, "said once")
    checkEqual(twice.status("alice"), MemberStatus.accepted, "accepted")
}

@MainActor
func theCreatorsStatusIsReadWholeEvenOnceTheCreatorHasLeftBeingOnlyTheCarrierOfWhatMembersSigned() {
    let r = rig(holds: ["creator"])
    r.hold(accepted: true)
    let rows = r.store.members(chatId: r.chatId).map { $0.hash == hex("creator") ? (hash: $0.hash, status: MemberStatus.left) : $0 }
    r.store.memberRows[r.chatId] = rows
    let m = maker()
    r.receive(m.status(to: "frank", elements: [m.msg("alice")]))
    checkEqual(r.lastTally?.counted, 1, "a status from a creator that left is read whole")
    checkEqual(r.status("alice"), MemberStatus.accepted, "what a member signed counts")
}

func statusRule(held: DeliveryPolicy.Held, creator: Bool, signature: Int) -> Bool {
    DeliveryPolicy.shouldProcess(action: GroupAction.status, sourceAllowed: false, held: held, sourceStatus: MemberStatus.accepted,
                                 namesOther: false, closed: false, signature: signature, sourceIsCreator: creator)
}

@MainActor
func theGroupRuleForAStatusAsATableOnlyTheCreatorOnlyForAJoinedGroupOnlyASignatureThatShowsIt() {
    let validated = DeliveryPolicy.Signature.validated
    for held in [DeliveryPolicy.Held.none, .pending, .joined] {
        for creator in bothForms {
            for signature in [DeliveryPolicy.Signature.validated, DeliveryPolicy.Signature.sourceUnknown, DeliveryPolicy.Signature.invalid] {
                let expected = held == .joined && creator && signature == validated
                checkEqual(statusRule(held: held, creator: creator, signature: signature), expected,
                           "status: held \(held), creator \(creator), signature \(signature)")
            }
        }
    }
    // The default is no creator: a group whose creator is not recorded takes no status.
    checkEqual(DeliveryPolicy.shouldProcess(action: GroupAction.status, sourceAllowed: false, held: .joined, sourceStatus: nil,
                                            namesOther: false, closed: false, signature: validated), false, "no creator recorded: dropped")
}

// MARK: - Key 10 in the fields, the envelopes

@MainActor
func groupStatusesReadsKeyTenOfTheRetichatFieldOnlyAndAnArrayOnlyElementsAsTheyCame() {
    let packed = Data(repeating: 3, count: 300)
    func fields(_ top: [(Data, Data)] = [], retichat: [(Data, Data)]?) -> Data {
        var entries = top
        if let retichat { entries.append((MP.uint(0xD1), MP.map(retichat))) }
        return MP.map(entries)
    }
    let key9 = (MP.uint(9), MP.str("x"))
    // In the Retichat field: an array of bin, read in order.
    checkEqual(LxmfFieldsDecoder.decode(fields(retichat: [(MP.uint(10), MP.array([MP.bin(packed), MP.bin(Data([1]))]))])).groupStatuses,
               [packed, Data([1])], "key 10 of the Retichat field")
    // Elements as they came: a str and an int are not bins.
    checkEqual(LxmfFieldsDecoder.decode(fields(retichat: [(MP.uint(10), MP.array([MP.bin(Data([2])), MP.str("no"), MP.uint(5)]))])).groupStatuses,
               [Data([2]), nil, nil], "elements as they came")
    // Never from a top-level field: it has no old one.
    check(LxmfFieldsDecoder.decode(fields([(MP.uint(10), MP.array([MP.bin(packed)]))], retichat: nil)).groupStatuses == nil, "not from field 0x0A")
    check(LxmfFieldsDecoder.decode(fields([(MP.uint(0xAA), MP.array([MP.bin(packed)]))], retichat: nil)).groupStatuses == nil, "not from 0xAA either")
    // Not an array, no key 10, or a 0xD1 that is not a map: none.
    check(LxmfFieldsDecoder.decode(fields(retichat: [(MP.uint(10), MP.bin(packed))])).groupStatuses == nil, "a bin is not an array")
    check(LxmfFieldsDecoder.decode(fields(retichat: [(MP.uint(1), MP.str("g"))])).groupStatuses == nil, "no key 10")
    check(LxmfFieldsDecoder.decode(MP.map([(MP.uint(0xD1), MP.array([MP.bin(packed)]))])).groupStatuses == nil, "a 0xD1 that is not a map")
    // A malformed key 10 costs the entries after it nothing, and the group entries read as ever.
    let mixed = LxmfFieldsDecoder.decode(fields(retichat: [(MP.uint(10), MP.str("x")), (MP.uint(1), MP.str("gid")), key9]))
    checkEqual(mixed.groupId, "gid", "the group id after a malformed key 10")
    // Key 10 is not a group entry: the nine are what they were.
    checkEqual(GroupEntry.allCases.count, 9, "nine group entries")
    check(LxmfFieldsDecoder.decode(fields(retichat: [(MP.uint(10), MP.array([MP.bin(packed)])), (MP.uint(4), MP.str("status"))])).groupAction == "status",
          "the action beside key 10")
}

@MainActor
func theEnvelopesCarryExactlyTheUsersOwnKeyAnAcceptAndALeaveInBothFormsAndAStatusItsThreeEntries() {
    let alice = V.identities["alice"]!
    let own = GroupEnvelopes.ownKeyEntry(selfHex: alice.hashHex, publicKey: alice.publicKey)
    checkEqual(own, alice.keyEntry, "the entry is hash:base64 of the key")
    for (name, entries) in [("accept", GroupEnvelopes.accept(groupId: V.groupId, selfHex: alice.hashHex, ownKey: own)),
                            ("leave", GroupEnvelopes.leave(groupId: V.groupId, selfHex: alice.hashHex, ownKey: own))] {
        checkEqual(entries.map { $0.entry }, [.id, .action, .sender, .memberKeys], "\(name): id, action, sender and the key, last")
        checkEqual(entries.last?.value, own, "\(name): exactly the user's own entry")
        checkEqual(entries.filter { $0.entry == .memberKeys }.count, 1, "\(name): one key entry")
        let writes = GroupEnvelopes.writes(entries, inRetichatField: false)
        checkEqual(writes.last, .topLevel(field: 0xA8, value: .str(own)), "\(name): old field 0xA8 until the switch")
        checkEqual(GroupEnvelopes.writes(entries, inRetichatField: true).last, .retichat(key: 9, value: .str(own)), "\(name): key 9 after it")
    }
    // The key cannot be read: the message goes without it, as a build from before this change sends it.
    checkEqual(GroupEnvelopes.accept(groupId: V.groupId, selfHex: alice.hashHex, ownKey: nil).map { $0.entry }, [.id, .action, .sender],
               "no key, no entry")
    checkEqual(GroupEnvelopes.status(groupId: V.groupId, selfHex: alice.hashHex),
               [GroupEnvelopes.Entry(entry: .id, value: V.groupId), GroupEnvelopes.Entry(entry: .action, value: "status"),
                GroupEnvelopes.Entry(entry: .sender, value: alice.hashHex)], "a status: GROUP_ID, the action and the creator")
}

/// The buffer the glue writes for an unpacked element, pinned to the one literal the Rust test pins
/// (group_status.rs ELEMENT_HEX): alice's keyed accept in the Retichat form.
@MainActor
func theUnpackBufferIsExactlyTheseBytesWhichTheGlueCratePinsTooAndSwiftReadsThemBack() {
    let rust = source("rust/retichat-ffi/src/group_status.rs")
    guard let at = rust.range(of: "const ELEMENT_HEX: &str = \""),
          let end = rust.range(of: "\";", range: at.upperBound..<rust.endIndex) else { check(false, "the literal is in the crate"); return }
    let literal = String(rust[at.upperBound..<end.lowerBound])
    guard let parsed = UnpackedGroupMessage.parse(unhex(literal)) else { check(false, "the literal parses"); return }
    let m = V.message("alice_accept_keyed_retichat")
    checkEqual(parsed.signature, 0, "validated")
    checkEqual(parsed.destination.hexString, V.hashOf("creator"), "to the creator")
    checkEqual(parsed.source.hexString, V.hashOf("alice"), "from alice")
    checkEqual(parsed.hash, m.messageHash, "alice's keyed accept in the Retichat form: its hash")
    checkEqual(parsed.senderKey, V.identities["alice"]!.publicKey, "carrying alice's key")
    checkEqual(parsed.timestamp, m.timestamp, "its time")
    checkEqual(parsed.fieldsRaw, m.fieldsRaw, "and its fields")
    // Anything but exactly that layout is no element.
    check(UnpackedGroupMessage.parse(Data()) == nil, "empty")
    check(UnpackedGroupMessage.parse(unhex(literal).dropLast()) == nil, "a byte short")
    check(UnpackedGroupMessage.parse(unhex(literal) + Data([0])) == nil, "a byte long")
    var bad = unhex(literal)
    bad[0] = 3
    check(UnpackedGroupMessage.parse(bad) == nil, "a verdict that is none of the three")
    bad = unhex(literal)
    bad[1] = 2
    check(UnpackedGroupMessage.parse(bad) == nil, "a key flag that is neither 0 nor 1")
    // Without a key.
    var keyless = unhex(literal)
    keyless[1] = 0
    keyless.removeSubrange(74..<138)
    checkEqual(UnpackedGroupMessage.parse(keyless)?.senderKey, nil, "a buffer without a key")
}

// MARK: - The wiring (source)

@MainActor
func theWiringDecidesInOnePlaceAndStartsNoTimerAndRetriesNothing() {
    let engine = source("Retichat/Services/GroupStatuses.swift")
    var code = ""
    for line in engine.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { code += line + "\n" }
    for clock in ["Task.sleep", "Timer", "DispatchQueue", "asyncAfter", "Date()", "schedule", "retry", "Thread.sleep"] {
        check(!code.contains(clock), "the engine names no clock or retry: \(clock)")
    }
    // The one place that decides what an accept or leave changes is applyChange, reached from takeChange alone.
    checkEqual(code.components(separatedBy: "applyChange(").count - 1, 3, "applyChange: declared, called by takeChange and by the held decision")
    checkEqual(code.components(separatedBy: "store.setMemberStatus(").count - 1, 1, "a member is moved in one place")
    checkEqual(code.components(separatedBy: "store.putCopy(").count - 1, 1, "a copy is kept in one place")
    checkEqual(code.components(separatedBy: "answer(chat, memberHex, statuses)").count - 1, 1, "a status is sent in one place, once")
    // GROUPS-DISTRO-DESIGN.md §9.4: the creator is any address of the user's in the group (D on every device of D).
    check(code.contains("guard let creator = chat.creatorHex, isSelf(chat.id, creator) else { return }"), "only the creator answers")
    check(code.contains("if counted, arrival.action == GroupAction.accept, arrival.senderKey != nil {\n            answerAccept("),
          "only an accept that counted and carries a binding key is answered")

    let repo = source("Retichat/Services/ChatRepository.swift")
    let handle = body(repo, "private func handleGroupMessage(", "/// DeliveryPolicy.author")
    check(before(handle, "groupStatuses.onKept(src: srcHex,", "switch action {")
            && before(handle, "case GroupAction.invite:", "case GroupAction.accept, GroupAction.leave:")
            && handle.contains("case GroupAction.status:") && handle.contains("groupStatuses.takeStatuses(chat: Self.groupInfo(chat), elements: fields.groupStatuses)"),
          "the key an accept carries is remembered after the rule and before anything is handled; a status goes to the engine")
    let admit = body(repo, "private func admitGroupMessage(", "/// A distro identity transfer")
    check(admit.contains("sourceIsCreator: standing.sourceIsCreator"), "the rule is told whether the source is the creator")
    let standing = body(repo, "private func groupStanding(", "/// James's group model")
    check(standing.contains("sourceIsCreator: chat?.creatorHash != nil && chat?.creatorHash == sourceHex"),
          "a group whose creator is not recorded has no creator")
    // The creator is recorded where the group is made.
    // §8.5: the group's own address, D when this device holds it, else the device.
    check(body(repo, "func createGroupChat(", "func archiveChat(").contains("creatorHash: own,")
            && body(repo, "func createGroupChat(", "func archiveChat(").contains("let own = signer.hex"),
          "the group's own address for a group it creates")
    check(body(repo, "private func handleGroupInvite(", "private func insertGroupMemberLine").contains("groupStatus: \"pending\", creatorHash: srcHex"),
          "the invite's source for a group it is invited into")
    // Keys that may unlock what was held.
    let accept = body(repo, "func acceptGroupInvite(", "/// Decline a pending group invite")
    check(before(accept, "groupStatuses.decideHeld()", "chat.groupStatus = \"active\""), "the user's accept decides what was held first")
    check(body(repo, "private func handleAnnounce(", "// Remember that this address is a distro").contains("groupStatuses.decideHeld(source: hex)"),
          "an announce's key decides what was held for it")
    check(body(repo, "private func deleteChatLocal(", "/// Search across").contains("SwiftDataGroupStatusStore.deleteRows(groupId: chatId, in: ctx)"),
          "the copies and the held entries go with the group")
    // The status is sent once, off the main thread, by the group manager.
    check(repo.contains("GroupChatManager.shared.sendStatus(groupId: groupId, to: member, statuses: statuses,"), "the answer is GroupChatManager.sendStatus")
    let manager = source("Retichat/Services/GroupChatManager.swift")
    check(body(manager, "func sendAccept(").contains("GroupEnvelopes.accept(groupId: groupId, selfHex: signer.hex, ownKey: ownKey)"),
          "an accept carries the user's own key")
    let status = body(manager, "func sendStatus(")
    check(before(status, "GroupEnvelopes.status(groupId: groupId, selfHex: signer.hex)", "messageSetRetichatStatuses(handle: handle, elements: statuses)")
            && before(status, "messageSetRetichatStatuses(handle: handle, elements: statuses)", "destroyAfterSend(client: client, handle: handle)")
            && status.contains("LxmfClient.messageDestroy(handle)\n            return"),
          "a status that cannot be built is not sent")
    check(!manager.contains("Timer") && !manager.contains("Task.sleep"), "the manager waits on nothing")
    // The NSE hands an accept's key and message over, as the router's path gets them.
    let nse = source("NotificationService/NotificationService.swift")
    check(nse.contains("client.setDeliveryCallbackReceipt(nseDeliveryTrampoline)") && nse.contains("senderKeyHex:") && nse.contains("packedBase64:"),
          "the NSE keeps an accept's key and the message as received")
    check(body(repo, "func importNSEMessages()", "// Dedup").isEmpty == false
            && repo.contains("senderKey: msg.senderKeyHex.flatMap { Data(hexString: $0) },"),
          "and the import gives them to the same group rule")
}

let allTests: [(String, @MainActor () -> Void)] = [
    ("verdict: verified counts, forged is ignored, unverifiable counts until the switch and is held from it", verdictVerifiedCountsForgedIsIgnoredUnverifiableCountsUntilTheSwitchAndIsHeldFromItUncheckedIsNeverCounted),
    ("the limits agree", theLimitsAgreeACreatorKeepsAndPassesOnAPackedMessageOfAtMost96BytesPlusThePayloadLimit),
    ("a keyed accept from a source nobody holds a key for is verified by the key it carries", aKeyedAcceptFromASourceNobodyHoldsAKeyForIsVerifiedByTheKeyItCarriesRememberedAndCountsBeforeAndAfterTheSwitchInEitherForm),
    ("a keyed leave is verified, remembered and final", aKeyedLeaveFromASourceNobodyHoldsAKeyForIsVerifiedRememberedAndFinalALaterAcceptOfTheSameMemberKeyedOrNotIsDroppedUnproved),
    ("a forged accept or leave carrying its sender's real key is dropped", aForgedAcceptOrLeaveCarryingItsSendersRealKeyIsDroppedUnprovedAndTheMembersOwnMessageStillCounts),
    ("a key that does not bind is no key", aKeyThatDoesNotBindIsNoKeyCountsBeforeTheSwitchIsHeldFromItAndIsCountedOrDroppedWhenTheRealKeyArrives),
    ("a keyless accept counts before the switch and is held from it until its sender's key arrives", aKeylessAcceptOrLeaveCountsBeforeTheSwitchAndIsHeldFromItUntilItsSendersKeyArrives),
    ("a key already held decides, whether or not the message carries one", aKeyAlreadyHeldDecidesWhetherOrNotTheMessageCarriesOne),
    ("a keyed message decides a member's older held accept first", aKeyedMessageDecidesAMembersOlderHeldAcceptFirstSoTheyCountInTheOrderTheyCameFromTheSwitch),
    ("a message its source signed decides what was held for that source's key before itself", aMessageItsSourceSignedDecidesWhatWasHeldForThatSourcesKeyBeforeItself),
    ("only a listed member's own accept or leave counts and no key is remembered from a message the rule dropped", onlyAListedMembersOwnAcceptOrLeaveCountsAndNoKeyIsRememberedFromAMessageTheRuleDropped),
    ("a member's accept in a pending group counts and lets nobody through the filter", theCreatorsAcceptIsNotNeededAMembersAcceptInAPendingGroupCountsAndIsRecordedTheUsersAcceptStillAllowsEveryMemberAndNobodyBeforeIt),
    ("a stamped accept is verified under its carried key", aStampedAcceptIsVerifiedUnderItsCarriedKeyLikeAnyOtherTheStampIsNotSigned),
    ("the creator keeps each member's newest counted message and answers each keyed accept with the others' copies by member hash", theCreatorKeepsEachMembersNewestCountedMessageAsReceivedAndAnswersEachKeyedAcceptWithTheOthersCopiesByMemberHash),
    ("a repeated accept is answered again and is the newest copy", aStatusAnswersTheAcceptThatJustCountedARepeatedAcceptAnotherMessageIsAnsweredAgainAndIsTheNewestCopy),
    ("a leave is kept as the copy and is final; neither is answered", aLeaveIsKeptAsTheCopyAndIsFinalNothingReplacesItALaterAcceptIsDroppedAndNeitherIsAnswered),
    ("the creator's own copy is never sent in an answer, nor the recipient's", theCreatorsOwnCopyIsNeverSentInAnAnswerNorTheRecipientsEvenIfOneWereKept),
    ("only a keyed accept is answered", onlyAKeyedAcceptIsAnsweredNotAKeylessOneALeaveAForgedOneANonMembersOrAnotherGroupsHeldKeyOrNot),
    ("the old client's unverified accept is the copy until a keyed one replaces it", theOldClientsUnverifiedAcceptIsTheCopyUntilAKeyedOneReplacesItAndAHeldAcceptIsKeptOnceItCounts),
    ("a copy is kept only for a listed member and never over the limit; the accept still counts", aCopyIsKeptOnlyForAListedMemberThatHasNotLeftAndNeverOverTheLimitTheAcceptStillCounts),
    ("the engine keeps no copy for a member that left or over the limit, and remembers a key only from an accept or leave", theEngineKeepsNoCopyForAMemberThatLeftOrOverTheLimitAndRemembersNoKeyFromAnythingButAnAcceptOrLeaveOrFromItself),
    ("only the creator answers; a group whose creator is not recorded neither keeps nor answers", onlyTheCreatorAnswersAMemberThatGetsAnAcceptSendsNothingAGroupWhoseCreatorIsNotRecordedHeldBeforeThisChangeNeitherKeepsNorAnswers),
    ("nothing replaces a leave copy", nothingReplacesALeaveCopyEvenIfTheMemberRowStillSaysInvitedAndACopyOverTheLimitIsNeverKept),
    ("the held store is bounded", theHeldStoreIsBoundedAMessageIsHeldOnceFourForAMemberAndOneHundredTwentyEightInAllAreHeldTheRestDroppedAndThoseHeldStay),
    ("what is held for a group that is gone is released; a key for several sources decides them in order", whatIsHeldForAGroupThatIsGoneIsReleasedWithoutEffectAndAKeyForSeveralSourcesDecidesThemAllInOrder),
    ("the late acceptor gets the accepts its client never saw, in the creator's answer", theLateAcceptorTheAcceptsItsClientNeverSawComeBackInTheCreatorsAnswerToItsOwnAcceptAndApplyUnderTheNormalRules),
    ("a status counts only from the group's creator whose signature shows it", aStatusCountsOnlyFromTheGroupsCreatorWhoseSignatureShowsItEachOtherSourceIsDroppedUnproved),
    ("a status counts only in a group the user has accepted", aStatusCountsOnlyInAGroupTheUserHasAcceptedAPendingGroupsAGroupNotHeldAndOneTheUserLeftAreDroppedUnprovedAndNothingIsApplied),
    ("each element is checked on its own", eachElementIsCheckedOnItsOwnAFailingOneIsSkippedAndTheRestApplyTheCreatorPassesOnOnlyWhatMembersSigned),
    ("an element is about the status's group alone; one over the size limit is skipped", anElementIsAboutThisStatusesGroupAloneAndOneOverTheSizeLimitIsSkippedWhileTheSameMessageDirectlyIsNot),
    ("an element applies with the normal rules: a leave stays final, whatever the order", anElementAppliesWithTheNormalRulesALeaveStaysFinalAndOrderDoesNotMatterWhetherTheElementsTheDirectMessagesOrBothComeFirst),
    ("an unverifiable element counts until the switch and is held from it; a forged one is skipped either way", anUnverifiableElementCountsUntilTheSwitchAndIsHeldFromItAForgedOneUnderAHeldKeyIsSkippedEitherWay),
    ("a status reads at most as many elements as the group has members", aStatusReadsAtMostAsManyElementsAsTheGroupHasMembersAnEmptyOneOrOneWithNoKeyTenChangesNothingAndTheSameStatusTwiceIsOne),
    ("the creator's status is read whole even once the creator has left", theCreatorsStatusIsReadWholeEvenOnceTheCreatorHasLeftBeingOnlyTheCarrierOfWhatMembersSigned),
    ("the group rule for a status as a table", theGroupRuleForAStatusAsATableOnlyTheCreatorOnlyForAJoinedGroupOnlyASignatureThatShowsIt),
    ("key 10 is read from the Retichat field only, an array only, elements as they came", groupStatusesReadsKeyTenOfTheRetichatFieldOnlyAndAnArrayOnlyElementsAsTheyCame),
    ("the envelopes carry exactly the user's own key in an accept and a leave, in both forms", theEnvelopesCarryExactlyTheUsersOwnKeyAnAcceptAndALeaveInBothFormsAndAStatusItsThreeEntries),
    ("the unpack buffer is exactly the bytes the glue crate pins", theUnpackBufferIsExactlyTheseBytesWhichTheGlueCratePinsTooAndSwiftReadsThemBack),
    ("the wiring decides in one place and starts no timer and retries nothing", theWiringDecidesInOnePlaceAndStartsNoTimerAndRetriesNothing),
]

/// The text of a member from `from` to the first of the markers after it (a function's body, as these tests read source).
func body(_ text: String, _ from: String, _ to: String) -> String {
    guard let start = text.range(of: from) else { check(false, "found: \(from)"); return "" }
    guard let end = text.range(of: to, range: start.upperBound..<text.endIndex) else { check(false, "found after it: \(to)"); return "" }
    return String(text[start.lowerBound..<end.lowerBound])
}

/// The text of a member from `signature` to the next member or doc comment after it.
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { check(false, "found: \(signature)"); return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    // MARK: -", "\n    /// "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

@main
enum GroupStatusesTests {
    @MainActor
    static func main() {
        for (name, run) in allTests {
            currentTest = name
            let failed = failures.count
            run()
            print(failures.count == failed ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(allTests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
