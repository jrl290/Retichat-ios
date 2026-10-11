//
//  DistroGroupSync.swift
//  Retichat
//
//  Groups for distro holders (GROUPS-DISTRO-DESIGN.md, approved by James
//  2026-10-10; RFed-rust SPEC.md §17.14; RFed-spec Group.md): the rules the
//  app applies to group traffic that reaches it through its distro D, and to
//  the group sync G that tells the user's other devices what the user did in
//  a group as D. The decisions are here; the storage, the FFI and the sends
//  are ChatRepository's.
//
//  - DistroGroupSync: G's keys and outbox id (§6.2, §10.5), its receive rules
//    (§11.1), what applying it does by the group's state here (§11.2), its
//    `left` list (§10.2) and the writer's JSON (§17.2).
//  - GroupSelf: who "me" is in a group (§9.1), the group's own address
//    (§8.1) and who signs for it (§8.1, §8.7).
//  - GroupFirstRules: §6.3's three rules, ahead of the group rule, on both
//    paths.
//  - FilteredInvites: the invites to D the privacy filter dropped (§6.5).
//  - KnownSiblings: the user's other devices of D, learned from what D signs
//    (§9.1).
//  - HeldArrivals: group traffic held until the group is joined here, and its
//    bounds (§6.5).
//
//  Foundation only (with DeliveryPolicy.swift and LxmfFields.swift), so
//  tests/DistroGroupsTests.swift runs it for real.
//

import Foundation

// MARK: - The group sync G

nonisolated enum DistroGroupSync {
    /// `fields[0xFB]` of a group sync (SPEC §17.14).
    static let marker = "rfed.distro.group"
    /// At most this many ids in `left` (§10.2).
    static let leftLimit = 32

    enum Op: String, Sendable, CaseIterable {
        case create, accept, leave, post
    }

    /// The outbox id of the G whose LXMF hash is `hashHex` (§10.5): each G is owed on its own.
    static func entryId(hashHex: String) -> String { "group:" + hashHex }
    /// The seen-store key of a group sync (§6.2).
    static func syncSeenKey(hashHex: String) -> String { "gsync:" + hashHex }
    /// The seen-store key of a group message on the distro path (§6.2).
    static func groupSeenKey(hashHex: String) -> String { "grp:" + hashHex }

    /// An LXMF message hash as the unwrap says it: 64 hex, lowercased; nil for anything else.
    static func messageHash(_ value: String?) -> String? {
        guard let v = value?.lowercased(), v.utf8.count == 64,
              v.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return v
    }

    /// The unwrap's `group_sync` object (§7), read leniently: a key of the wrong type reads as
    /// absent, so the form check below says what is wrong instead of the whole unwrap failing.
    struct Reading: Decodable, Equatable, Sendable {
        var by: String = ""
        var problem: String? = nil
        var op: String? = nil
        var groupId: String? = nil
        var atMs: UInt64? = nil
        var name: String? = nil
        var members: String? = nil
        var keys: [String]? = nil
        var creator: String? = nil
        var text: String? = nil
        var left: [String]? = nil

        init(by: String = "", problem: String? = nil, op: String? = nil, groupId: String? = nil,
             atMs: UInt64? = nil, name: String? = nil, members: String? = nil, keys: [String]? = nil,
             creator: String? = nil, text: String? = nil, left: [String]? = nil) {
            self.by = by; self.problem = problem; self.op = op; self.groupId = groupId; self.atMs = atMs
            self.name = name; self.members = members; self.keys = keys; self.creator = creator
            self.text = text; self.left = left
        }

        private enum CodingKeys: String, CodingKey {
            case by, problem, op, group_id, at_ms, name, members, keys, creator, text, left
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            by = ((try? c.decodeIfPresent(String.self, forKey: .by)) ?? nil)?.lowercased() ?? ""
            problem = (try? c.decodeIfPresent(String.self, forKey: .problem)) ?? nil
            op = (try? c.decodeIfPresent(String.self, forKey: .op)) ?? nil
            groupId = (try? c.decodeIfPresent(String.self, forKey: .group_id)) ?? nil
            atMs = (try? c.decodeIfPresent(UInt64.self, forKey: .at_ms)) ?? nil
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
            members = (try? c.decodeIfPresent(String.self, forKey: .members)) ?? nil
            keys = (try? c.decodeIfPresent([String].self, forKey: .keys)) ?? nil
            creator = (try? c.decodeIfPresent(String.self, forKey: .creator)) ?? nil
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
            left = (try? c.decodeIfPresent([String].self, forKey: .left)) ?? nil
        }
    }

    /// A G that passed rule 4 (§11.1): every element its op carries, checked.
    struct Form: Equatable, Sendable {
        let op: Op
        let groupId: String
        let atMs: UInt64
        /// create, accept; "" otherwise.
        let name: String
        /// create, accept: the GROUP_MEMBERS csv verbatim, and its members as the invite's own
        /// parser reads them; "" and [] otherwise.
        let membersCsv: String
        let members: [String]
        /// create, accept: GROUP_MEMBER_KEYS entries verbatim.
        let keys: [String]
        /// accept: the invite's authenticated source.
        let creator: String?
        /// post: the text ("" for an attachment-only post).
        let text: String
        let left: [String]
    }

    /// §11.1 rules 1 to 4, in order; rule 0 (the repeat) is the seen store's, rules 5 and 6
    /// need the group as held here (`step`).
    enum Disposition: Equatable, Sendable {
        /// Rule 1: the unwrapped source is not D. Ignored and logged.
        case notFromDistro
        /// Rule 2: not validated under D's key. Dropped with a log line.
        case forged
        /// Rule 3: `fields[0xFD]` is this device: dropped silently, recorded as seen.
        case ownEcho
        /// Rule 4: dropped with a log line. `sibling` is the 0xFD learned at rule 3.
        case malformed(String, sibling: String?)
        /// Rules 5 and 6 decide (`step`, `leftSteps`).
        case apply(Form, sibling: String?)
    }

    static func disposition(sourceHex: String, distroHex: String?, signatureValidated: Bool,
                            reading: Reading, deviceHex: String) -> Disposition {
        guard let d = DeliveryPolicy.hash(distroHex), sourceHex.lowercased() == d else { return .notFromDistro }
        guard signatureValidated else { return .forged }
        let by = reading.by.lowercased()
        if !deviceHex.isEmpty, by == deviceHex.lowercased() { return .ownEcho }
        let sibling = DeliveryPolicy.hash(by)
        switch form(reading, distroHex: d) {
        case .success(let form): return .apply(form, sibling: sibling)
        case .failure(let why): return .malformed(why.text, sibling: sibling)
        }
    }

    struct Problem: Error, Equatable { let text: String }

    /// Rule 4. The unwrap checks the form (`problem`); this checks it again, so a G is applied
    /// only as the rules say whatever the bridge build.
    static func form(_ r: Reading, distroHex d: String) -> Result<Form, Problem> {
        func fail(_ why: String) -> Result<Form, Problem> { .failure(Problem(text: why)) }
        if let problem = r.problem { return fail(problem) }
        guard let opText = r.op, let op = Op(rawValue: opText) else { return fail("op is \(r.op ?? "absent"), not one of the four") }
        guard let groupId = DeliveryPolicy.hash(r.groupId?.lowercased()) else { return fail("group_id is not 32 hex") }
        guard let atMs = r.atMs, atMs <= 9_007_199_254_740_991 else { return fail("at_ms is not an integer 0 to 2^53 - 1") }
        guard let left = r.left else { return fail("left is absent") }
        if left.count > leftLimit { return fail("left holds \(left.count) ids, more than \(leftLimit)") }
        var leftIds: [String] = []
        for raw in left {
            guard let id = DeliveryPolicy.hash(raw.lowercased()), id == raw.lowercased() else { return fail("left holds an id that is not 32 hex") }
            leftIds.append(id)
        }
        var name = "", csv = "", members: [String] = [], keys: [String] = [], creator: String?, text = ""
        switch op {
        case .create, .accept:
            guard let n = r.name else { return fail("name is absent") }
            guard let m = r.members else { return fail("members is absent") }
            members = DeliveryPolicy.members(LxmfFieldsDecoder.groupCsv(m))
            guard members.contains(d) else { return fail("members does not name D") }
            guard let k = r.keys else { return fail("keys is absent") }
            name = n; csv = m; keys = k
            if op == .accept {
                guard let c = DeliveryPolicy.hash(r.creator?.lowercased()) else { return fail("creator is not 32 hex") }
                if c == d { return fail("creator is D") }
                guard members.contains(c) else { return fail("creator is not listed in members") }
                creator = c
            }
        case .post:
            guard let t = r.text else { return fail("text is absent") }
            text = t
        case .leave:
            break
        }
        return .success(Form(op: op, groupId: groupId, atMs: atMs, name: name, membersCsv: csv,
                             members: members, keys: keys, creator: creator, text: text, left: leftIds))
    }

    // MARK: Apply (§11.2)

    /// Where the group a G names stands here.
    enum Standing: Equatable, Sendable {
        case notHeld
        case pending
        case joined
        /// Declined or left here (a closed id, the conversation removed).
        case closed
    }

    /// What applying a G that passed rules 0 to 4 does to its own group.
    enum Step: Equatable, Sendable {
        /// "Hold the group from G": list, creator, ownMember D, joined, and so on.
        case holdFromSync
        /// The pending invite held here (someone else's version of the group) is discarded
        /// without sending anything, with a log line naming its inviter; then hold from G.
        case discardPendingThenHold
        /// The pending invite matches G: joined as the user's own accept here would make it,
        /// without sending.
        case joinPending
        /// Closed as the local decline or leave closes it (the id recorded closed, the
        /// conversation removed), without sending and without owing a G.
        case close
        /// Not held here: the id is recorded closed, so a later invite, create or accept for it
        /// is ignored.
        case tombstone
        /// Stored as the user's own outgoing post: sender D, SENT, at `atMs`, id = G's hash.
        case storeOwnPost
        /// A `post` G for a group not joined here: held (§6.5), not recorded as seen.
        case holdArrival
        /// Nothing changes; the text says why (for the log).
        case nothing(String)
    }

    /// `ownMemberIsD`: the group held here has D as its own address (rule 5 asks it of a
    /// pending or joined group). `pendingMatches`: a pending invite's recorded creator and
    /// member list equal an `accept` G's.
    static func step(_ op: Op, standing: Standing, ownMemberIsD: Bool, pendingMatches: Bool) -> Step {
        if (standing == .pending || standing == .joined) && !ownMemberIsD {
            return .nothing("the group is held here as this device's own address, not as the distro (rule 5)")
        }
        switch (op, standing) {
        case (.create, .notHeld), (.accept, .notHeld): return .holdFromSync
        case (.create, .pending): return .discardPendingThenHold
        case (.accept, .pending): return pendingMatches ? .joinPending : .discardPendingThenHold
        case (.create, .joined), (.accept, .joined): return .nothing("the group is held here already")
        case (.create, .closed), (.accept, .closed): return .nothing("the group was left here, for good")
        case (.leave, .notHeld): return .tombstone
        case (.leave, .pending), (.leave, .joined): return .close
        case (.leave, .closed): return .nothing("the group was left here already")
        case (.post, .joined): return .storeOwnPost
        case (.post, .notHeld), (.post, .pending): return .holdArrival
        case (.post, .closed): return .nothing("the group was left here")
        }
    }

    /// What `left` does to one id other than G's own (§11.2).
    enum LeftStep: Equatable, Sendable {
        /// Held here with ownMember D: applied as a `leave` G for it.
        case close
        /// Not held here: recorded closed.
        case tombstone
        /// Closed here already: nothing changes, but the id goes in this device's own list.
        case alreadyClosed
        /// Held here with another own address: ignored.
        case ignore
    }

    static func leftStep(standing: Standing, ownMemberIsD: Bool) -> LeftStep {
        switch standing {
        case .closed: return .alreadyClosed
        case .notHeld: return .tombstone
        case .pending, .joined: return ownMemberIsD ? .close : .ignore
        }
    }

    /// The ids of `left` to apply: each once, never G's own group id.
    static func leftIds(_ form: Form) -> [String] {
        var seen = Set<String>()
        return form.left.filter { $0 != form.groupId && seen.insert($0).inserted }
    }

    /// This device's own `left` list for D after `ids` were left (§10.2): most recent first, each
    /// once, at most 32, the oldest forgotten first.
    static func recordLeft(_ ids: [String], into list: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for id in ids + list where seen.insert(id).inserted { out.append(id) }
        return Array(out.prefix(leftLimit))
    }

    // MARK: The writer (§17.2)

    /// The JSON `retichat_message_set_distro_group_sync` takes: the unwrap's `group_sync` object
    /// without `by` and `problem`. Only the keys the op carries are written.
    static func writerJSON(op: Op, groupId: String, atMs: UInt64, name: String? = nil,
                           membersCsv: String? = nil, keys: [String]? = nil, creator: String? = nil,
                           text: String? = nil, left: [String]) -> String {
        var object: [String: Any] = [
            "op": op.rawValue, "group_id": groupId, "at_ms": NSNumber(value: atMs), "left": left,
        ]
        switch op {
        case .create, .accept:
            object["name"] = name ?? ""
            object["members"] = membersCsv ?? ""
            object["keys"] = keys ?? []
            if op == .accept { object["creator"] = creator ?? "" }
        case .post:
            object["text"] = text ?? ""
        case .leave:
            break
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// A G's time: the action's, in milliseconds.
    static func atMs(_ seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(UInt64(seconds * 1000), 9_007_199_254_740_991)
    }
}

// MARK: - Who is "me" in a group (§8.1, §9.1)

nonisolated enum GroupSelf {
    /// X (§9.1): the group's own address when that is a distro (anything but the device), else
    /// the distro this device holds now when the list names it; nil when neither.
    static func distro(ownMember: String?, device: String, listed: [String], heldDistro: String?) -> String? {
        if let own = DeliveryPolicy.hash(ownMember), own != device { return own }
        if let d = DeliveryPolicy.hash(heldDistro), listed.contains(d) { return d }
        return nil
    }

    /// The self addresses of a group: in a group whose list names X, {X, the device, the known
    /// siblings of X}; in any other group, {the device}.
    static func addresses(ownMember: String?, device: String, listed: [String], heldDistro: String?,
                          siblings: (String) -> [String]) -> Set<String> {
        var out: Set<String> = device.isEmpty ? [] : [device]
        guard let x = distro(ownMember: ownMember, device: device, listed: listed, heldDistro: heldDistro),
              listed.contains(x) else { return out }
        out.insert(x)
        out.formUnion(siblings(x))
        return out
    }

    /// Whether `hex` is shown as "You" (§9.1, §9.2). In a group, exactly that group's self
    /// addresses (`groupSelf`, from `addresses`): a sibling listed in a group that names no distro
    /// this device holds or held is a separate member there, and a former D is "You" in the groups
    /// it is the own address of (§8.7). Outside groups (a DM, the new-chat, QR and contact checks),
    /// the device and the distro held now (`heldDistro`), never a sibling.
    static func shownAsYou(_ hex: String, groupSelf: Set<String>?, device: String, heldDistro: String?) -> Bool {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return false }
        if !device.isEmpty, h == device.lowercased() { return true }
        if let groupSelf { return groupSelf.contains(h) }
        if let d = heldDistro?.lowercased(), h == d { return true }
        return false
    }

    /// A D-group: one whose own address is a distro (the current D or a former one). nil (a
    /// group held from before this change) is the device.
    static func isDistroGroup(ownMember: String?, device: String) -> Bool {
        guard let own = DeliveryPolicy.hash(ownMember) else { return false }
        return own != device
    }

    /// The group's own address for an invite admitted after this change (§8.1): D when the list
    /// names the D this device holds now, else the device when listed, else nil (the invite is
    /// not for this user, §9.3).
    static func ownMemberForInvite(listed: [String], device: String, heldDistro: String?) -> String? {
        if let d = DeliveryPolicy.hash(heldDistro), listed.contains(d) { return d }
        if !device.isEmpty, listed.contains(device) { return device }
        return nil
    }

    /// Who signs for a group (`groupSigner`, §8.1), resolved at send time.
    enum Signer: Equatable, Sendable {
        /// The device identity: a group whose own address is the device.
        case device
        /// D, the distro this device holds now, loaded, equal to the group's own address.
        case distro(String)
        /// D is held but not loaded yet (start-up): nothing is offered until it is (§8.7).
        case distroNotLoaded(String)
        /// The group's own address is a distro this device does not hold (§8.7).
        case formerDistro(String)
    }

    /// `loadedDistro`: the `lxmf.delivery` hash of the distro `DistroManager.signing()` gives
    /// now (nil when none is loaded); `distroSettled`: whether the Keychain has said what the
    /// device holds (`DistroManager.isSettled`).
    static func signer(ownMember: String?, device: String, loadedDistro: String?, distroSettled: Bool) -> Signer {
        guard let own = DeliveryPolicy.hash(ownMember), own != device else { return .device }
        if let loaded = DeliveryPolicy.hash(loadedDistro), loaded == own { return .distro(own) }
        if !distroSettled { return .distroNotLoaded(own) }
        return .formerDistro(own)
    }

    /// §8.7's text for a D-group this device cannot sign for.
    static func cannotSignText(_ signer: Signer) -> String? {
        switch signer {
        case .device, .distro: return nil
        case .formerDistro(let d):
            return "This group uses your distro address \(short(d)), which this device no longer holds. You can read it here, but cannot post or change your membership from this device."
        case .distroNotLoaded(let d):
            return "This group uses your distro address \(short(d)), which has not loaded on this device yet. You can read it here, and post or change your membership once it has loaded."
        }
    }

    /// "Delete from this device" (§8.7): the group's own address is a distro this device does
    /// not hold.
    static let deleteLocalTitle = "Delete from this device"
    static let deleteLocalMessage = "This removes the group from this device only. You stay in the group on your other devices and for the other members."

    /// §8.7, "If D is held but not yet loaded (start-up), group actions as D are not offered
    /// until it is": what the new-group form says when a group cannot be created yet. Nothing
    /// is queued or retried. (The design gives no wording for this case.)
    static let createNotReadyText = "Your distro address has not loaded on this device yet. Create the group once it has."

    static func short(_ hex: String) -> String { String(hex.prefix(8)) }
}

// MARK: - §6.3's first three rules

nonisolated enum GroupFirstRules {
    enum Verdict: Equatable, Sendable {
        /// The group rule decides. `ownAct`: the packet source is a known sibling of the user,
        /// an older device acting as its own listed entry (§9.2).
        case pass(ownAct: Bool)
        /// `unverified_reason` 2: dropped, never held, never notified.
        case forged
        /// The packet source is D: the user's own echo, dropped.
        case ownEcho
        /// The author would be a self address (GROUP_SENDER) while the packet source is not one:
        /// dropped.
        case selfSenderFromOther
        /// The packet source is a known sibling (one of the user's own addresses here) and the
        /// signature did not validate (SOURCE_UNKNOWN): only a validly signed message from another
        /// device of D is the user's own (§9.2, SPEC §17.14), and a self address is never another
        /// member, so it is dropped, never stored as sent, never held.
        case selfSourceUnproven
    }

    /// `selfAddresses`: the group's (GroupSelf.addresses); `distros`: the D this device holds
    /// and the group's X; `siblings`: the known siblings among the self addresses.
    static func check(signature: Int, sourceHex: String, groupSender: String?, selfAddresses: Set<String>,
                      distros: Set<String>, siblings: Set<String>) -> Verdict {
        if signature == DeliveryPolicy.Signature.invalid { return .forged }
        if distros.contains(sourceHex) { return .ownEcho }
        let sourceIsSelf = selfAddresses.contains(sourceHex)
        if let named = DeliveryPolicy.hash(groupSender), selfAddresses.contains(named), !sourceIsSelf {
            return .selfSenderFromOther
        }
        let fromSibling = sourceIsSelf && siblings.contains(sourceHex)
        if fromSibling, signature != DeliveryPolicy.Signature.validated { return .selfSourceUnproven }
        return .pass(ownAct: fromSibling)
    }
}

// MARK: - The filtered-invite set (§6.5)

nonisolated enum FilteredInvites {
    static let limit = 64

    /// `ids` with `groupId` added last; the oldest forgotten past the limit.
    static func record(_ ids: [String], _ groupId: String) -> [String] {
        var out = ids.filter { $0 != groupId }
        out.append(groupId)
        if out.count > limit { out.removeFirst(out.count - limit) }
        return out
    }

    static func remove(_ ids: [String], _ groupId: String) -> [String] { ids.filter { $0 != groupId } }

    /// Whether an invite to D the privacy filter dropped records its group id: the set is for
    /// groups the filter decided not to hold. Not for a group held here (pending from an inviter
    /// the filter admitted, or joined): a co-member's own invite for it (§11.2) must not make this
    /// device refuse to hold that group's traffic. Not from an allowlisted inviter, for a closed
    /// group, or for a forged invite.
    static func records(sourceAllowlisted: Bool, closed: Bool, signature: Int, heldHere: Bool) -> Bool {
        !sourceAllowlisted && !closed && signature != DeliveryPolicy.Signature.invalid && !heldHere
    }
}

// MARK: - Known siblings (§9.1)

nonisolated enum KnownSiblings {
    /// `known` (distro → its known siblings) with `by` learned for `distro`: never the device,
    /// never anything that is not an address.
    static func learn(_ known: [String: [String]], by: String?, distro: String?, device: String) -> [String: [String]] {
        guard let by = DeliveryPolicy.hash(by?.lowercased()), let d = DeliveryPolicy.hash(distro),
              by != device, by != d else { return known }
        var out = known
        var list = out[d] ?? []
        if !list.contains(by) { list.append(by) }
        out[d] = list
        return out
    }

    /// The siblings kept when the device holds `heldDistro`: those of a distro given up are
    /// dropped unless a group here still has that distro as its own address (§8.7).
    static func prune(_ known: [String: [String]], heldDistro: String?, ownMembers: Set<String>) -> [String: [String]] {
        known.filter { $0.key == heldDistro || ownMembers.contains($0.key) }
    }
}

// MARK: - Held arrivals (§6.5)

nonisolated enum HeldArrivals {
    static let maxBlobs = 64
    static let maxBytes = 256 * 1024
    static let perGroup = 16
    static let perSource = 8
    static let notHeldMax = 16
    static let maxBlobSize = 64 * 1024

    /// One held blob, as the bounds read it. `seq` is the arrival order.
    struct Item: Equatable, Sendable {
        let seq: Int
        let groupId: String
        let source: String
        let hash: String
        /// The LXMF signature when the unwrap gives it (an accept's or leave's `packed`), else
        /// nil: then the hash and `validated` stand for it (§6.5's pair).
        let signature: Data?
        let validated: Bool
        let size: Int
        /// False for a `post` G (source D): it counts only against its group.
        let countsAgainstSource: Bool
    }

    enum Decision: Equatable, Sendable {
        /// The same message (hash and signature) is held already.
        case duplicate
        /// Held, after evicting these (by `seq`), each with the bound that evicted it.
        case hold(evict: [Eviction])
        /// Not held; the text names the bound.
        case refuse(String)
    }

    struct Eviction: Equatable, Sendable {
        let seq: Int
        let bound: String
    }

    /// Whether `new` is held, and what it evicts. `pending(groupId)`: the group is held pending
    /// here (otherwise it is not held here). A blob for a group not held may evict only blobs
    /// of groups not held; a pending group's may evict any. A later copy whose signature
    /// validates replaces an unverified one with the same hash.
    static func decide(_ new: Item, existing: [Item], pending: (String) -> Bool) -> Decision {
        if new.size > maxBlobSize { return .refuse("a blob over \(maxBlobSize / 1024) KiB is never held") }
        var items = existing
        var evicted: [Eviction] = []
        for e in existing where e.hash == new.hash {
            if same(e, new) { return .duplicate }
            if !e.validated && new.validated {
                items.removeAll { $0.seq == e.seq }
                evicted.append(Eviction(seq: e.seq, bound: "replaced by a copy whose signature validates"))
            }
        }
        let newPending = pending(new.groupId)
        func evictable(_ i: Item) -> Bool { newPending || !pending(i.groupId) }
        while true {
            let bound: (name: String, within: [Item])?
            let sameGroup = items.filter { $0.groupId == new.groupId }
            let sameSource = items.filter { $0.countsAgainstSource && $0.source == new.source }
            let notHeld = items.filter { !pending($0.groupId) }
            if sameGroup.count >= perGroup {
                bound = ("\(perGroup) per group", sameGroup)
            } else if new.countsAgainstSource, sameSource.count >= perSource {
                bound = ("\(perSource) per source", sameSource)
            } else if !newPending, notHeld.count >= notHeldMax {
                bound = ("\(notHeldMax) for groups not held here", notHeld)
            } else if items.count >= maxBlobs {
                bound = ("\(maxBlobs) in all", items)
            } else if items.reduce(0, { $0 + $1.size }) + new.size > maxBytes {
                bound = ("\(maxBytes / 1024) KiB in all", items)
            } else {
                bound = nil
            }
            guard let bound else { return .hold(evict: evicted) }
            let candidates = bound.within.filter(evictable)
            guard let victim = oldestOfLargestSource(candidates) else {
                return .refuse("the bound of \(bound.name) is full, and nothing in it may be evicted for it")
            }
            items.removeAll { $0.seq == victim.seq }
            evicted.append(Eviction(seq: victim.seq, bound: bound.name))
        }
    }

    private static func same(_ a: Item, _ b: Item) -> Bool {
        if let sa = a.signature, let sb = b.signature { return sa == sb }
        // Without the signature bytes, a copy that validated is the signed message: its hash
        // names it (an Ed25519 signature over one message is one value). Two unverified copies
        // with one hash are taken as the same.
        return a.validated == b.validated
    }

    /// The oldest blob of the source holding the most of `items` (ties: the source whose oldest
    /// blob is oldest).
    static func oldestOfLargestSource(_ items: [Item]) -> Item? {
        let bySource = Dictionary(grouping: items, by: \.source)
        let best = bySource.values.max { a, b in
            if a.count != b.count { return a.count < b.count }
            return (a.map(\.seq).min() ?? 0) > (b.map(\.seq).min() ?? 0)
        }
        return best?.min { $0.seq < $1.seq }
    }

    /// Whether a group message the rules would drop is held instead (§6.5): only when the group
    /// not being joined here is the sole reason. `keptIfJoined`: the group rule, asked as if the
    /// group were joined here (pending: the list is known); unused for a group not held, where
    /// only a proven message is held.
    static func holdable(isPostSync: Bool, action: String?, held: DeliveryPolicy.Held, closed: Bool,
                         filtered: Bool, signature: Int, sourceIsSelf: Bool, keptIfJoined: Bool) -> Bool {
        if closed || filtered || held == .joined { return false }
        if isPostSync { return true }
        if action == GroupAction.invite || action == GroupAction.relayRequest { return false }
        if signature == DeliveryPolicy.Signature.invalid || sourceIsSelf { return false }
        if held == .none { return signature == DeliveryPolicy.Signature.validated }
        return keptIfJoined
    }
}

// MARK: - What the distro path hands the app

/// A group sync G as RfedDistroClient read it (§11.1 rule 0 already checked): judged on the
/// main actor by ChatRepository.handleDistroGroupSync.
nonisolated struct DistroGroupSyncArrival: Sendable {
    /// The fan-out blob as received: what is held, and fed to the distro path again, when a
    /// `post` G waits for its group to be joined here (§6.5).
    let blob: Data
    /// Its LXMF hash, 64 lowercase hex.
    let hash: String
    let sourceHex: String
    /// D's `lxmf.delivery` hash, read with the handle that unwrapped it.
    let distroHex: String
    /// The unwrap's verdict, under D's key for a message from D (rule 2).
    let signatureValidated: Bool
    let reading: DistroGroupSync.Reading
}

/// A group message to the distro (§6.1 step 2) as RfedDistroClient read it: admitted, handed
/// to the group handler or held by ChatRepository.handleDistroGroupArrival.
nonisolated struct DistroGroupArrival: Sendable {
    let blob: Data
    /// Its LXMF hash, 64 lowercase hex: the group handler's message id (§6.2).
    let hash: String
    let sourceHex: String
    /// GROUP_ID, 32 lowercase hex.
    let groupId: String
    let title: String
    let content: String
    let timestamp: Double
    let fieldsRaw: Data?
    let displayName: DisplayNames.NameField
    /// 0 validated, 1 source unknown, 2 invalid: the receipt's verdict (§7).
    let unverifiedReason: Int
    let signatureValidated: Bool
    /// The receipt's key for an accept or leave, when it binds to the source.
    let senderKey: Data?
    /// The receipt's packed accept or leave (`dest | src | sig | payload`), for the creator's
    /// kept copy (§12.2).
    let packed: Data?
}
