//! Member statuses and keys (RFed-spec Group.md, "Member statuses and keys
//! (2026-10-06)"; LXMF-rust/DISPLAY_NAMES.md section 10, key 10): the parts of
//! the group follow-up that Swift cannot make, kept apart from the C
//! wrappers in `lib.rs` so that `cargo test` runs them, and every one of the
//! shared vectors (`tests/data/group_status_vectors.json`), without a stack.
//! The same code as Retichat-android's `rust/retichat-jni/src/group_status.rs`
//! (the two glue crates are separate, and the messages they check must not be).
//!
//! * [`receipt`] (and [`receipt_parts`], the same on a message's parts, which
//!   [`distro_unwrap_json`] runs on what the distro unwrap rebuilt, RFed SPEC
//!   §17.14): what a message the router has just delivered is worth. An
//!   accept or leave carries its sender's own key (`GROUP_MEMBER_KEYS`, one
//!   `hash:base64-public-key` entry). It is bound as an invite chunk's key is:
//!   the key's `lxmf.delivery` destination must be the entry's hash, and the
//!   entry's hash must be the message's LXMF source. The router checks the
//!   signature at receipt under a key it holds and reports a source it holds
//!   none for as unverified (`SOURCE_UNKNOWN`); this checks it under the bound
//!   key then and reports the result as the router reports any signature:
//!   validated, or invalid (a forged message). The bound key itself and the
//!   message exactly as received (what a creator keeps and answers with) are
//!   reported too. **Nothing is remembered here**: Swift remembers the key
//!   after the group rule has passed, never for a message it drops.
//! * [`unpack_element`]: an element of a `status`, a member's own packed accept
//!   or leave as the creator received it, unpacked and checked as if it had
//!   arrived directly: the router's own `LXMessage::unpack_from_bytes` (the
//!   key it holds for the source), then [`receipt`]'s carried key. It is also
//!   how Swift decides an entry it held for a key that was not here (from the
//!   switch around 2026-10-26).
//! * [`set_statuses`]: key 10 of the Retichat field, an array of bin, always in
//!   the Retichat field (it has no old top-level field), written as a native
//!   array of bins and never wrapped again (CHECK_THESE_THINGS_FIRST section 11).
//!
//! No timers and no retries (DESIGN_PRINCIPLES section 1, 3): nothing here waits.

use std::io::Cursor;

use base64::alphabet;
use base64::engine::{Engine, GeneralPurpose, GeneralPurposeConfig};
use lxmf_rust::lx_message::LXMessage;
use lxmf_rust::retichat_field::{self, GroupValue, RF_GROUP_ACTION, RF_GROUP_ID, RF_GROUP_MEMBER_KEYS};
use reticulum_rust::destination::{Destination, DestinationType};
use reticulum_rust::identity::{self, Identity};
use rmpv::Value;

/// Key 10 of the Retichat field: `GROUP_STATUSES`, an array of bin (the
/// members' own packed accept and leave messages) carried by a `status`. It
/// has no old top-level field and is not one of the nine group entries
/// (`retichat_field::GROUP_ENTRIES`).
pub const RF_GROUP_STATUSES: u8 = 10;

/// The longest payload of an accept or leave worth keeping or passing on, as
/// the web's `STATUS_PAYLOAD_LIMIT`: a genuine one holds no content, so its
/// payload (group id, action and sender, a name of at most 64 characters, a
/// ticket) is a few hundred bytes.
pub const STATUS_PAYLOAD_LIMIT: usize = 2048;

/// destination (16) + source (16) + signature (64).
pub const PACKED_HEADER_LEN: usize = 96;

/// The longest packed accept or leave: a status element over this is skipped,
/// and a creator keeps no copy of one.
pub const STATUS_PACKED_LIMIT: usize = PACKED_HEADER_LEN + STATUS_PAYLOAD_LIMIT;

/// The verdict codes are the router's `unverified_reason`: 0 validated, 1 the
/// source's key is not held, 2 the signature is invalid.
pub const VALIDATED: u8 = 0;
pub const SOURCE_UNKNOWN: u8 = LXMessage::SOURCE_UNKNOWN;
pub const SIGNATURE_INVALID: u8 = LXMessage::SIGNATURE_INVALID;

/// A destination hash is 16 bytes, a public key 64 (x25519 | ed25519).
const HASH_LEN: usize = 16;
const KEY_LEN: usize = 64;

/// A key entry's base64 is exactly 86 characters and `==`, the way every
/// client writes it (the web's `/^[A-Za-z0-9+/]{86}==$/`); the trailing bits
/// of the last character are not checked, as a JavaScript `Buffer` does not.
const KEY_B64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true),
);

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// What a received message is worth, and what a creator needs of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Receipt {
    pub validated: bool,
    /// [`VALIDATED`], [`SOURCE_UNKNOWN`] or [`SIGNATURE_INVALID`].
    pub unverified_reason: u8,
    /// The 64-byte key the message carries for its own sender, when it binds
    /// (an accept or leave only), whether the router already held a key for
    /// that sender or not: a creator answers only an accept that carries one.
    pub sender_key: Option<Vec<u8>>,
    /// The message exactly as received (`destination | source | signature |
    /// payload`, a stamp with it), for an accept or leave of at most
    /// [`STATUS_PACKED_LIMIT`] bytes: what a creator keeps and a held entry is
    /// decided from. None for any other message, and for one over the limit.
    pub packed: Option<Vec<u8>>,
}

/// Whether `fields` are those of an accept or a leave of a group (a group id
/// and the action, in either form of section 10): the only messages that
/// carry a key for their own sender.
fn is_accept_or_leave(fields: &Value) -> bool {
    let has_id = matches!(retichat_field::read_group_entry(fields, RF_GROUP_ID), Some(GroupValue::Str(_)));
    let action = match retichat_field::read_group_entry(fields, RF_GROUP_ACTION) {
        Some(GroupValue::Str(action)) => action,
        _ => return false,
    };
    has_id && (action == "accept" || action == "leave")
}

/// The `lxmf.delivery` destination of `identity`, as the router builds it to check a source's signature.
fn delivery_destination_of(identity: Identity) -> Option<Destination> {
    Destination::new_outbound(Some(identity), DestinationType::Single, "lxmf".to_string(), vec!["delivery".to_string()]).ok()
}

/// The `lxmf.delivery` destination `key` (64 bytes) produces, or None.
fn delivery_destination(key: &[u8]) -> Option<Destination> {
    if key.len() != KEY_LEN {
        return None;
    }
    delivery_destination_of(Identity::from_public_key(key).ok()?)
}

/// The key `fields` carry for the message's own sender `source`, once bound:
/// the key and the destination it produces. Entries are `hash:base64`, comma
/// separated; only well-formed ones count (a 32-hex hash, lowercased, and a
/// key of the exact form), the last entry for `source` wins, and an entry for
/// any other hash is not the sender's and is ignored. The key then must
/// produce `source` as an `lxmf.delivery` destination, or it is no key: the
/// message stays as one that carried none (`boundSenderKey` in the web's
/// `lib/group_status.js`).
fn carried_key(fields: &Value, source: &[u8]) -> Option<(Vec<u8>, Destination)> {
    let Some(GroupValue::Str(entries)) = retichat_field::read_group_entry(fields, RF_GROUP_MEMBER_KEYS) else {
        return None;
    };
    let want = hex(source);
    let mut entry_for_source: Option<&str> = None;
    for entry in entries.split(',').map(str::trim).filter(|entry| !entry.is_empty()) {
        let Some((hash, key)) = entry.split_once(':') else { continue };
        let hash = hash.to_ascii_lowercase();
        let well_formed_hash = hash.len() == 2 * HASH_LEN && hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
        let well_formed_key = key.len() == 88
            && key.ends_with("==")
            && key[..86].bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/');
        if well_formed_hash && well_formed_key && hash == want {
            entry_for_source = Some(key);
        }
    }
    let key = KEY_B64.decode(entry_for_source?).ok()?;
    let destination = delivery_destination(&key)?;
    (destination.hash == source).then_some((key, destination))
}

/// What the signature of a packed message covers, and the signature: the way
/// `LXMessage::unpack_from_bytes` builds it, so that a check under another key
/// than the router's agrees with the router's own: `destination | source |
/// the first four payload elements packed again | the SHA-256 of those`. A
/// stamp (a fifth element) is not signed.
fn signature_and_signed_part(packed: &[u8]) -> Result<(Vec<u8>, Vec<u8>), String> {
    if packed.len() <= PACKED_HEADER_LEN {
        return Err(format!("{} bytes hold no payload", packed.len()));
    }
    let payload = rmpv::decode::read_value(&mut Cursor::new(&packed[PACKED_HEADER_LEN..]))
        .map_err(|e| format!("the payload is not msgpack: {e}"))?;
    let items = payload.as_array().ok_or("the payload is not an array")?;
    let core = Value::Array(items.iter().take(4).cloned().collect());
    let mut core_bytes = Vec::new();
    rmpv::encode::write_value(&mut core_bytes, &core).map_err(|e| format!("the payload cannot be packed again: {e}"))?;
    let mut signed = Vec::with_capacity(2 * HASH_LEN + core_bytes.len() + 32);
    signed.extend_from_slice(&packed[..2 * HASH_LEN]);
    signed.extend_from_slice(&core_bytes);
    let hash = identity::full_hash(&signed);
    signed.extend_from_slice(&hash);
    Ok((packed[2 * HASH_LEN..PACKED_HEADER_LEN].to_vec(), signed))
}

/// Whether the signature of `packed` is valid under `destination`'s key.
fn valid_under(packed: &[u8], destination: &Destination) -> Option<bool> {
    let (signature, signed) = signature_and_signed_part(packed).ok()?;
    Some(destination.validate(&signature, &signed))
}

/// What the message `msg` is worth, given the router's verdict on it
/// (`validated`, `reason`: `ReceivedMessage`'s `signature_validated` and
/// `unverified_reason`).
///
/// Any message keeps the router's verdict and carries nothing extra, except
/// an accept or a leave (RFed-spec Group.md, "Verifying an accept or leave"):
///
/// * the key it carries for its own sender, when it binds, is reported;
/// * when the router held no key for the source (`SOURCE_UNKNOWN`) the
///   signature is checked under that key: validated, or invalid when it does
///   not verify (forged: signed by someone else under the sender's name);
/// * a key already held decides, as the router has reported (a key that binds
///   is the same key, and a key that does not bind is no key);
/// * the packed message is reported when it is no longer than
///   [`STATUS_PACKED_LIMIT`].
pub fn receipt(msg: &LXMessage, validated: bool, reason: u8) -> Receipt {
    receipt_of(&msg.fields, &msg.source_hash, msg.packed.as_deref(), validated, reason)
}

/// [`receipt`] on a message's parts: its fields, its LXMF source and the packed message as received
/// (`destination | source | signature | payload`). For a message no router unpacked: the distro
/// unwrap (GROUPS-DISTRO-DESIGN.md §7, §17.2) has these, not an `LXMessage`.
pub fn receipt_parts(fields: &Value, source_hash: &[u8], packed: &[u8], validated: bool, reason: u8) -> Receipt {
    receipt_of(fields, source_hash, Some(packed), validated, reason)
}

fn receipt_of(fields: &Value, source_hash: &[u8], whole: Option<&[u8]>, validated: bool, reason: u8) -> Receipt {
    let plain = Receipt { validated, unverified_reason: reason, sender_key: None, packed: None };
    if !is_accept_or_leave(fields) {
        return plain;
    }
    let packed = whole.filter(|packed| packed.len() <= STATUS_PACKED_LIMIT).map(<[u8]>::to_vec);
    let Some((key, destination)) = carried_key(fields, source_hash) else {
        return Receipt { packed, ..plain };
    };
    let (validated, reason) = match (validated, reason, whole) {
        (false, SOURCE_UNKNOWN, Some(whole)) => match valid_under(whole, &destination) {
            Some(true) => (true, VALIDATED),
            Some(false) => (false, SIGNATURE_INVALID),
            // A check that cannot run does not verify (the router unpacked it, so this is not expected).
            None => (false, SIGNATURE_INVALID),
        },
        other => (other.0, other.1),
    };
    Receipt { validated, unverified_reason: reason, sender_key: Some(key), packed }
}

/// The JSON of the distro unwrap (`retichat_distro_unwrap`; RFed SPEC §17.14, GROUPS-DISTRO-DESIGN.md
/// §7, §17.2): `lxmf_rust::distro::unwrap_blob`, then [`receipt_parts`] on the message it rebuilt
/// (its fields map, an empty one when it has none; its source; its packed bytes; its own verdict),
/// reported by `DistroMessage::to_json_with_receipt`, the one definition of the keys. So an accept
/// or leave from a member whose key this device does not hold is decided under the key it carries,
/// as on the direct path, and a creator gets the packed copy it keeps. Nothing is remembered here.
/// `Ok(None)` for a blob addressed to another distro.
pub fn distro_unwrap_json(distro: &mut Identity, blob: &[u8]) -> Result<Option<String>, String> {
    let Some(message) = lxmf_rust::distro::unwrap_blob(distro, blob)? else {
        return Ok(None);
    };
    let fields = match message.fields.as_deref() {
        // unwrap_blob has read these bytes as a map already, so they decode.
        Some(bytes) => rmpv::decode::read_value(&mut Cursor::new(bytes)).unwrap_or_else(|_| Value::Map(Vec::new())),
        None => Value::Map(Vec::new()),
    };
    let r = receipt_parts(
        &fields,
        &message.source_hash,
        &message.packed,
        message.signature_validated,
        message.unverified_reason.unwrap_or(VALIDATED),
    );
    Ok(Some(message.to_json_with_receipt(&lxmf_rust::distro::DistroReceipt {
        validated: r.validated,
        unverified_reason: r.unverified_reason,
        sender_key: r.sender_key,
        packed: r.packed,
    })))
}

/// An element of a `status`, unpacked and checked as if it had arrived
/// directly.
#[derive(Debug, Clone, PartialEq)]
pub struct Element {
    pub receipt: Receipt,
    pub destination: Vec<u8>,
    pub source: Vec<u8>,
    /// The LXMF message hash (32 bytes).
    pub hash: Vec<u8>,
    pub timestamp: f64,
    /// The LXMF fields map, msgpack, as the delivery callback's `fieldsRaw`.
    pub fields_raw: Vec<u8>,
}

/// [`unpack_element_with`] under the keys the stack holds: `Identity::recall` by the
/// `lxmf.delivery` hash, which is what the router checks a source's signature with.
pub fn unpack_element(packed: &[u8]) -> Result<Element, String> {
    unpack_element_with(packed, &|hash| Identity::recall(hash))
}

/// Unpack and check `packed`, an element of a `status` or an entry held for
/// its sender's key: `destination | source | signature | payload`, longer than
/// the 96 bytes of header and no longer than [`STATUS_PACKED_LIMIT`]. The
/// message is unpacked by the router's own `unpack_from_bytes`, and its
/// signature checked exactly as the router checks any: under the key `held`
/// returns for the source's `lxmf.delivery` hash (valid or invalid), or, when
/// it holds none, as unverified (`SOURCE_UNKNOWN`); [`receipt`] then applies the
/// key an accept or leave carries. `held` is a parameter so that the shared
/// vectors can be run for a receiver holding no member's key and one holding
/// every member's without touching the process's identity store. Errors when
/// it is not an LXMF message.
pub fn unpack_element_with(packed: &[u8], held: &dyn Fn(&[u8]) -> Option<Identity>) -> Result<Element, String> {
    if packed.len() <= PACKED_HEADER_LEN || packed.len() > STATUS_PACKED_LIMIT {
        return Err(format!("{} bytes is not the size of an accept or leave", packed.len()));
    }
    let msg = LXMessage::unpack_from_bytes(packed, None)?;
    let (validated, reason) = match held(&msg.source_hash).and_then(delivery_destination_of) {
        Some(destination) => match valid_under(packed, &destination) {
            Some(true) => (true, VALIDATED),
            // A check that cannot run does not verify.
            Some(false) | None => (false, SIGNATURE_INVALID),
        },
        None => (false, SOURCE_UNKNOWN),
    };
    let receipt = receipt(&msg, validated, reason);
    let mut fields_raw = Vec::new();
    rmpv::encode::write_value(&mut fields_raw, msg.get_fields()).map_err(|e| format!("the fields cannot be packed again: {e}"))?;
    Ok(Element {
        receipt,
        destination: msg.destination_hash.clone(),
        source: msg.source_hash.clone(),
        hash: msg.hash.clone().unwrap_or_default(),
        timestamp: msg.timestamp.unwrap_or(0.0),
        fields_raw,
    })
}

/// The bytes `retichat_group_unpack_packed` returns for `element`, all numbers big
/// endian:
///
/// | bytes | |
/// |---|---|
/// | 0 | verdict: 0 validated, 1 source unknown, 2 invalid |
/// | 1 | 1 when a bound sender key follows, else 0 |
/// | 2..18 | destination hash |
/// | 18..34 | source hash |
/// | 34..66 | message hash |
/// | 66..74 | timestamp, f64 |
/// | 74..138 | the sender key, only when byte 1 is 1 |
/// | then 4 | length of the fields, u32 |
/// | then n | the fields map, msgpack |
///
/// Swift's `UnpackedGroupMessage.parse` reads it; both pin this to one
/// literal (`ELEMENT_HEX` here, tests/GroupStatusesTests.swift there).
pub fn encode_element(element: &Element) -> Vec<u8> {
    let key = element.receipt.sender_key.as_deref();
    let mut out = Vec::with_capacity(78 + KEY_LEN + element.fields_raw.len());
    out.push(element.receipt.unverified_reason);
    out.push(u8::from(key.is_some()));
    out.extend_from_slice(&element.destination);
    out.extend_from_slice(&element.source);
    out.extend_from_slice(&element.hash);
    out.extend_from_slice(&element.timestamp.to_bits().to_be_bytes());
    if let Some(key) = key {
        out.extend_from_slice(key);
    }
    out.extend_from_slice(&(element.fields_raw.len() as u32).to_be_bytes());
    out.extend_from_slice(&element.fields_raw);
    out
}

/// Write key 10 (`GROUP_STATUSES`) into `fields`' Retichat field: a native
/// array of bins, one for each of `elements`, merged beside the entries
/// already there. It is written into the Retichat field whatever form the
/// other group entries go in: released builds skip an unknown key inside
/// `0xD1`, and there is no old field to carry it. An empty array is written
/// too: it is a creator's valid answer when nobody else has answered.
pub fn set_statuses_in(fields: &mut Value, elements: &[Vec<u8>]) -> Result<(), String> {
    for (index, element) in elements.iter().enumerate() {
        if element.len() <= PACKED_HEADER_LEN || element.len() > STATUS_PACKED_LIMIT {
            return Err(format!(
                "element {index} is {} bytes: a packed accept or leave is {}..={STATUS_PACKED_LIMIT}",
                element.len(),
                PACKED_HEADER_LEN + 1
            ));
        }
    }
    let value = Value::Array(elements.iter().map(|element| Value::Binary(element.clone())).collect());
    retichat_field::set_entry(fields, RF_GROUP_STATUSES, value);
    Ok(())
}

/// [`set_statuses_in`] on the outbound message `msg`.
pub fn set_statuses(msg: &mut LXMessage, elements: &[Vec<u8>]) -> Result<(), String> {
    set_statuses_in(&mut msg.fields, elements)
}

/// The list of elements `retichat_message_set_retichat_statuses` is given, flat:
/// `count u32 | (length u32 | bytes) * count`, all numbers big endian. Swift builds it from the
/// copies it keeps; it is no part of the wire. An element that runs past the buffer, a count the
/// buffer cannot hold and bytes left over after the last element are errors, so a mistake in the
/// host never becomes a shorter list.
pub fn decode_elements(flat: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    let read_u32 = |at: usize| -> Result<usize, String> {
        flat.get(at..at + 4)
            .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize)
            .ok_or_else(|| format!("the element list ends inside a length at byte {at}"))
    };
    let count = read_u32(0)?;
    if count > flat.len() / 4 {
        return Err(format!("{count} elements cannot fit in {} bytes", flat.len()));
    }
    let mut at = 4;
    let mut elements = Vec::with_capacity(count);
    for index in 0..count {
        let length = read_u32(at)?;
        at += 4;
        let end = at.checked_add(length).filter(|end| *end <= flat.len()).ok_or_else(|| format!("element {index} runs past the end of the list"))?;
        elements.push(flat[at..end].to_vec());
        at = end;
    }
    if at != flat.len() {
        return Err(format!("{} bytes follow the last element", flat.len() - at));
    }
    Ok(elements)
}

/// [`decode_elements`]' inverse (the tests, and the layout Swift writes).
pub fn encode_elements(elements: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(elements.len() as u32).to_be_bytes());
    for element in elements {
        out.extend_from_slice(&(element.len() as u32).to_be_bytes());
        out.extend_from_slice(element);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value as Json;

    const VECTORS: &str = include_str!("../tests/data/group_status_vectors.json");

    fn vectors() -> Json {
        serde_json::from_str(VECTORS).expect("the vectors are JSON")
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
    }

    fn named<'a>(list: &'a Json, key: &str, name: &str) -> &'a Json {
        list.as_array().unwrap().iter().find(|entry| entry[key] == name).unwrap_or_else(|| panic!("no {name}"))
    }

    fn identity_of<'a>(vectors: &'a Json, name: &str) -> &'a Json {
        named(&vectors["identities"], "name", name)
    }

    fn fields_value(hex_bytes: &str) -> Value {
        rmpv::decode::read_value(&mut Cursor::new(unhex(hex_bytes))).unwrap()
    }

    fn encode(value: &Value) -> Vec<u8> {
        let mut out = Vec::new();
        rmpv::encode::write_value(&mut out, value).unwrap();
        out
    }

    /// The members whose keys a receiver holds in each context of the vectors' `verdict`.
    const HOLDERS: [&str; 6] = ["alice", "bob", "carol", "dave", "erin", "frank"];

    fn verdict_name(receipt: &Receipt) -> &'static str {
        match (receipt.validated, receipt.unverified_reason) {
            (true, VALIDATED) => "verified",
            (false, SIGNATURE_INVALID) => "forged",
            (false, SOURCE_UNKNOWN) => "unverifiable",
            other => panic!("not a verdict: {other:?}"),
        }
    }

    /// The copy of the shared vectors the crate's tests run is LXMF-rust's own file: its working tree's once
    /// the vectors are merged there, else the one committed on its `group-statuses` branch. Neither found
    /// fails the test rather than skipping it: a skipped contract check reads as a pass.
    #[test]
    fn the_copy_of_the_vectors_here_is_the_one_lxmf_rust_has() {
        let lxmf = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../LXMF-rust");
        let tree = lxmf.join("tests/group_status_vectors.json");
        let theirs = if tree.exists() {
            std::fs::read_to_string(&tree).expect("LXMF-rust's vectors are readable")
        } else {
            let shown = std::process::Command::new("git")
                .arg("-C")
                .arg(&lxmf)
                .args(["show", "group-statuses:tests/group_status_vectors.json"])
                .output()
                .expect("git runs");
            assert!(
                shown.status.success(),
                "the vectors are in neither {} nor LXMF-rust's group-statuses branch",
                tree.display()
            );
            String::from_utf8(shown.stdout).expect("the vectors are UTF-8")
        };
        assert_eq!(
            theirs, VECTORS,
            "tests/data/group_status_vectors.json is not LXMF-rust's: copy it again (the web's tools/group_status_vectors.mjs writes it there)"
        );
    }

    #[test]
    fn the_limits_are_the_webs() {
        assert_eq!(STATUS_PAYLOAD_LIMIT, 2048);
        assert_eq!(PACKED_HEADER_LEN, 96);
        assert_eq!(STATUS_PACKED_LIMIT, 2144);
        assert_eq!((VALIDATED, SOURCE_UNKNOWN, SIGNATURE_INVALID), (0, 1, 2));
        assert_eq!(RF_GROUP_STATUSES, 10);
    }

    #[test]
    fn the_identities_are_what_the_file_says() {
        let vectors = vectors();
        let names: Vec<&str> = vectors["identities"].as_array().unwrap().iter().map(|i| i["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["creator", "alice", "bob", "carol", "dave", "erin", "frank", "mallory"]);
        for spec in vectors["identities"].as_array().unwrap() {
            let name = spec["name"].as_str().unwrap();
            let public_key = unhex(spec["public_key_hex"].as_str().unwrap());
            let rebuilt = Identity::from_bytes(&unhex(spec["private_key_hex"].as_str().unwrap())).unwrap();
            assert_eq!(rebuilt.get_public_key().unwrap(), public_key, "{name}");
            let destination = delivery_destination(&public_key).unwrap();
            assert_eq!(hex(&destination.hash), spec["lxmf_delivery_hash_hex"].as_str().unwrap(), "{name}");
            let entry = format!("{}:{}", hex(&destination.hash), KEY_B64.encode(&public_key));
            assert_eq!(entry, spec["key_entry"].as_str().unwrap(), "{name}");
        }
    }

    /// A receiver's keys: the identities of `names`, by `lxmf.delivery` hash. The process's identity store is
    /// never touched (it persists to disk and is shared with every other run), so the tests run in any order.
    fn holding(vectors: &Json, names: &[&str]) -> impl Fn(&[u8]) -> Option<Identity> {
        let keys: std::collections::HashMap<Vec<u8>, Vec<u8>> = names
            .iter()
            .map(|name| {
                let spec = identity_of(vectors, name);
                (unhex(spec["lxmf_delivery_hash_hex"].as_str().unwrap()), unhex(spec["public_key_hex"].as_str().unwrap()))
            })
            .collect();
        move |hash: &[u8]| keys.get(hash).map(|key| Identity::from_public_key(key).unwrap())
    }

    /// Every message's verdict, for a receiver holding no member's key and one holding every member's,
    /// from the file's bytes.
    #[test]
    fn every_messages_verdict_is_the_files_for_a_receiver_holding_nothing_and_everything() {
        let vectors = vectors();
        assert!(vectors["messages"].as_array().unwrap().len() >= 9);
        for context in ["none", "all"] {
            let held = holding(&vectors, if context == "all" { &HOLDERS } else { &[] });
            for message in vectors["messages"].as_array().unwrap() {
                let name = message["name"].as_str().unwrap();
                let packed = unhex(message["packed_hex"].as_str().unwrap());
                let element = unpack_element_with(&packed, &held).unwrap_or_else(|e| panic!("{name}: {e}"));
                assert_eq!(
                    verdict_name(&element.receipt),
                    message["verdict"][context].as_str().unwrap(),
                    "{name}, the receiver holding {context}"
                );
                // verified counts, forged is ignored, unverifiable counts until the switch and is held from it
                let before = match element.receipt.unverified_reason {
                    SIGNATURE_INVALID => "ignored",
                    _ => "counts",
                };
                let from = match element.receipt.unverified_reason {
                    VALIDATED => "counts",
                    SOURCE_UNKNOWN => "held",
                    _ => "ignored",
                };
                assert_eq!(before, message["outcome_before_switch"][context].as_str().unwrap(), "{name}: {context}");
                assert_eq!(from, message["outcome_from_switch"][context].as_str().unwrap(), "{name}: {context}");

                // The key it carries, when it binds, is the sender's own: reported whether the router held a key or not.
                let source = message["source"].as_str().unwrap();
                let binds = !message["carries_key_of"].is_null()
                    && message["key_entry_hash_of"] == source
                    && message["carries_key_of"] == source;
                assert_eq!(element.receipt.sender_key.is_some(), binds, "{name}: a key that binds is the sender's own");
                if binds {
                    assert_eq!(
                        hex(element.receipt.sender_key.as_deref().unwrap()),
                        identity_of(&vectors, source)["public_key_hex"].as_str().unwrap(),
                        "{name}"
                    );
                }
                // The message exactly as received, for the creator's copy.
                assert_eq!(element.receipt.packed.as_deref(), Some(packed.as_slice()), "{name}");
                assert_eq!(hex(&element.source), identity_of(&vectors, source)["lxmf_delivery_hash_hex"].as_str().unwrap(), "{name}");
                assert_eq!(hex(&element.destination), identity_of(&vectors, "creator")["lxmf_delivery_hash_hex"].as_str().unwrap(), "{name}");
                assert_eq!(hex(&element.hash), message["message_hash_hex"].as_str().unwrap(), "{name}: the LXMF message hash");
                assert_eq!(element.fields_raw, unhex(message["fields_msgpack_hex"].as_str().unwrap()), "{name}: the fields as the delivery callback gives them");
            }
        }
    }

    /// The creator's statuses are signed by it, and every element a receiver is handed is judged as the file's
    /// `receiver_outcomes` say, for a receiver holding no member's key and one holding every member's.
    #[test]
    fn the_statuses_and_every_element_are_judged_as_the_file_says() {
        let vectors = vectors();
        let creator = identity_of(&vectors, "creator")["lxmf_delivery_hash_hex"].as_str().unwrap();
        for status in vectors["statuses"].as_array().unwrap() {
            let name = status["name"].as_str().unwrap();
            let packed = unhex(status["packed_hex"].as_str().unwrap());
            let with = unpack_element_with(&packed, &holding(&vectors, &["creator"])).unwrap();
            let without = unpack_element_with(&packed, &holding(&vectors, &[])).unwrap();
            assert_eq!(verdict_name(&with.receipt), "verified", "{name}: signed by the creator");
            assert_eq!(verdict_name(&without.receipt), "unverifiable", "{name}: and by nobody whose key is not held");
            assert_eq!(hex(&with.source), creator, "{name}");
            // A status is no accept or leave: it carries no key for its sender and no copy is given.
            assert!(with.receipt.sender_key.is_none() && with.receipt.packed.is_none(), "{name}");
        }
        assert_eq!(vectors["receiver_outcomes"].as_array().unwrap().len(), 4);
        for outcome in vectors["receiver_outcomes"].as_array().unwrap() {
            let names: Vec<&str> = outcome["holds_keys_of"].as_array().unwrap().iter().map(|n| n.as_str().unwrap()).collect();
            let held = holding(&vectors, &names);
            for element in outcome["elements"].as_array().unwrap() {
                let message = named(&vectors["messages"], "name", element["message"].as_str().unwrap());
                let got = unpack_element_with(&unhex(message["packed_hex"].as_str().unwrap()), &held).unwrap();
                assert_eq!(
                    verdict_name(&got.receipt),
                    element["verdict"].as_str().unwrap(),
                    "{} holding {names:?}",
                    element["message"]
                );
            }
        }
    }

    /// The router's own verdict (`ReceivedMessage`'s `signature_validated` and `unverified_reason`) for a message
    /// from a source whose key it holds none for is SOURCE_UNKNOWN; `receipt` checks the carried key then and only then.
    #[test]
    fn the_delivery_callbacks_receipt_applies_the_carried_key_only_to_a_source_the_router_held_no_key_for() {
        let vectors = vectors();
        let carol = named(&vectors["messages"], "name", "carol_accept_forged");
        let alice = named(&vectors["messages"], "name", "alice_accept_keyed_retichat");
        let bob = named(&vectors["messages"], "name", "bob_accept_keyless_legacy");
        let parse = |m: &Json| LXMessage::unpack_from_bytes(&unhex(m["packed_hex"].as_str().unwrap()), None).unwrap();
        // Unknown source, a key that binds: validated, or invalid (forged: signed by mallory under carol's name).
        let (a, c) = (parse(alice), parse(carol));
        assert_eq!(verdict_name(&receipt(&a, false, SOURCE_UNKNOWN)), "verified");
        assert_eq!(verdict_name(&receipt(&c, false, SOURCE_UNKNOWN)), "forged");
        // A key already held decides, whatever the message carries: the router's verdict stands.
        assert_eq!(verdict_name(&receipt(&a, true, VALIDATED)), "verified");
        assert_eq!(verdict_name(&receipt(&a, false, SIGNATURE_INVALID)), "forged");
        assert_eq!(verdict_name(&receipt(&c, false, SIGNATURE_INVALID)), "forged");
        // A keyless accept is as unverifiable as the router found it.
        let b = parse(bob);
        let r = receipt(&b, false, SOURCE_UNKNOWN);
        assert_eq!((verdict_name(&r), r.sender_key.is_some(), r.packed.is_some()), ("unverifiable", false, true));
        // The carried key is reported either way.
        assert!(receipt(&a, true, VALIDATED).sender_key.is_some());
    }

    #[test]
    fn the_statuses_are_read_and_written_byte_for_byte() {
        let vectors = vectors();
        let creator = identity_of(&vectors, "creator");
        let creator_hash = creator["lxmf_delivery_hash_hex"].as_str().unwrap();
        assert_eq!(vectors["statuses"].as_array().unwrap().len(), 4);
        for status in vectors["statuses"].as_array().unwrap() {
            let name = status["name"].as_str().unwrap();
            let fields = fields_value(status["fields_msgpack_hex"].as_str().unwrap());
            // Read: key 10 of the Retichat field is an array of bin holding exactly the listed messages.
            let Some(Value::Array(elements)) = retichat_field::read_entry(&fields, RF_GROUP_STATUSES) else {
                panic!("{name}: key 10 is not an array");
            };
            let listed: Vec<Vec<u8>> = status["statuses"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| unhex(named(&vectors["messages"], "name", e["message"].as_str().unwrap())["packed_hex"].as_str().unwrap()))
                .collect();
            let read: Vec<Vec<u8>> = elements
                .iter()
                .map(|e| match e {
                    Value::Binary(bytes) => bytes.clone(),
                    other => panic!("{name}: an element is {other:?}, not a bin"),
                })
                .collect();
            assert_eq!(read, listed, "{name}");
            // Key 10 has no old field: it is never read from the top level.
            assert!(retichat_field::top_level(&fields, RF_GROUP_STATUSES).is_none(), "{name}");
            // The group entries are where the form puts them.
            for (key, want) in [(RF_GROUP_ID, status["group_entries"]["group_id"].as_str().unwrap()),
                                (RF_GROUP_ACTION, "status"), (retichat_field::RF_GROUP_SENDER, creator_hash)] {
                assert_eq!(retichat_field::read_group_entry(&fields, key), Some(GroupValue::Str(want.to_string())), "{name}: key {key}");
            }
            // Written: the same entries and the writer rebuild the file's fields exactly.
            let in_retichat_field = status["form"] == "retichat";
            let mut rebuilt = Value::Map(Vec::new());
            for (key, value) in [(RF_GROUP_ID, status["group_entries"]["group_id"].as_str().unwrap()),
                                 (RF_GROUP_ACTION, "status"), (retichat_field::RF_GROUP_SENDER, creator_hash)] {
                retichat_field::set_group_entry_as(&mut rebuilt, key, &GroupValue::Str(value.to_string()), in_retichat_field).unwrap();
            }
            retichat_field::set_entry(&mut rebuilt, retichat_field::RF_DISPLAY_NAME, Value::Binary(b"Creator".to_vec()));
            set_statuses_in(&mut rebuilt, &listed).unwrap();
            assert_eq!(hex(&encode(&rebuilt)), status["fields_msgpack_hex"].as_str().unwrap(), "{name}: written as the file has it");
        }
    }

    #[test]
    fn a_status_is_an_array_of_bins_never_a_bin_of_packed_msgpack() {
        // CHECK_THESE_THINGS_FIRST section 11: key 10 starts with an array head (0x9n), each element with a bin head.
        let vectors = vectors();
        let status = named(&vectors["statuses"], "name", "status_to_frank_retichat");
        let bytes = unhex(status["fields_msgpack_hex"].as_str().unwrap());
        let key10 = bytes.windows(2).position(|w| w == [0x0a, 0x95]).expect("key 10 is a fixarray of five");
        assert_eq!(bytes[key10 + 2], 0xc5, "the first element is a bin 16 (a packed message of 256..=65535 bytes)");
        let mut empty = Value::Map(Vec::new());
        set_statuses_in(&mut empty, &[]).unwrap();
        assert_eq!(hex(&encode(&empty)), "81ccd1810a90", "an empty answer is an empty native array, 0x90");
    }

    #[test]
    fn a_status_writes_into_the_retichat_field_beside_the_other_entries_and_refuses_an_element_no_receiver_would_read() {
        let mut fields = Value::Map(vec![(Value::from(0xA0u8), Value::String("g".into()))]);
        retichat_field::set_entry(&mut fields, 0, Value::Binary(b"N".to_vec()));
        let good = vec![7u8; PACKED_HEADER_LEN + 1];
        set_statuses_in(&mut fields, std::slice::from_ref(&good)).unwrap();
        assert!(retichat_field::top_level(&fields, 0xA0).is_some(), "the old field stays");
        assert!(matches!(retichat_field::read_entry(&fields, 0), Some(Value::Binary(_))), "the name stays");
        assert_eq!(retichat_field::read_entry(&fields, RF_GROUP_STATUSES), Some(&Value::Array(vec![Value::Binary(good.clone())])));
        // Too short to hold a payload, or over the limit: refused, and nothing changes.
        let before = encode(&fields);
        assert!(set_statuses_in(&mut fields, &[vec![0u8; PACKED_HEADER_LEN]]).is_err());
        assert!(set_statuses_in(&mut fields, &[good.clone(), vec![0u8; STATUS_PACKED_LIMIT + 1]]).is_err());
        assert_eq!(before, encode(&fields));
        assert!(set_statuses_in(&mut fields, &[vec![0u8; STATUS_PACKED_LIMIT]]).is_ok());
    }

    #[test]
    fn an_element_outside_the_size_of_an_accept_or_leave_is_not_unpacked() {
        assert!(unpack_element(&[0u8; PACKED_HEADER_LEN]).is_err());
        assert!(unpack_element(&vec![0u8; STATUS_PACKED_LIMIT + 1]).is_err());
        assert!(unpack_element(&vec![0xc1u8; PACKED_HEADER_LEN + 20]).is_err(), "not msgpack");
        assert!(unpack_element(&[]).is_err());
    }

    /// The unpack result for the first vector message, pinned to one literal: Swift's
    /// `GroupStatusJniContractTest` parses the very same bytes, so a writer and a reader that
    /// drift apart cannot both pass. Alice's accept verifies whether or not her key is held, and
    /// carries it, so the bytes are the same in every state of the identity store.
    const ELEMENT_HEX: &str = "0001727e215e19daf66bf647e96143a22117315f18700c02eab7992d9c2ee50374e2a7fea02b1dd94ea73fd11703b1457433b358d68d9d7ba707a320a0659f40b05241daac4ee0a00000c8de11a32801ffcf9761b8e3a1689eb1ebdc1a5b8191e610aea8b7134a9a53712852128a569309197de73a28fa5acdb41cee640031f5122194437016a6ac0119000000d681ccd18500c405416c69636501d920356537316163326430623163346636653961336438653766366335623461333904a661636365707405d920333135663138373030633032656162373939326439633265653530333734653209d97933313566313837303063303265616237393932643963326565353033373465323a794e34526f7967422f382b5859626a6a6f57696573657663476c75426b65595172716933453071615533456f55684b4b56704d4a4758336e4f696a3657733230484f356b4144483145694755513341577071774247513d3d";

    #[test]
    fn the_unpack_buffer_is_exactly_these_bytes_which_swifts_reader_pins_too() {
        let vectors = vectors();
        let message = named(&vectors["messages"], "name", "alice_accept_keyed_retichat");
        let element = unpack_element(&unhex(message["packed_hex"].as_str().unwrap())).unwrap();
        let bytes = encode_element(&element);
        assert_eq!(hex(&bytes), ELEMENT_HEX);
        // The layout, read back by hand from the table in `encode_element`.
        assert_eq!(bytes[0], 0, "validated");
        assert_eq!(bytes[1], 1, "a bound key follows");
        assert_eq!(hex(&bytes[2..18]), identity_of(&vectors, "creator")["lxmf_delivery_hash_hex"].as_str().unwrap());
        assert_eq!(hex(&bytes[18..34]), identity_of(&vectors, "alice")["lxmf_delivery_hash_hex"].as_str().unwrap());
        assert_eq!(hex(&bytes[34..66]), message["message_hash_hex"].as_str().unwrap());
        assert_eq!(f64::from_bits(u64::from_be_bytes(bytes[66..74].try_into().unwrap())), 1_790_000_002.5);
        assert_eq!(hex(&bytes[74..138]), identity_of(&vectors, "alice")["public_key_hex"].as_str().unwrap());
        let fields_len = u32::from_be_bytes(bytes[138..142].try_into().unwrap()) as usize;
        assert_eq!(&bytes[142..], unhex(message["fields_msgpack_hex"].as_str().unwrap()).as_slice());
        assert_eq!(bytes.len(), 142 + fields_len);
        // Without a key the buffer has no key block.
        let keyless = named(&vectors["messages"], "name", "bob_accept_keyless_legacy");
        let keyless = encode_element(&unpack_element(&unhex(keyless["packed_hex"].as_str().unwrap())).unwrap());
        assert_eq!(keyless[1], 0);
        assert_eq!(keyless.len(), 74 + 4 + u32::from_be_bytes(keyless[74..78].try_into().unwrap()) as usize);
    }

    // ── messages made here: a stamp, an invite, a message over the limit, a key never remembered ──

    /// A signed accept from a fresh identity to a fresh destination: its packed bytes and the sender's key
    /// entry, with `carried` as the GROUP_MEMBER_KEYS entry (None: none), the entries in the old fields.
    fn made(action: &str, content: &str, carried: impl Fn(&Identity, &[u8]) -> Option<String>) -> (Vec<u8>, Identity, Vec<u8>) {
        let sender = Identity::new(true);
        let source = Destination::new_inbound(
            Some(sender.clone()),
            DestinationType::Single,
            "lxmf".to_string(),
            vec!["delivery".to_string()],
        )
        .unwrap();
        let to = Identity::new(true);
        let destination = Destination::new_outbound(Some(to), DestinationType::Single, "lxmf".to_string(), vec!["delivery".to_string()]).unwrap();
        let mut msg = LXMessage::new(
            None,
            Some(source.clone()),
            Some(content.as_bytes().to_vec()),
            Some(Vec::new()),
            None,
            Some(LXMessage::DIRECT),
            Some(destination.hash.clone()),
            Some(source.hash.clone()),
            None,
            false,
        )
        .unwrap();
        let mut fields = Value::Map(Vec::new());
        for (key, value) in [(RF_GROUP_ID, "5e71ac2d0b1c4f6e9a3d8e7f6c5b4a39".to_string()), (RF_GROUP_ACTION, action.to_string()),
                             (retichat_field::RF_GROUP_SENDER, hex(&source.hash))] {
            retichat_field::set_group_entry_as(&mut fields, key, &GroupValue::Str(value), false).unwrap();
        }
        if let Some(entry) = carried(&sender, &source.hash) {
            retichat_field::set_group_entry_as(&mut fields, RF_GROUP_MEMBER_KEYS, &GroupValue::Str(entry), false).unwrap();
        }
        msg.fields = fields;
        msg.pack(false).unwrap();
        (msg.packed.clone().unwrap(), sender, source.hash.clone())
    }

    fn own_entry(identity: &Identity, hash: &[u8]) -> Option<String> {
        Some(format!("{}:{}", hex(hash), KEY_B64.encode(identity.get_public_key().unwrap())))
    }

    #[test]
    fn a_stamped_accept_is_verified_under_its_carried_key_like_any_other_the_stamp_is_not_signed() {
        let (packed, _sender, _hash) = made("accept", "", own_entry);
        // A fifth payload element, as the stamp LXMF appends after signing.
        let mut payload = rmpv::decode::read_value(&mut Cursor::new(&packed[PACKED_HEADER_LEN..])).unwrap();
        if let Value::Array(items) = &mut payload {
            assert_eq!(items.len(), 4);
            items.push(Value::Binary(vec![9u8; 32]));
        }
        let mut stamped = packed[..PACKED_HEADER_LEN].to_vec();
        stamped.extend_from_slice(&encode(&payload));
        let element = unpack_element(&stamped).unwrap();
        assert_eq!(verdict_name(&element.receipt), "verified");
        assert!(element.receipt.sender_key.is_some());
        assert_eq!(element.receipt.packed.as_deref(), Some(stamped.as_slice()), "the stamp stays in the copy, as received");
    }

    #[test]
    fn a_forged_accept_is_invalid_under_its_carried_key_and_a_message_that_is_not_an_accept_or_leave_is_left_alone() {
        // Another identity's signature under this one's name and key.
        let (mut packed, _sender, _hash) = made("accept", "", own_entry);
        packed[PACKED_HEADER_LEN - 1] ^= 0x01;
        assert_eq!(verdict_name(&unpack_element(&packed).unwrap().receipt), "forged");
        // An invite carrying a key that binds to its source decides nothing for it: the router's verdict stands.
        let (invite, _sender, _hash) = made("invite", "", own_entry);
        let element = unpack_element(&invite).unwrap();
        assert_eq!(element.receipt, Receipt { validated: false, unverified_reason: SOURCE_UNKNOWN, sender_key: None, packed: None });
        // A plain message, a relay and a status likewise.
        for action in ["relay_req", "relay_done", "status"] {
            let (packed, _s, _h) = made(action, "", own_entry);
            let element = unpack_element(&packed).unwrap();
            assert_eq!((element.receipt.unverified_reason, element.receipt.sender_key, element.receipt.packed), (SOURCE_UNKNOWN, None, None), "{action}");
        }
    }

    #[test]
    fn the_key_a_message_carries_is_never_remembered_here() {
        let (packed, _sender, hash) = made("leave", "", own_entry);
        let element = unpack_element(&packed).unwrap();
        assert_eq!(verdict_name(&element.receipt), "verified");
        assert!(element.receipt.sender_key.is_some());
        assert!(Identity::recall(&hash).is_none(), "Swift remembers it, after the group rule has passed");
    }

    #[test]
    fn an_entry_for_another_hash_or_a_malformed_one_is_no_key() {
        let other = Identity::new(true);
        let other_hash = vec![0x42u8; 16];
        let (packed, _s, _h) = made("accept", "", |_, _| own_entry(&other, &other_hash));
        let receipt = unpack_element(&packed).unwrap().receipt;
        assert_eq!((receipt.unverified_reason, receipt.sender_key), (SOURCE_UNKNOWN, None), "an entry for someone else's hash is ignored");
        for bad in ["", ":", "nothex:AAAA", "zz:AA", "0123"] {
            let (packed, _s, _h) = made("accept", "", |_, _| Some(bad.to_string()));
            let receipt = unpack_element(&packed).unwrap().receipt;
            assert_eq!((receipt.unverified_reason, receipt.sender_key.is_none()), (SOURCE_UNKNOWN, true), "{bad:?}");
        }
        // A short key under the right hash, in the right form of base64, binds to nothing.
        let (packed, _s, _h) = made("accept", "", |_, hash| Some(format!("{}:{}", hex(hash), KEY_B64.encode([5u8; 63]))));
        assert!(unpack_element(&packed).unwrap().receipt.sender_key.is_none());
        // Several entries, one the sender's: that one is the key, wherever it stands in the list.
        let (packed, _s, _h) = made("accept", "", |sender, hash| {
            Some(format!("{},{},{}", own_entry(&other, &other_hash).unwrap(), own_entry(sender, hash).unwrap(), "x:y"))
        });
        let receipt = unpack_element(&packed).unwrap().receipt;
        assert_eq!(verdict_name(&receipt), "verified");
    }

    #[test]
    fn a_message_over_the_limit_is_judged_but_no_copy_of_it_is_given() {
        let (packed, _sender, _hash) = made("accept", &"x".repeat(STATUS_PAYLOAD_LIMIT + 100), own_entry);
        assert!(packed.len() > STATUS_PACKED_LIMIT);
        // unpack_element refuses its size; the router's receipt of it is judged, with no copy.
        assert!(unpack_element(&packed).is_err());
        let msg = LXMessage::unpack_from_bytes(&packed, None).unwrap();
        let reason = msg.unverified_reason.unwrap();
        let receipt = receipt(&msg, msg.signature_validated, reason);
        assert_eq!((receipt.validated, receipt.unverified_reason), (true, VALIDATED), "still verified by its carried key");
        assert!(receipt.sender_key.is_some());
        assert!(receipt.packed.is_none(), "a copy over {STATUS_PACKED_LIMIT} bytes is not kept");
    }

    #[test]
    fn a_held_key_decides_whatever_the_message_carries() {
        let (packed, sender, hash) = made("accept", "", own_entry);
        // The router holds this sender's key: validated under it, and the carried key is reported all the same.
        let held = |h: &[u8]| (h == hash.as_slice()).then(|| Identity::from_public_key(&sender.get_public_key().unwrap()).unwrap());
        let element = unpack_element_with(&packed, &held).unwrap();
        assert_eq!(verdict_name(&element.receipt), "verified");
        assert!(element.receipt.sender_key.is_some());
        // A keyless accept from a sender whose key is held is verified too.
        let (keyless, sender2, hash2) = made("accept", "", |_, _| None);
        let held2 = |h: &[u8]| (h == hash2.as_slice()).then(|| Identity::from_public_key(&sender2.get_public_key().unwrap()).unwrap());
        let element = unpack_element_with(&keyless, &held2).unwrap();
        assert_eq!((verdict_name(&element.receipt), element.receipt.sender_key), ("verified", None));
        // Held under another sender's key, a message is forged whatever it carries.
        let other = Identity::new(true);
        let wrong = |h: &[u8]| (h == hash.as_slice()).then(|| Identity::from_public_key(&other.get_public_key().unwrap()).unwrap());
        assert_eq!(verdict_name(&unpack_element_with(&packed, &wrong).unwrap().receipt), "forged");
    }

    #[test]
    fn the_element_list_swift_hands_over_is_read_exactly_or_refused() {
        let list = vec![vec![1u8, 2, 3], vec![], vec![9u8; 300]];
        let flat = encode_elements(&list);
        assert_eq!(&flat[..8], &[0, 0, 0, 3, 0, 0, 0, 3]);
        assert_eq!(decode_elements(&flat).unwrap(), list);
        assert_eq!(decode_elements(&encode_elements(&[])).unwrap(), Vec::<Vec<u8>>::new(), "an empty list is an answer");
        assert!(decode_elements(&[]).is_err(), "no count");
        assert!(decode_elements(&[0, 0, 0, 1]).is_err(), "a count with no element");
        assert!(decode_elements(&[0, 0, 0, 1, 0, 0, 0, 5, 1, 2]).is_err(), "an element past the end");
        assert!(decode_elements(&[0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0]).is_err(), "a count the buffer cannot hold");
        let mut extra = flat.clone();
        extra.push(0);
        assert!(decode_elements(&extra).is_err(), "bytes after the last element");
        let mut short = flat.clone();
        short.pop();
        assert!(decode_elements(&short).is_err(), "a last element that stops short");
    }
}

/// GROUPS-DISTRO-DESIGN.md §7, §17.2, §19.1: the distro unwrap runs this crate's group receipt,
/// checked against LXMF-rust's group sync vectors (`tests/data/distro_group_sync_vectors.json`,
/// made with the Python reference by LXMF-rust `tests/distro_group_sync_vectors.py`).
#[cfg(test)]
mod distro_unwrap_tests {
    use super::*;
    use serde_json::Value as Json;

    const VECTORS: &str = include_str!("../tests/data/distro_group_sync_vectors.json");

    fn vectors() -> Json {
        serde_json::from_str(VECTORS).expect("the vectors are JSON")
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
    }

    fn distro(v: &Json) -> Identity {
        Identity::from_bytes(&unhex(v["distro"]["private_key_hex"].as_str().unwrap())).unwrap()
    }

    /// The copy here is LXMF-rust's own file: its working tree's once the vectors are merged there,
    /// else the one committed on its `group-distro` branch. Neither found fails the test rather
    /// than skipping it: a skipped contract check reads as a pass.
    #[test]
    fn the_copy_of_the_group_sync_vectors_here_is_the_one_lxmf_rust_has() {
        let lxmf = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../LXMF-rust");
        let tree = lxmf.join("tests/distro_group_sync_vectors.json");
        let theirs = if tree.exists() {
            std::fs::read_to_string(&tree).expect("LXMF-rust's vectors are readable")
        } else {
            let shown = std::process::Command::new("git")
                .arg("-C")
                .arg(&lxmf)
                .args(["show", "group-distro:tests/distro_group_sync_vectors.json"])
                .output()
                .expect("git runs");
            assert!(shown.status.success(), "the vectors are in neither {} nor LXMF-rust's group-distro branch", tree.display());
            String::from_utf8(shown.stdout).expect("the vectors are UTF-8")
        };
        assert_eq!(theirs, VECTORS, "tests/data/distro_group_sync_vectors.json is not LXMF-rust's: copy it again");
    }

    /// Every sealed vector: the unwrap's hash and group keys, and the receipt's key, packed copy
    /// and verdict. M is not known here; nothing is remembered.
    #[test]
    fn the_distro_unwrap_reports_the_group_receipts_key_packed_copy_and_verdict() {
        let v = vectors();
        let mut d = distro(&v);
        let member = unhex(v["member"]["lxmf_delivery_hash_hex"].as_str().unwrap());
        assert!(Identity::recall(&member).is_none(), "M is unknown here");
        let sealed = v["sealed"].as_array().unwrap();
        // g_accept_web_form_int64_at_ms is the web's G (at_ms as int 64, 0xd3): not the form rmpv
        // packs, so it holds the unwrap to §17.14 rule 2, the hash and the signature over the
        // payload bytes as received; packing it again would give another hash and fail D's signature.
        let names: Vec<&str> = sealed.iter().map(|s| s["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            [
                "g_accept_full_left",
                "g_accept_web_form_int64_at_ms",
                "member_accept_legacy",
                "member_accept_forged",
                "member_invite_retichat_field",
                "member_post_legacy"
            ]
        );
        for vector in sealed {
            let name = vector["name"].as_str().unwrap();
            let expected = &vector["expected"];
            let json = distro_unwrap_json(&mut d, &unhex(vector["blob_hex"].as_str().unwrap())).unwrap().expect("a blob for D");
            let out: Json = serde_json::from_str(&json).unwrap();
            assert_eq!(out["hash"], vector["hash_hex"], "{name}: hash");
            assert_eq!(out["sender_key"], expected["sender_key_hex"], "{name}: sender_key");
            if expected["packed"].as_bool().unwrap() {
                let packed = base64::engine::general_purpose::STANDARD.decode(out["packed"].as_str().unwrap()).unwrap();
                assert_eq!(packed, unhex(vector["packed_hex"].as_str().unwrap()), "{name}: packed");
            } else {
                assert!(out["packed"].is_null(), "{name}: packed");
            }
            assert_eq!(out["signature_validated"], expected["signature_validated"], "{name}");
            assert_eq!(out["unverified_reason"], expected["unverified_reason"], "{name}");
            for key in ["has_group_id", "group_id", "group_action", "group_name", "group_sync"] {
                assert_eq!(out[key], expected[key], "{name}: {key}");
            }
        }
        assert!(Identity::recall(&member).is_none(), "the app remembers M's key, after its group rule passes");
        // A blob for another distro is no message.
        let blob = unhex(sealed[1]["blob_hex"].as_str().unwrap());
        assert_eq!(distro_unwrap_json(&mut Identity::new(true), &blob).unwrap(), None);
    }

    /// `receipt_parts` is `receipt` on the parts of the message the router would have unpacked.
    #[test]
    fn receipt_parts_is_receipt_on_the_parts() {
        let v = vectors();
        for vector in v["sealed"].as_array().unwrap() {
            let name = vector["name"].as_str().unwrap();
            let packed = unhex(vector["packed_hex"].as_str().unwrap());
            let msg = LXMessage::unpack_from_bytes(&packed, None).unwrap();
            for (validated, reason) in [(false, SOURCE_UNKNOWN), (true, VALIDATED), (false, SIGNATURE_INVALID)] {
                assert_eq!(
                    receipt_parts(&msg.fields, &msg.source_hash, &packed, validated, reason),
                    receipt(&msg, validated, reason),
                    "{name} {reason}"
                );
            }
        }
    }

    /// Every `group_entries` vector through the distro unwrap the app calls: a blob to D from a
    /// fresh sender carrying the vector's fields map exactly as given (a repeated key, an ext of an
    /// unknown type, a bin GROUP_ID) reports the entries LXMF-rust reads (RFed SPEC §17.14
    /// "Repeated keys": a group entry from the first entry with its key, 0xFB from the last).
    #[test]
    fn the_distro_unwrap_reads_each_group_entries_vector_as_lxmf_rust_does() {
        let v = vectors();
        let mut d = distro(&v);
        let dest = lxmf_rust::distro::delivery_hash(&d).unwrap();
        let entries = v["group_entries"].as_array().unwrap();
        for name in ["group_id_twice_the_first_malformed", "ext_beside_group_id", "custom_type_twice_the_last_a_marker"] {
            assert!(entries.iter().any(|e| e["name"] == name), "{name} is in the vectors");
        }
        for vector in entries {
            let name = vector["name"].as_str().unwrap();
            let expected = &vector["expected"];
            let sender = Identity::new(true);
            let src = lxmf_rust::distro::delivery_hash(&sender).unwrap();
            // [timestamp 1790000000.5, bin title "", bin content "x", the fields as given]
            let mut payload = unhex("94cb41daac4ee0200000c400c40178");
            payload.extend_from_slice(&unhex(vector["fields_hex"].as_str().unwrap()));
            let mut signed = [dest.clone(), src.clone(), payload.clone()].concat();
            let hash = identity::full_hash(&signed);
            signed.extend_from_slice(&hash);
            let signature = sender.sign(&signed);
            let blob = [dest.clone(), d.encrypt(&[src, signature, payload].concat()).unwrap()].concat();
            let out: Json = serde_json::from_str(&distro_unwrap_json(&mut d, &blob).unwrap().expect("a blob for D")).unwrap();
            for key in ["has_group_id", "group_id", "group_action", "group_name"] {
                assert_eq!(out[key], expected[key], "{name}: {key}");
            }
            assert_eq!(!out["group_sync"].is_null(), expected["group_sync"].as_bool().unwrap(), "{name}: group_sync");
        }
    }
}
