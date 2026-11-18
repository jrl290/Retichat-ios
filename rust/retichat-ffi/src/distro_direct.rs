//! Offline use of a distro address (RFed-rust SPEC.md §17.15, James
//! 2026-11-17): the pure parts, and the state the C wrappers in `lib.rs`
//! keep, apart from the FFI so `cargo test` runs them. The same code as
//! Retichat-android's `rust/retichat-jni/src/distro_direct.rs`.
//!
//! A distro device that cannot reach RFed, and has no internet connection,
//! holds an **offline address** of its own under RFed's name, made with the
//! distro's key: `rfed.distro.direct.<random>`, with ratchets. Senders that
//! know it send it the same sealed message they give RFed, as one packet or
//! one `/distro/direct` request: `msgpack [ bin sealed, bin stamp ]`. It also
//! holds `rfed.distro.direct`, the **lookup address**, which accepts no links
//! and is never announced: Reticulum answers a path request for it with the
//! offline addresses the device knows. The app (Retichat-ios
//! `Services/DistroOffline.swift`) decides when the device is offline, what it
//! announces and when, what a sender keeps, and which messages it sends where;
//! this module does what the app cannot:
//!
//! * the wire forms of §17.15 (the announce and lookup `app_data`, a copy and
//!   the answer to a request), and the two addresses' hashes;
//! * [`direct_copy`]: a sender's copy, from the message it sends through
//!   propagation, so every copy and RFed's are one sealed message with one
//!   stamp ([`direct_copy`] says how);
//! * [`hold`], [`take`]: the device's two addresses (app-links' held
//!   addresses), and each copy checked before the app is asked to keep it: the
//!   stamp against the device's own RFed node's cost, and the distro;
//! * [`sign_sealed`]: the §17.13 Distro Sync proof of a message received
//!   direct, which the device uploads to RFed as it owes a §17.11 Distro Sync
//!   of a send;
//! * [`hook_announces`]: offline addresses and lookup answers heard, handed to
//!   the app once the address checks out against the announced identity;
//! * [`send`], [`ask`]: a sender's copy to one offline address, and its path
//!   requests over the mesh connections it names.
//!
//! Nothing here sends on a timer or sends again (DESIGN_PRINCIPLES §3): a
//! send's outcome is told once, and the app decides what follows.

use std::sync::{Arc, Mutex, Once};

use app_links::{AppLinks, HeldAddress, HeldPacketHandler, HeldRequestHandler, SINGLE_PACKET_MAX};
use lxmf_rust::distro::{delivery_hash, sync_signed_bytes, sync_transient_id};
use lxmf_rust::lx_message::LXMessage;
use lxmf_rust::lx_stamper::{validate_pn_stamp, STAMP_SIZE};
use reticulum_rust::destination::Destination;
use reticulum_rust::identity::{self, Identity};
use reticulum_rust::transport::{AnnounceHandler, Transport};
use rmpv::Value;

/// Both addresses are under RFed's name.
pub const APP_NAME: &str = "rfed";

/// The request a copy goes as when it does not fit in one packet.
pub const DIRECT_PATH: &str = "/distro/direct";

/// What the device's answer to a copy says, as bits: it holds the message
/// afterwards, newly or already.
pub const HELD: u8 = 1;

/// ... and it is back: it reaches RFed again, or its offline toggle is off.
pub const BACK: u8 = 2;

const DEST_LEN: usize = 16;

/// The offline address's aspects.
pub fn offline_aspects(random: &str) -> Vec<String> {
    vec!["distro".to_string(), "direct".to_string(), random.to_string()]
}

/// The lookup address's aspects.
pub fn lookup_aspects() -> Vec<String> {
    vec!["distro".to_string(), "direct".to_string()]
}

/// `<random>`: 16 lowercase hex characters, from 8 random bytes.
pub fn valid_random(random: &str) -> bool {
    random.len() == 16 && random.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// `rfed.distro.direct.<random>` of the identity whose hash is `identity_hash`.
pub fn offline_hash(identity_hash: &[u8], random: &str) -> Vec<u8> {
    Destination::hash(Some(identity_hash), APP_NAME, &["distro", "direct", random])
}

/// `rfed.distro.direct` of the identity whose hash is `identity_hash`.
pub fn lookup_hash(identity_hash: &[u8]) -> Vec<u8> {
    Destination::hash(Some(identity_hash), APP_NAME, &["distro", "direct"])
}

/// The distro's own `lxmf.delivery`, which the app knows a distro by.
fn distro_of(identity_hash: &[u8]) -> Vec<u8> {
    Destination::hash(Some(identity_hash), "lxmf", &["delivery"])
}

fn encode(value: Value) -> Vec<u8> {
    let mut out = Vec::new();
    // Writing to a Vec cannot fail.
    let _ = rmpv::encode::write_value(&mut out, &value);
    out
}

fn decode(data: &[u8]) -> Option<Value> {
    let mut slice = data;
    let value = rmpv::decode::read_value(&mut slice).ok()?;
    // One value and nothing after it.
    slice.is_empty().then_some(value)
}

/// An offline address's announce `app_data`: `msgpack [ str random, bool back ]`.
pub fn offline_app_data(random: &str, back: bool) -> Vec<u8> {
    encode(Value::Array(vec![Value::String(random.into()), Value::Boolean(back)]))
}

/// The `random` and `back` of an offline address's `app_data`; `None` for
/// anything else.
pub fn parse_offline_app_data(app_data: &[u8]) -> Option<(String, bool)> {
    let Value::Array(items) = decode(app_data)? else { return None };
    match items.as_slice() {
        [Value::String(random), Value::Boolean(back)] => {
            let random = random.as_str()?;
            valid_random(random).then(|| (random.to_string(), *back))
        }
        _ => None,
    }
}

/// The lookup address's `app_data`: `msgpack [ str random, ... ]`, the device's
/// own first; `msgpack []` once it is back.
pub fn lookup_app_data(randoms: &[String]) -> Vec<u8> {
    encode(Value::Array(randoms.iter().map(|r| Value::String(r.as_str().into())).collect()))
}

/// The offline addresses a lookup answer names; `None` when it is not an
/// array of strings. A string that is no `<random>` is left out.
pub fn parse_lookup_app_data(app_data: &[u8]) -> Option<Vec<String>> {
    let Value::Array(items) = decode(app_data)? else { return None };
    let mut randoms = Vec::with_capacity(items.len());
    for item in &items {
        let Value::String(s) = item else { return None };
        let s = s.as_str()?;
        if valid_random(s) {
            randoms.push(s.to_string());
        }
    }
    Some(randoms)
}

/// A copy: `msgpack [ bin sealed, bin stamp ]`.
pub fn encode_copy(sealed: &[u8], stamp: &[u8]) -> Vec<u8> {
    encode(Value::Array(vec![Value::Binary(sealed.to_vec()), Value::Binary(stamp.to_vec())]))
}

/// The `sealed` and `stamp` of a copy; `None` when it is not one.
pub fn decode_copy(data: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let Value::Array(items) = decode(data)? else { return None };
    match items.as_slice() {
        [Value::Binary(sealed), Value::Binary(stamp)] => Some((sealed.clone(), stamp.clone())),
        _ => None,
    }
}

/// The device's answer to a request: `msgpack [ bool held, bool back ]`.
pub fn encode_answer(held: bool, back: bool) -> Vec<u8> {
    encode(Value::Array(vec![Value::Boolean(held), Value::Boolean(back)]))
}

/// `held` and `back` of an answer; `None` when it is not one.
pub fn decode_answer(data: &[u8]) -> Option<(bool, bool)> {
    let Value::Array(items) = decode(data)? else { return None };
    match items.as_slice() {
        [Value::Boolean(held), Value::Boolean(back)] => Some((*held, *back)),
        _ => None,
    }
}

/// An answer's bits ([`HELD`], [`BACK`]); 0 for anything that is not one.
pub fn answer_bits(answer: &[u8]) -> u8 {
    match decode_answer(answer) {
        Some((held, back)) => (if held { HELD } else { 0 }) | (if back { BACK } else { 0 }),
        None => 0,
    }
}

/// The `lxmf_data` (with its stamp) of a message's propagated form,
/// `msgpack [ f64 timebase, [ bin lxmf_data ] ]`.
fn propagated_lxmf_data(propagation_packed: &[u8]) -> Result<Vec<u8>, String> {
    let value = decode(propagation_packed).ok_or("the propagated form is not one msgpack value")?;
    let Value::Array(items) = value else { return Err("the propagated form is not an array".into()) };
    let Some(Value::Array(messages)) = items.get(1) else {
        return Err("the propagated form carries no message list".into());
    };
    match messages.as_slice() {
        [Value::Binary(lxmf_data)] => Ok(lxmf_data.clone()),
        _ => Err("the propagated form does not carry exactly one message".into()),
    }
}

/// A sender's copy of `msg`, a message to a distro that the router has taken
/// through propagation (LXMF `LXMRouter.handle_outbound` packed it, so its
/// `transient_id` is set): `msgpack [ bin sealed, bin stamp ]`, where `sealed`
/// is the `lxmf_data` LXMF built for propagation without its stamp and
/// `stamp` the propagation stamp (§17.15 "On the sender").
///
/// The router makes that stamp later, in its own loop, for the node's cost
/// (`LXMRouter`'s deferred stamps). When it has not made it yet, it is made
/// here, at `cost`, the node's announced cost the router would use, and put in
/// the message's propagated form, as the router puts in one it makes: the
/// router then finds the stamp made and sends the message as it is. So the
/// copies and the message RFed gets are one sealed message with one stamp, and
/// their `transient_id` is the same (§17.15: "one stamp serves them all"). The
/// encryption is never made again (`LXMessage` keeps `pn_encrypted_data`).
/// `cost` `None` with no stamp yet is an error, and so is a message not sent
/// through propagation. Blocks while the stamp is mined, holding the
/// message's lock as the router's own mining does.
pub fn direct_copy(msg: &mut LXMessage, cost: Option<u32>) -> Result<Vec<u8>, String> {
    if msg.desired_method != Some(LXMessage::PROPAGATED) {
        return Err("only a message sent through propagation has a sealed form".into());
    }
    if msg.packed.is_none() || msg.transient_id.is_none() {
        return Err("the message has not been packed for propagation yet".into());
    }
    if msg.propagation_stamp.is_none() {
        let cost = cost.ok_or("the propagation node's stamp cost is not known")?;
        if msg.get_propagation_stamp(cost)?.is_none() {
            return Err(format!("the propagation stamp (cost {cost}) could not be generated"));
        }
        msg.propagation_packed = None;
        msg.make_propagation_packed()?;
    }
    let stamp = msg.propagation_stamp.clone().ok_or("the message has no propagation stamp")?;
    let propagated = msg.propagation_packed.as_ref().ok_or("the message has no propagated form")?;
    let lxmf_data = propagated_lxmf_data(propagated)?;
    if lxmf_data.len() <= DEST_LEN + stamp.len() || !lxmf_data.ends_with(&stamp) {
        return Err("the propagated form does not end with the message's stamp".into());
    }
    let sealed = &lxmf_data[..lxmf_data.len() - stamp.len()];
    if msg.transient_id.as_deref() != Some(identity::full_hash(sealed).as_slice()) {
        return Err("the sealed bytes are not the message's transient id".into());
    }
    Ok(encode_copy(sealed, &stamp))
}

/// Check a copy as RFed checks an upload (§17.15 "Taking a message"):
/// `sealed` is for the distro whose `lxmf.delivery` is `distro`, and `stamp` is
/// a propagation stamp over `full_hash(sealed)` of at least `cost`. The message
/// itself is opened by the app, with `lxmf_rust::distro::unwrap_blob`.
pub fn check_copy(sealed: &[u8], stamp: &[u8], distro: &[u8], cost: u32) -> Result<(), String> {
    if sealed.len() <= DEST_LEN || sealed[..DEST_LEN] != *distro {
        return Err("it is not addressed to this distro".into());
    }
    if stamp.len() != STAMP_SIZE {
        return Err(format!("its stamp is {} bytes, not {STAMP_SIZE}", stamp.len()));
    }
    let mut data = Vec::with_capacity(sealed.len() + stamp.len());
    data.extend_from_slice(sealed);
    data.extend_from_slice(stamp);
    if validate_pn_stamp(&data, cost).is_none() {
        return Err(format!("its stamp is below the RFed node's cost of {cost}"));
    }
    Ok(())
}

/// The §17.13 Distro Sync proof of `sealed`, a message to `distro` received
/// direct: D's signature over `sync_signed_bytes(D_hash, SHA-256(sealed))`,
/// made once, when the device takes the message, and kept with what it owes
/// (as `lxmf_rust::distro::seal_for_sync` makes it for a message D sends).
pub fn sign_sealed(distro: &Identity, sealed: &[u8]) -> Result<Vec<u8>, String> {
    if distro.get_private_key().is_err() {
        return Err("the distro identity has no private key: a sync proof needs its signature".into());
    }
    let d_hash: [u8; DEST_LEN] = delivery_hash(distro)?
        .try_into()
        .map_err(|_| "the distro's lxmf.delivery hash is not 16 bytes".to_string())?;
    if sealed.len() <= DEST_LEN || sealed[..DEST_LEN] != d_hash {
        return Err("the sealed message is not addressed to the distro".into());
    }
    let signed = sync_signed_bytes(&d_hash, &sync_transient_id(sealed));
    let sig = distro.sign(&signed);
    if !distro.validate(&sig, &signed) {
        return Err("the sync signature does not validate with the distro's own key".into());
    }
    Ok(sig)
}

// ---------------------------------------------------------------------------
// What the app is told
// ---------------------------------------------------------------------------

/// A copy taken at an offline address of the distro (its `lxmf.delivery`),
/// checked: the app keeps it, or not, and answers [`HELD`] and [`BACK`] bits.
pub type OnDirect = Arc<dyn Fn(&[u8], &[u8], &[u8]) -> u8 + Send + Sync>;

/// An offline address of the distro announced, or answered for: its random
/// part, and whether it says the device is back.
pub type OnOfflineAddress = Arc<dyn Fn(&[u8], &str, bool) + Send + Sync>;

/// The distro's lookup address answered for: the offline addresses it names.
pub type OnLookup = Arc<dyn Fn(&[u8], &[String]) + Send + Sync>;

#[derive(Clone)]
pub struct Sink {
    pub on_direct: OnDirect,
    pub on_offline_address: OnOfflineAddress,
    pub on_lookup: OnLookup,
}

static SINK: Mutex<Option<Sink>> = Mutex::new(None);

/// Tell `sink` from now on, in place of any earlier one.
pub fn set_sink(sink: Sink) {
    if let Ok(mut slot) = SINK.lock() {
        *slot = Some(sink);
    }
}

/// Tell no one (the stack is stopping).
pub fn clear_sink() {
    if let Ok(mut slot) = SINK.lock() {
        *slot = None;
    }
}

/// The sink, cloned out of its lock: what it does (a call into the app) never holds it.
fn sink() -> Option<Sink> {
    SINK.lock().ok().and_then(|slot| slot.clone())
}

fn say(message: String, level: i32) {
    reticulum_rust::log(format!("[distro-direct] {message}"), level, false, false);
}

// ---------------------------------------------------------------------------
// The device: its two addresses
// ---------------------------------------------------------------------------

/// One pair of addresses held, until the app restarts (Reticulum keeps them).
struct Held {
    /// The distro's `lxmf.delivery`.
    distro: Vec<u8>,
    random: String,
    offline: Vec<u8>,
    lookup: Vec<u8>,
    /// The RFed node's own `lxmf.propagation`, whose cost a copy's stamp meets.
    node: Vec<u8>,
    /// Whether the device is back: what a refused request's answer says.
    back: bool,
}

static HELD_PAIRS: Mutex<Vec<Held>> = Mutex::new(Vec::new());

/// Hold the offline address `rfed.distro.direct.<random>` of `distro` (D's
/// identity, its private key with it), with its ratchets kept at
/// `ratchets_path`, and the lookup address `rfed.distro.direct`, which accepts
/// no links. Their `app_data` is `[random, back]` and `lookup` (the offline
/// addresses the lookup names). A copy's stamp is checked against the cost of
/// `node`, the RFed node's own `lxmf.propagation`. Returns the offline
/// address's hash.
///
/// Held already in this run: the node and both `app_data` are set again, and
/// nothing else changes; app-links holds each address once.
pub fn hold(
    distro: &Identity,
    random: &str,
    ratchets_path: &str,
    node: &[u8],
    back: bool,
    lookup: &[String],
) -> Result<Vec<u8>, String> {
    if !valid_random(random) {
        return Err(format!("{random:?} is not 16 lowercase hex characters"));
    }
    if distro.get_private_key().is_err() {
        return Err("the distro identity has no private key: its addresses cannot be held".into());
    }
    let identity_hash = distro.hash.clone().ok_or("the distro identity has no hash")?;
    let distro_hash = delivery_hash(distro)?;
    let offline = offline_hash(&identity_hash, random);
    let lookup_dest = lookup_hash(&identity_hash);

    let already = {
        let mut pairs = HELD_PAIRS.lock().map_err(|_| "held pairs: lock poisoned".to_string())?;
        match pairs.iter_mut().find(|h| h.offline == offline) {
            Some(held) => {
                held.node = node.to_vec();
                true
            }
            None => {
                // Kept before the address is held: a copy that comes the moment
                // it is held finds what it is checked against.
                pairs.push(Held {
                    distro: distro_hash,
                    random: random.to_string(),
                    offline: offline.clone(),
                    lookup: lookup_dest.clone(),
                    node: node.to_vec(),
                    back,
                });
                false
            }
        }
    };

    if !AppLinks::holds_address(&offline) {
        let on_packet_offline = offline.clone();
        let on_packet: HeldPacketHandler = Arc::new(move |plaintext: &[u8]| take(&on_packet_offline, plaintext) & HELD != 0);
        let on_request_offline = offline.clone();
        let on_request: HeldRequestHandler = Arc::new(move |data: &[u8]| {
            let bits = take(&on_request_offline, data);
            encode_answer(bits & HELD != 0, bits & BACK != 0)
        });
        if let Err(e) = AppLinks::hold_address(HeldAddress {
            identity: distro.clone(),
            app_name: APP_NAME.to_string(),
            aspects: offline_aspects(random),
            ratchets_path: Some(ratchets_path.to_string()),
            accepts_links: true,
            default_app_data: Some(offline_app_data(random, back)),
            on_packet: Some(on_packet),
            requests: vec![(DIRECT_PATH.to_string(), on_request)],
        }) {
            if !already {
                if let Ok(mut pairs) = HELD_PAIRS.lock() {
                    pairs.retain(|h| h.offline != offline);
                }
            }
            return Err(format!("the offline address could not be held: {e}"));
        }
    }
    if !AppLinks::holds_address(&lookup_dest) {
        AppLinks::hold_address(HeldAddress {
            identity: distro.clone(),
            app_name: APP_NAME.to_string(),
            aspects: lookup_aspects(),
            ratchets_path: None,
            accepts_links: false,
            default_app_data: Some(lookup_app_data(lookup)),
            on_packet: None,
            requests: Vec::new(),
        })
        .map_err(|e| format!("the lookup address could not be held: {e}"))?;
    }
    set_app_data(&offline, back, lookup)?;
    Ok(offline)
}

/// Set both addresses' `app_data` (§17.15): the offline address's
/// `[random, back]`, which Reticulum's answers to path requests carry and the
/// next announce carries, and the lookup's `lookup`.
pub fn set_app_data(offline: &[u8], back: bool, lookup: &[String]) -> Result<(), String> {
    let (random, lookup_dest) = {
        let mut pairs = HELD_PAIRS.lock().map_err(|_| "held pairs: lock poisoned".to_string())?;
        let held = pairs
            .iter_mut()
            .find(|h| h.offline == offline)
            .ok_or("that offline address is not held")?;
        held.back = back;
        (held.random.clone(), held.lookup.clone())
    };
    AppLinks::set_held_app_data(offline, Some(offline_app_data(&random, back)))?;
    AppLinks::set_held_app_data(&lookup_dest, Some(lookup_app_data(lookup)))
}

/// Announce the offline address on each of `interfaces` that is up, with its
/// `app_data` as set, and, while the device is offline (not back), the lookup
/// address with it (§17.15, 2026-11-18): relays then keep the lookup's answer
/// and give it to a sender that asks, even while they hold back searches for
/// unknown addresses, and a sender that watches the lookup hears it. Once the
/// device is back the lookup answers `[]` and is not announced. How many
/// announces of the offline address went; the lookup's are said in the log.
pub fn announce(offline: &[u8], interfaces: &[String]) -> Result<usize, String> {
    let count = AppLinks::announce_held(offline, None, interfaces)?;
    let lookup = HELD_PAIRS
        .lock()
        .ok()
        .and_then(|pairs| pairs.iter().find(|h| h.offline == offline && !h.back).map(|h| h.lookup.clone()));
    if let Some(lookup) = lookup {
        match AppLinks::announce_held(&lookup, None, interfaces) {
            Ok(sent) => say(
                format!("the lookup address {} announced on {sent} mesh connection(s)", reticulum_rust::hexrep(&lookup, false)),
                reticulum_rust::LOG_NOTICE,
            ),
            Err(e) => say(format!("the lookup address was not announced: {e}"), reticulum_rust::LOG_ERROR),
        }
    }
    Ok(count)
}

/// A copy that came to the offline address `offline`, as one packet or as a
/// request: checked here ([`check_copy`], against the cost the RFed node
/// announced), then handed to the app, which opens it, keeps it or not, and
/// answers. Returns [`HELD`] and [`BACK`] bits; a copy refused here is said in
/// the log, never silently.
pub fn take(offline: &[u8], data: &[u8]) -> u8 {
    let found = HELD_PAIRS.lock().ok().and_then(|pairs| {
        pairs
            .iter()
            .find(|h| h.offline == offline)
            .map(|h| (h.distro.clone(), h.node.clone(), h.back))
    });
    let Some((distro, node, back)) = found else { return 0 };
    let back_bit = if back { BACK } else { 0 };
    let refuse = |why: String| {
        say(
            format!(
                "a message at the offline address {} was refused: {why}",
                reticulum_rust::hexrep(offline, false)
            ),
            reticulum_rust::LOG_NOTICE,
        );
        back_bit
    };
    let Some((sealed, stamp)) = decode_copy(data) else {
        return refuse("it is not msgpack [bin sealed, bin stamp]".into());
    };
    let cost = match crate::distro_outbox::node_stamp_cost(Identity::recall_app_data(&node).as_deref()) {
        Ok(cost) => cost,
        Err(e) => return refuse(format!("its stamp cannot be checked: {e}")),
    };
    if let Err(why) = check_copy(&sealed, &stamp, &distro, cost) {
        return refuse(why);
    }
    let Some(sink) = sink() else {
        return refuse("the stack is stopping".into());
    };
    (sink.on_direct)(&distro, &sealed, &stamp)
}

// ---------------------------------------------------------------------------
// Announces heard
// ---------------------------------------------------------------------------

/// Hear every announce, and answers to path requests, once per process
/// (Transport keeps its handlers for the process and has no way to remove one
/// without an aspect filter, which an offline address cannot have: its name
/// ends in a random part). What it tells goes to the sink set now.
pub fn hook_announces() {
    static HOOKED: Once = Once::new();
    HOOKED.call_once(|| {
        Transport::register_announce_handler(AnnounceHandler {
            aspect_filter: None,
            receive_path_responses: true,
            callback: Arc::new(
                |dest: &[u8], identity: &Identity, app_data: &[u8], _packet_hash: Option<Vec<u8>>, _path_response: bool| {
                    heard(dest, identity, app_data)
                },
            ),
        });
    });
}

/// An announce of `dest` by `identity`: told to the sink when it is an offline
/// address or a lookup answer of that identity's distro, and nothing else. An
/// announce carries only a hash of its name, so the address is rebuilt from the
/// random part and the identity and compared (§17.15).
fn heard(dest: &[u8], identity: &Identity, app_data: &[u8]) {
    // Both forms are a short msgpack array (fixarray); most announces are not.
    if !matches!(app_data.first(), Some(0x90..=0x9f)) {
        return;
    }
    let Some(identity_hash) = identity.hash.as_deref() else { return };
    if let Some((random, back)) = parse_offline_app_data(app_data) {
        if offline_hash(identity_hash, &random) == dest {
            if let Some(sink) = sink() {
                (sink.on_offline_address)(&distro_of(identity_hash), &random, back);
            }
        }
        return;
    }
    if let Some(randoms) = parse_lookup_app_data(app_data) {
        if lookup_hash(identity_hash) == dest {
            if let Some(sink) = sink() {
                (sink.on_lookup)(&distro_of(identity_hash), &randoms);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The sender
// ---------------------------------------------------------------------------

/// Send `copy` to the offline address `random` of the distro whose
/// `lxmf.delivery` is `distro` (§17.15 "On the sender"): one packet with a
/// delivery proof asked for when it fits (RNS encrypts it to the address's
/// latest ratchet), otherwise one `/distro/direct` request on a link of its
/// own. `outcome` is told once: [`HELD`] for a proof, the answer's bits for a
/// request, 0 for a failure (no proof, the link did not come up or closed, the
/// request failed). `Ok(false)` when no path to the address is known: nothing
/// was sent, and the caller asks for one.
pub fn send(distro: &[u8], random: &str, copy: Vec<u8>, outcome: Arc<dyn Fn(u8) + Send + Sync>) -> Result<bool, String> {
    if !valid_random(random) {
        return Err(format!("{random:?} is not 16 lowercase hex characters"));
    }
    let identity = Identity::recall(distro).ok_or("the distro's identity is not known: its announce has not been heard")?;
    let identity_hash = identity.hash.clone().ok_or("the distro's identity has no hash")?;
    if !Transport::has_path(&offline_hash(&identity_hash, random)) {
        return Ok(false);
    }
    let aspects = offline_aspects(random);
    if copy.len() <= SINGLE_PACKET_MAX {
        let (proved, failed) = (outcome.clone(), outcome);
        AppLinks::send_packet_to(
            &identity,
            APP_NAME,
            &aspects,
            &copy,
            Arc::new(move || proved(HELD)),
            Arc::new(move || failed(0)),
        )?;
    } else {
        let (answered, failed) = (outcome.clone(), outcome);
        AppLinks::request_once(
            &identity,
            APP_NAME,
            &aspects,
            DIRECT_PATH,
            copy,
            Arc::new(move |answer: Vec<u8>| answered(answer_bits(&answer))),
            Arc::new(move || failed(0)),
        )?;
    }
    Ok(true)
}

/// The addresses a sender watches for the distro whose identity hash is
/// `identity_hash`: its lookup address first, then the offline address of each
/// valid random part in `randoms`.
fn watched_hashes(identity_hash: &[u8], randoms: &[String]) -> Vec<Vec<u8>> {
    let mut hashes = vec![lookup_hash(identity_hash)];
    hashes.extend(randoms.iter().filter(|r| valid_random(r)).map(|r| offline_hash(identity_hash, r)));
    hashes
}

/// Watch for the announces of the lookup address of the distro whose
/// `lxmf.delivery` is `distro`, and of each of its offline addresses `randoms`
/// that this sender keeps (§17.15 "On the sender", 2026-11-18). The apps drop
/// announces they have not asked for (Transport `drop_announces`); watched
/// addresses pass that drop (Transport `watch_announce`), so a sender hears a
/// device of the distro go offline when it announces, not only when it next
/// asks. Watching is kept for the process and is the same however often it is
/// asked for. How many addresses are watched.
pub fn watch(distro: &[u8], randoms: &[String]) -> Result<usize, String> {
    let identity = Identity::recall(distro).ok_or("the distro's identity is not known: its announce has not been heard")?;
    let identity_hash = identity.hash.clone().ok_or("the distro's identity has no hash")?;
    let hashes = watched_hashes(&identity_hash, randoms);
    for hash in &hashes {
        Transport::watch_announce(hash.clone());
    }
    Ok(hashes.len())
}

/// Ask, over each of `interfaces` (the sender's mesh connections), for a path
/// to each offline address `randoms` of the distro whose `lxmf.delivery` is
/// `distro`, and, `with_lookup`, to its lookup address (§17.15). A relay that
/// has kept an answer replies from it; a device that holds the address replies
/// itself. How many requests went.
pub fn ask(distro: &[u8], randoms: &[String], with_lookup: bool, interfaces: &[String]) -> Result<usize, String> {
    let identity = Identity::recall(distro).ok_or("the distro's identity is not known: its announce has not been heard")?;
    let identity_hash = identity.hash.clone().ok_or("the distro's identity has no hash")?;
    let mut hashes: Vec<Vec<u8>> = randoms
        .iter()
        .filter(|r| valid_random(r))
        .map(|r| offline_hash(&identity_hash, r))
        .collect();
    if with_lookup {
        hashes.push(lookup_hash(&identity_hash));
    }
    let mut asked = 0;
    for hash in &hashes {
        for interface in interfaces {
            Transport::request_path(hash, None, Some(interface.clone()), None, None);
            asked += 1;
        }
    }
    Ok(asked)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lxmf_rust::distro::{verify_sync_claim, SyncClaim};
    use lxmf_rust::lx_stamper::{generate_stamp, WORKBLOCK_EXPAND_ROUNDS_PN};

    const RANDOM: &str = "0123456789abcdef";

    #[test]
    fn a_random_part_is_sixteen_lowercase_hex_characters() {
        assert!(valid_random(RANDOM));
        assert!(!valid_random("0123456789ABCDEF"));
        assert!(!valid_random("0123456789abcde"));
        assert!(!valid_random("0123456789abcdefa"));
        assert!(!valid_random("0123456789abcdeg"));
    }

    #[test]
    fn the_announce_app_data_is_random_and_back_and_nothing_else_reads_as_it() {
        let data = offline_app_data(RANDOM, false);
        // msgpack [ fixstr(16) random, false ]
        let mut expected = vec![0x92, 0xb0];
        expected.extend_from_slice(RANDOM.as_bytes());
        expected.push(0xc2);
        assert_eq!(data, expected);
        assert_eq!(parse_offline_app_data(&data), Some((RANDOM.to_string(), false)));
        assert_eq!(parse_offline_app_data(&offline_app_data(RANDOM, true)), Some((RANDOM.to_string(), true)));
        // A lookup answer, LXMF's own app_data and junk are not one.
        assert_eq!(parse_offline_app_data(&lookup_app_data(&[RANDOM.to_string()])), None);
        assert_eq!(parse_offline_app_data(&encode(Value::Array(vec![Value::Binary(b"name".to_vec()), Value::from(8)]))), None);
        assert_eq!(parse_offline_app_data(&[0x92, 0xa1]), None);
        // A random part that is not one is refused.
        assert_eq!(parse_offline_app_data(&offline_app_data("0123456789ABCDEF", false)), None);
    }

    #[test]
    fn a_lookup_answer_names_the_random_parts_and_an_empty_one_names_none() {
        let named = vec![RANDOM.to_string(), "fedcba9876543210".to_string()];
        let data = lookup_app_data(&named);
        assert_eq!(data[0], 0x92);
        assert_eq!(parse_lookup_app_data(&data), Some(named));
        assert_eq!(lookup_app_data(&[]), vec![0x90]);
        assert_eq!(parse_lookup_app_data(&[0x90]), Some(vec![]));
        // An announce's [random, back] is no lookup answer.
        assert_eq!(parse_lookup_app_data(&offline_app_data(RANDOM, false)), None);
        // A string that is no random part is left out.
        assert_eq!(parse_lookup_app_data(&lookup_app_data(&["nope".to_string(), RANDOM.to_string()])), Some(vec![RANDOM.to_string()]));
    }

    #[test]
    fn a_copy_and_an_answer_round_trip_as_native_msgpack() {
        let sealed = vec![7u8; 200];
        let stamp = vec![9u8; 32];
        let copy = encode_copy(&sealed, &stamp);
        // [ bin8 sealed, bin8 stamp ], never a bin of packed msgpack (CHECK_THESE_THINGS_FIRST §11).
        assert_eq!(&copy[..3], &[0x92, 0xc4, 200]);
        assert_eq!(decode_copy(&copy), Some((sealed, stamp)));
        assert_eq!(decode_copy(&encode_answer(true, false)), None);
        assert_eq!(encode_answer(true, false), vec![0x92, 0xc3, 0xc2]);
        assert_eq!(decode_answer(&encode_answer(false, true)), Some((false, true)));
        assert_eq!(answer_bits(&encode_answer(true, true)), HELD | BACK);
        assert_eq!(answer_bits(&encode_answer(true, false)), HELD);
        assert_eq!(answer_bits(&[0xc3]), 0);
    }

    #[test]
    fn the_addresses_are_rfed_names_under_the_distros_identity() {
        let distro = Identity::new(true);
        let id = distro.hash.clone().unwrap();
        assert_eq!(offline_hash(&id, RANDOM), Destination::hash(Some(&id), "rfed", &["distro", "direct", RANDOM]));
        assert_eq!(lookup_hash(&id), Destination::hash(Some(&id), "rfed", &["distro", "direct"]));
        assert_ne!(offline_hash(&id, RANDOM), offline_hash(&id, "fedcba9876543210"));
        assert_eq!(distro_of(&id), delivery_hash(&distro).unwrap());
    }

    #[test]
    fn a_sender_watches_the_lookup_and_each_kept_offline_address() {
        let distro = Identity::new(true);
        let id = distro.hash.clone().unwrap();
        let kept = vec![RANDOM.to_string(), "not-a-random".to_string(), "fedcba9876543210".to_string()];
        assert_eq!(
            watched_hashes(&id, &kept),
            vec![lookup_hash(&id), offline_hash(&id, RANDOM), offline_hash(&id, "fedcba9876543210")],
            "the lookup first, then each valid kept random part; an invalid one is skipped"
        );
        assert_eq!(watched_hashes(&id, &[]), vec![lookup_hash(&id)], "with nothing kept, the lookup alone");
    }

    /// A sealed message to `distro` and a stamp over it at `cost`.
    fn sealed_and_stamp(distro: &Identity, cost: u32) -> (Vec<u8>, Vec<u8>) {
        let mut sealed = delivery_hash(distro).unwrap();
        sealed.extend_from_slice(&distro.encrypt(&[5u8; 160]).unwrap());
        let (stamp, _) = generate_stamp(&identity::full_hash(&sealed), cost, WORKBLOCK_EXPAND_ROUNDS_PN);
        (sealed, stamp.unwrap())
    }

    #[test]
    fn a_copy_is_taken_only_for_this_distro_with_a_stamp_that_meets_the_cost() {
        let distro = Identity::new(true);
        let other = Identity::new(true);
        let (sealed, stamp) = sealed_and_stamp(&distro, 4);
        let d = delivery_hash(&distro).unwrap();
        assert_eq!(check_copy(&sealed, &stamp, &d, 4), Ok(()));
        assert!(check_copy(&sealed, &stamp, &delivery_hash(&other).unwrap(), 4).is_err());
        assert!(check_copy(&sealed, &stamp[..31], &d, 4).is_err());
        // A cost the stamp does not reach (a stamp of value >= 40 is all but impossible).
        assert!(check_copy(&sealed, &stamp, &d, 40).is_err());
    }

    #[test]
    fn the_sync_proof_of_a_message_received_direct_is_what_rfed_accepts() {
        let distro = Identity::new(true);
        let (sealed, _) = sealed_and_stamp(&distro, 0);
        let sig = sign_sealed(&distro, &sealed).unwrap();
        let claim = SyncClaim::for_sealed(&sealed, &distro.get_public_key().unwrap(), &sig).unwrap();
        assert!(verify_sync_claim(&claim, &sync_transient_id(&sealed), &sealed).is_ok());
        // Another distro's message is not signed.
        let other = Identity::new(true);
        assert!(sign_sealed(&other, &sealed).is_err());
    }

    /// A message from a new sender to `distro`, sent through propagation and
    /// packed as the router packs it (`handle_outbound`), without its stamp.
    fn propagated_message(distro: &Identity, content: &str) -> LXMessage {
        let sender = Identity::new(true);
        let source = Destination::new_inbound(
            Some(sender),
            reticulum_rust::destination::DestinationType::Single,
            "lxmf".to_string(),
            vec!["delivery".to_string()],
        )
        .expect("source destination");
        let recipient = Identity::from_public_key(&distro.get_public_key().unwrap()).unwrap();
        let destination = Destination::new_outbound(
            Some(recipient),
            reticulum_rust::destination::DestinationType::Single,
            "lxmf".to_string(),
            vec!["delivery".to_string()],
        )
        .expect("destination");
        let mut msg = LXMessage::new(
            Some(destination),
            Some(source),
            Some(content.as_bytes().to_vec()),
            Some(Vec::new()),
            None,
            Some(LXMessage::PROPAGATED),
            None,
            None,
            None,
            false,
        )
        .expect("message");
        msg.pack(false).expect("packed for propagation");
        msg
    }

    #[test]
    fn a_senders_copy_is_the_message_rfed_gets_with_one_stamp() {
        let mut distro = Identity::new(true);
        let mut msg = propagated_message(&distro, "out of range");
        assert!(msg.propagation_stamp.is_none());
        let transient_id = msg.transient_id.clone().unwrap();

        let copy = direct_copy(&mut msg, Some(2)).expect("a copy");
        let (sealed, stamp) = decode_copy(&copy).expect("[sealed, stamp]");
        // One sealed message: its transient id is the message's own.
        assert_eq!(identity::full_hash(&sealed), transient_id);
        assert_eq!(msg.transient_id.as_deref(), Some(transient_id.as_slice()));
        // The stamp is the message's, and what the router sends carries it.
        assert_eq!(msg.propagation_stamp.as_deref(), Some(stamp.as_slice()));
        let mut sent = sealed.clone();
        sent.extend_from_slice(&stamp);
        assert_eq!(propagated_lxmf_data(msg.propagation_packed.as_ref().unwrap()).unwrap(), sent);
        // The device takes it at that cost, and opens it as a blob from RFed.
        let d = delivery_hash(&distro).unwrap();
        assert_eq!(check_copy(&sealed, &stamp, &d, 2), Ok(()));
        let opened = lxmf_rust::distro::unwrap_blob(&mut distro, &sealed).unwrap().expect("for this distro");
        assert_eq!(opened.content, "out of range");
        // A second copy is the same bytes: nothing is mined or encrypted again.
        assert_eq!(direct_copy(&mut msg, Some(30)).unwrap(), copy);
    }

    #[test]
    fn no_copy_is_made_of_a_message_not_sent_through_propagation_or_with_no_cost_known() {
        let distro = Identity::new(true);
        let mut msg = propagated_message(&distro, "x");
        assert!(direct_copy(&mut msg, None).is_err());
        assert!(msg.propagation_stamp.is_none());
        msg.desired_method = Some(LXMessage::DIRECT);
        assert!(direct_copy(&mut msg, Some(2)).is_err());
    }

    #[test]
    fn the_propagated_forms_message_is_read_out_whole() {
        let mut data = Vec::new();
        rmpv::encode::write_value(
            &mut data,
            &Value::Array(vec![Value::F64(1.5), Value::Array(vec![Value::Binary(vec![1, 2, 3])])]),
        )
        .unwrap();
        assert_eq!(propagated_lxmf_data(&data), Ok(vec![1, 2, 3]));
        let mut two = Vec::new();
        rmpv::encode::write_value(
            &mut two,
            &Value::Array(vec![Value::F64(1.5), Value::Array(vec![Value::Binary(vec![1]), Value::Binary(vec![2])])]),
        )
        .unwrap();
        assert!(propagated_lxmf_data(&two).is_err());
    }
}
