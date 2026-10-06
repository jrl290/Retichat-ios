//! What a device owes its distro (RFed-rust SPEC.md §17.12 "On the sending
//! device", §17.11): the pure parts of building and uploading it, kept apart
//! from the C wrappers in `lib.rs` so `cargo test` runs them without a stack.
//! The same code as Retichat-android's `rust/retichat-jni/src/distro_outbox.rs`
//! (the two glue crates are separate, the LXMF messages they make must not be).
//!
//! The Swift outbox (`Retichat/Services/DistroOutbox.swift`) keeps what is owed
//! and decides when to upload; this module does only what Swift cannot:
//!
//! * [`set_channel_sync_fields`]: C's fields, the membership message of §17.12.
//!   The generic field setters write str and bool only, and 0xFC is an array.
//! * [`pack_message`]: pack and sign a message once. What Swift keeps is that
//!   message, never packed again.
//! * [`build_propagation_upload`]: the upload of a packed message, encrypted to
//!   its distro's key and stamped for the propagation node, as
//!   `LXMessage::pack` builds `propagation_packed` for a PROPAGATED message.
//!   Built anew for every upload from the same packed message.

use std::sync::{Arc, Mutex};

use lxmf_rust::lx_message::LXMessage;
use lxmf_rust::lx_stamper::{generate_stamp, WORKBLOCK_EXPAND_ROUNDS_PN};
use reticulum_rust::destination::{Destination, DestinationType};
use reticulum_rust::identity::{self, Identity};
use rmpv::Value;

/// `FIELD_TICKET`: an empty bin in C, so that clients older than §17.12 take C
/// for a delivery notification and drop it. It is no ticket.
const FIELD_TICKET: u8 = 0x0C;
const FIELD_CUSTOM_TYPE: u8 = 0xFB;
const FIELD_CUSTOM_DATA: u8 = 0xFC;
const FIELD_CUSTOM_META: u8 = 0xFD;

/// The `FIELD_CUSTOM_TYPE` of a membership message.
pub const DISTRO_CHANNEL_TYPE: &str = "rfed.distro.channel";

/// `at_ms` is bounded at 2^53 - 1 on every client (§17.12 "`at_ms` on the wire").
pub const MAX_AT_MS: u64 = (1u64 << 53) - 1;

/// LXMF's destination hash and source hash lengths, the signature, and so the
/// shortest packed message that has a payload at all.
const DEST_LEN: usize = 16;
const LXMF_HEADER_LEN: usize = 16 + 16 + 64;

/// A stamp cost above this is not one a node means: it would be mined for
/// ever. (Costs are leading-zero bits of a SHA-256: LXMF's own are below 40.)
const MAX_STAMP_COST: i64 = 255;

/// Write C's fields on `msg`, as §17.12's table gives them:
///
/// | field | value |
/// |---|---|
/// | 0x0C | an empty bin |
/// | 0xFB | the str `"rfed.distro.channel"` |
/// | 0xFC | the native array `[op, name, at_ms]`: `op` the str `"join"` or `"leave"`, `name` the channel's full name, `at_ms` an integer |
/// | 0xFD | the sending device's own `lxmf.delivery` address, 32 lowercase hex |
///
/// `at_ms` is a `Value::from(u64)`, which rmpv packs as uint 64 (0xcf) for any
/// time after 1970-02-19; the web writes int 64 (0xd3), and every reader takes
/// both (CHECK_THESE_THINGS_FIRST §11: the array is native, never a bin of
/// packed msgpack). No 0xD1: C is a message to one's own devices and carries no
/// Message Display Name.
pub fn set_channel_sync_fields(
    msg: &mut LXMessage,
    op: &str,
    name: &str,
    at_ms: u64,
    device_hex: &str,
) -> Result<(), String> {
    if op != "join" && op != "leave" {
        return Err(format!("a membership action is \"join\" or \"leave\", not {op:?}"));
    }
    if name.is_empty() {
        return Err("a membership message names its channel".to_string());
    }
    if at_ms > MAX_AT_MS {
        return Err(format!("at_ms {at_ms} is above 2^53 - 1"));
    }
    if device_hex.len() != 32 || !device_hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("0xFD is the sending device's own lxmf.delivery address, 32 hex characters".to_string());
    }
    msg.set_field(FIELD_TICKET, Value::Binary(Vec::new()));
    msg.set_field(FIELD_CUSTOM_TYPE, Value::String(DISTRO_CHANNEL_TYPE.into()));
    msg.set_field(
        FIELD_CUSTOM_DATA,
        Value::Array(vec![Value::String(op.into()), Value::String(name.into()), Value::from(at_ms)]),
    );
    msg.set_field(FIELD_CUSTOM_META, Value::String(device_hex.to_ascii_lowercase().into()));
    Ok(())
}

/// Pack and sign the message behind `msg` once, and return its packed bytes:
/// `dest(16) | src(16) | signature(64) | msgpack payload`. A message already
/// packed returns the bytes it was packed to; nothing is ever packed again, so
/// every upload of it is one and the same LXMF message (its hash does not
/// change). The message's hash is then `LXMessage::hash`.
pub fn pack_message(msg: &Arc<Mutex<LXMessage>>) -> Result<Vec<u8>, String> {
    let mut msg = msg.lock().map_err(|e| e.to_string())?;
    if msg.packed.is_none() {
        msg.pack(false)?;
    }
    msg.packed.clone().ok_or_else(|| "the message packed to nothing".to_string())
}

/// The stamp cost a propagation node asks of an upload, from its announce's
/// `app_data` (LXMF `get_outbound_propagation_cost`): the first of the stamp
/// cost array, element 5. An `Err` says why none is known: the node's announce
/// has not been heard, or carries no valid cost.
pub fn node_stamp_cost(app_data: Option<&[u8]>) -> Result<u32, String> {
    match lxmf_rust::lxmf::pn_stamp_cost_from_app_data(app_data) {
        Some(cost) if (0..=MAX_STAMP_COST).contains(&cost) => Ok(cost as u32),
        Some(cost) => Err(format!("the propagation node asks a stamp cost of {cost}, which is not one")),
        None => Err("the propagation node's stamp cost is not known: its announce has not been heard".to_string()),
    }
}

/// Build the propagation upload of `packed` (a message D packed and signed,
/// `dest | src | signature | payload`): the encrypted body for D's key
/// `distro_public_key`, stamped for the node at `stamp_cost`, and wrapped as the
/// node reads it, `msgpack([timestamp_f64, [lxmf_data]])` with
/// `lxmf_data = dest | encrypted | stamp(32)` (LXMF `LXMessage.pack`,
/// PROPAGATED). The LXMF message inside is `packed` unchanged; the encryption
/// uses a fresh ephemeral key and the stamp is mined anew each time, so no two
/// uploads of one message are the same bytes, and the node and the siblings tell
/// them apart by what they carry, not by how it was wrapped.
///
/// It is encrypted to `distro_public_key` and to no other key: the key must
/// produce `packed`'s own destination hash. A sent-copy still owed to a distro
/// the device has given up is built with that distro's key, never the one held
/// now. Fails, with nothing left, when the key is wrong or short, the
/// encryption fails, or the stamp cannot be mined.
pub fn build_propagation_upload(distro_public_key: &[u8], packed: &[u8], stamp_cost: u32) -> Result<Vec<u8>, String> {
    if packed.len() < LXMF_HEADER_LEN {
        return Err(format!("a packed LXMF message is at least {LXMF_HEADER_LEN} bytes, this is {}", packed.len()));
    }
    let recipient = Identity::from_public_key(distro_public_key)?;
    let destination = Destination::new_outbound(
        Some(recipient.clone()),
        DestinationType::Single,
        "lxmf".to_string(),
        vec!["delivery".to_string()],
    )?;
    let dest = &packed[..DEST_LEN];
    if destination.hash != dest {
        return Err("the distro's key does not produce the message's destination".to_string());
    }
    let encrypted = recipient.encrypt(&packed[DEST_LEN..])?;
    let mut lxmf_data = Vec::with_capacity(DEST_LEN + encrypted.len() + 32);
    lxmf_data.extend_from_slice(dest);
    lxmf_data.extend_from_slice(&encrypted);
    // The transient id is the hash of what the node stores, before the stamp.
    let transient_id = identity::full_hash(&lxmf_data);
    let (stamp, _value) = generate_stamp(&transient_id, stamp_cost, WORKBLOCK_EXPAND_ROUNDS_PN);
    let stamp = stamp.ok_or_else(|| format!("the propagation stamp (cost {stamp_cost}) could not be generated"))?;
    lxmf_data.extend_from_slice(&stamp);
    Ok(propagation_payload(now_seconds(), &lxmf_data))
}

/// `msgpack([timestamp_f64, [bin(lxmf_data)]])`, written by hand: the node
/// reads a native array of an f64 and an array of one bin (CHECK_THESE_THINGS_FIRST §11).
pub fn propagation_payload(timestamp: f64, lxmf_data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(lxmf_data.len() + 16);
    out.push(0x92);
    out.push(0xcb);
    out.extend_from_slice(&timestamp.to_bits().to_be_bytes());
    out.push(0x91);
    let len = lxmf_data.len();
    if len <= 0xff {
        out.extend_from_slice(&[0xc4, len as u8]);
    } else if len <= 0xffff {
        out.push(0xc5);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(0xc6);
        out.extend_from_slice(&(len as u32).to_be_bytes());
    }
    out.extend_from_slice(lxmf_data);
    out
}

fn now_seconds() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lxmf_rust::distro::unwrap_blob;

    /// A distro identity, its `lxmf.delivery` hash and a message from it to itself.
    fn distro_message(content: &str) -> (Identity, Vec<u8>, LXMessage) {
        let distro = Identity::new(true);
        let source = Destination::new_inbound(
            Some(distro.clone()),
            DestinationType::Single,
            "lxmf".to_string(),
            vec!["delivery".to_string()],
        )
        .expect("source destination");
        let hash = source.hash.clone();
        let msg = LXMessage::new(
            None,
            Some(source),
            Some(content.as_bytes().to_vec()),
            Some(Vec::new()),
            None,
            Some(LXMessage::DIRECT),
            Some(hash.clone()),
            Some(hash.clone()),
            None,
            false,
        )
        .expect("message");
        (distro, hash, msg)
    }

    const DEVICE: &str = "0123456789abcdef0123456789abcdef";

    /// The fields map of C written out by hand from §17.12's table: fixmap of
    /// four, `0x0C: bin(0)`, `0xFB: str`, `0xFC: array of three with at_ms as
    /// uint 64`, `0xFD: str(32)`. Keys over 0x7f are uint 8, as rmpv writes them.
    fn expected_fields(op: &str, name: &str, at_ms: u64, device: &str) -> Vec<u8> {
        let mut out = vec![0x84];
        out.extend_from_slice(&[0x0c, 0xc4, 0x00]);
        out.extend_from_slice(&[0xcc, 0xfb, 0xa0 | DISTRO_CHANNEL_TYPE.len() as u8]);
        out.extend_from_slice(DISTRO_CHANNEL_TYPE.as_bytes());
        out.extend_from_slice(&[0xcc, 0xfc, 0x93]);
        out.push(0xa0 | op.len() as u8);
        out.extend_from_slice(op.as_bytes());
        assert!(name.len() < 32);
        out.push(0xa0 | name.len() as u8);
        out.extend_from_slice(name.as_bytes());
        out.push(0xcf);
        out.extend_from_slice(&at_ms.to_be_bytes());
        out.extend_from_slice(&[0xcc, 0xfd, 0xd9, device.len() as u8]);
        out.extend_from_slice(device.as_bytes());
        out
    }

    /// The fields map of a packed message: element 3 of the payload array, as bytes.
    fn fields_of(packed: &[u8]) -> Vec<u8> {
        let payload = &packed[LXMF_HEADER_LEN..];
        assert_eq!(payload[0], 0x94, "the payload is an array of four");
        let mut rd = &payload[1..];
        for _ in 0..3 {
            rmpv::decode::read_value_ref(&mut rd).unwrap();
        }
        let start = payload.len() - rd.len();
        rmpv::decode::read_value_ref(&mut rd).unwrap();
        payload[start..payload.len() - rd.len()].to_vec()
    }

    #[test]
    fn c_is_written_as_the_spec_table_gives_it() {
        let (_distro, _hash, mut msg) = distro_message("");
        set_channel_sync_fields(&mut msg, "join", "public.general", 1_767_225_600_000, DEVICE).unwrap();
        let msg = Arc::new(Mutex::new(msg));
        let packed = pack_message(&msg).unwrap();
        assert_eq!(
            fields_of(&packed),
            expected_fields("join", "public.general", 1_767_225_600_000, DEVICE),
            "0x0C an empty bin, 0xFB a str, 0xFC a NATIVE array of op, name and uint 64 at_ms, 0xFD a str"
        );
    }

    /// The bytes of C's fields for join, `public.general`, 2026-01-01 00:00 UTC and `DEVICE`, written out
    /// as hex. The same literal is pinned on the reading side (Swift `tests/DistroChannelSyncTests.swift`
    /// and Kotlin `DistroChannelSyncTest`), so a writer and a reader that drift apart cannot both pass.
    const C_FIELDS_HEX: &str = "840cc400ccfbb3726665642e64697374726f2e6368616e6e656cccfc93a46a6f696eae7075626c69632e67656e6572616ccf0000019b76daa800ccfdd9203031323334353637383961626364656630313233343536373839616263646566";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn c_is_exactly_these_bytes_which_the_phones_reader_pins_too() {
        let (_d, _h, mut msg) = distro_message("");
        set_channel_sync_fields(&mut msg, "join", "public.general", 1_767_225_600_000, DEVICE).unwrap();
        let packed = pack_message(&Arc::new(Mutex::new(msg))).unwrap();
        assert_eq!(hex(&fields_of(&packed)), C_FIELDS_HEX);
    }

    #[test]
    fn at_ms_goes_as_uint64_for_a_real_time_and_the_array_is_never_a_bin() {
        let (_d, _h, mut msg) = distro_message("");
        set_channel_sync_fields(&mut msg, "leave", "0123456789abcdef.team", 1_767_225_600_000, DEVICE).unwrap();
        let packed = pack_message(&Arc::new(Mutex::new(msg))).unwrap();
        let fields = fields_of(&packed);
        // 2026-01-01 00:00 UTC is cf 00 00 01 9b 76 da a8 00 (§17.12), the type rmpv writes.
        let at: &[u8] = &[0xcf, 0x00, 0x00, 0x01, 0x9b, 0x76, 0xda, 0xa8, 0x00];
        assert!(fields.windows(at.len()).any(|w| w == at));
        // The 0xFC value starts with the array head 0x93, never a bin head (0xc4..0xc6).
        let pos = fields.windows(2).position(|w| w == [0xcc, 0xfc]).unwrap();
        assert_eq!(fields[pos + 2], 0x93);
    }

    #[test]
    fn c_is_refused_when_it_is_malformed() {
        let (_d, _h, mut msg) = distro_message("");
        assert!(set_channel_sync_fields(&mut msg, "Join", "public.x", 1, DEVICE).is_err());
        assert!(set_channel_sync_fields(&mut msg, "join", "", 1, DEVICE).is_err());
        assert!(set_channel_sync_fields(&mut msg, "join", "public.x", MAX_AT_MS + 1, DEVICE).is_err());
        assert!(set_channel_sync_fields(&mut msg, "join", "public.x", 1, "xyz").is_err());
        assert!(set_channel_sync_fields(&mut msg, "join", "public.x", 1, &"g".repeat(32)).is_err());
        // Nothing was written by a refused call.
        assert!(!msg.get_fields().as_map().map(|m| m.iter().any(|(k, _)| k.as_u64() == Some(0xFC))).unwrap_or(false));
        // 2^53 - 1 is the last at_ms there is.
        assert!(set_channel_sync_fields(&mut msg, "join", "public.x", MAX_AT_MS, DEVICE).is_ok());
    }

    #[test]
    fn the_device_address_is_written_lowercase() {
        let (_d, _h, mut msg) = distro_message("");
        set_channel_sync_fields(&mut msg, "join", "public.x", 1, &DEVICE.to_ascii_uppercase()).unwrap();
        let packed = pack_message(&Arc::new(Mutex::new(msg))).unwrap();
        let fields = fields_of(&packed);
        assert!(fields.windows(32).any(|w| w == DEVICE.as_bytes()));
    }

    #[test]
    fn a_message_is_packed_once_and_every_call_returns_the_same_bytes() {
        let (_d, _h, mut msg) = distro_message("hello");
        set_channel_sync_fields(&mut msg, "join", "public.x", 5, DEVICE).unwrap();
        let msg = Arc::new(Mutex::new(msg));
        let first = pack_message(&msg).unwrap();
        let hash = msg.lock().unwrap().hash.clone().unwrap();
        let second = pack_message(&msg).unwrap();
        assert_eq!(first, second, "never packed again");
        assert_eq!(hash, msg.lock().unwrap().hash.clone().unwrap());
        // dest | src | signature | payload, and the hash is SHA-256 of dest | src | payload.
        let mut hashed = first[..32].to_vec();
        hashed.extend_from_slice(&first[LXMF_HEADER_LEN..]);
        assert_eq!(identity::full_hash(&hashed), hash);
    }

    /// A node's announce `app_data`: `[name, timebase, active, limit, sync limit, [cost, ...], {}]`.
    fn node_app_data(cost: i64) -> Vec<u8> {
        let value = Value::Array(vec![
            Value::Nil,
            Value::from(1_767_225_600),
            Value::Boolean(true),
            Value::from(256),
            Value::from(10_240),
            Value::Array(vec![Value::from(cost), Value::from(3), Value::from(18)]),
            Value::Map(Vec::new()),
        ]);
        let mut out = Vec::new();
        rmpv::encode::write_value(&mut out, &value).unwrap();
        out
    }

    #[test]
    fn the_nodes_stamp_cost_is_read_from_its_announce() {
        assert_eq!(node_stamp_cost(Some(&node_app_data(0))), Ok(0));
        assert_eq!(node_stamp_cost(Some(&node_app_data(16))), Ok(16));
        assert!(node_stamp_cost(None).unwrap_err().contains("not known"));
        assert!(node_stamp_cost(Some(&[])).is_err());
        // Not a propagation node's announce.
        assert!(node_stamp_cost(Some(&[0x90])).is_err());
        assert!(node_stamp_cost(Some(&node_app_data(1000))).unwrap_err().contains("not one"));
        assert!(node_stamp_cost(Some(&node_app_data(-1))).is_err());
    }

    /// The `lxmf_data` of an upload: `dest | encrypted | stamp(32)`, from its wrapper.
    fn lxmf_data_of(upload: &[u8]) -> (f64, Vec<u8>) {
        assert_eq!(upload[0], 0x92, "a native array of two");
        assert_eq!(upload[1], 0xcb, "an f64 timestamp");
        let ts = f64::from_bits(u64::from_be_bytes(upload[2..10].try_into().unwrap()));
        assert_eq!(upload[10], 0x91, "an array of one blob");
        let (len, start) = match upload[11] {
            0xc4 => (upload[12] as usize, 13),
            0xc5 => (u16::from_be_bytes([upload[12], upload[13]]) as usize, 14),
            0xc6 => (u32::from_be_bytes(upload[12..16].try_into().unwrap()) as usize, 16),
            other => panic!("a bin, not {other:#x}"),
        };
        assert_eq!(start + len, upload.len());
        (ts, upload[start..].to_vec())
    }

    #[test]
    fn an_upload_is_the_packed_message_encrypted_to_its_distro_and_stamped() {
        let (distro, hash, mut msg) = distro_message("");
        set_channel_sync_fields(&mut msg, "join", "public.general", 1_767_225_600_000, DEVICE).unwrap();
        let packed = pack_message(&Arc::new(Mutex::new(msg))).unwrap();
        let key = distro.get_public_key().unwrap();

        let cost = 6;
        let upload = build_propagation_upload(&key, &packed, cost).unwrap();
        let (ts, data) = lxmf_data_of(&upload);
        assert!(ts > 1_700_000_000.0);
        assert_eq!(&data[..16], &hash[..], "the node reads dest in the clear at offset 0");
        // The stamp is the last 32 bytes, valid for the node's cost over what precedes it.
        let valid = lxmf_rust::lx_stamper::validate_pn_stamp(&data, cost).expect("a valid stamp for the node's cost");
        assert_eq!(valid.1, data[..data.len() - 32].to_vec());

        // A sibling unwraps it with the distro key: the message inside is the one packed,
        // with a valid distro signature, and it passes for a delivery notification (§17.12).
        let mut holder = distro.clone();
        let unwrapped = unwrap_blob(&mut holder, &data[..data.len() - 32]).unwrap().expect("addressed to the distro");
        assert_eq!(unwrapped.source_hash, hash);
        assert!(unwrapped.signature_validated);
        assert!(unwrapped.is_delivery_notification);
        assert!(unwrapped.content.is_empty());
        assert_eq!(unwrapped.fields.as_deref(), Some(&expected_fields("join", "public.general", 1_767_225_600_000, DEVICE)[..]));
        assert_eq!((unwrapped.sent_to, unwrapped.sent_by), (None, None));
    }

    #[test]
    fn a_free_node_still_gets_a_stamp_and_two_uploads_differ_but_carry_one_message() {
        let (distro, hash, mut msg) = distro_message("sent text");
        let packed = pack_message(&Arc::new(Mutex::new(msg))).unwrap();
        let key = distro.get_public_key().unwrap();
        let a = build_propagation_upload(&key, &packed, 0).unwrap();
        let b = build_propagation_upload(&key, &packed, 0).unwrap();
        assert_ne!(a, b, "a fresh ephemeral key and a fresh stamp each time");
        let (_, da) = lxmf_data_of(&a);
        let (_, db) = lxmf_data_of(&b);
        assert_eq!(da.len(), db.len());
        assert!(da.len() > 16 + 32, "a stamp follows the body even at cost 0");
        let mut holder = distro.clone();
        for data in [&da, &db] {
            let m = unwrap_blob(&mut holder, &data[..data.len() - 32]).unwrap().unwrap();
            assert_eq!(m.content, "sent text");
            assert_eq!(m.source_hash, hash);
            assert!(m.signature_validated);
        }
    }

    #[test]
    fn an_upload_is_encrypted_to_the_key_it_is_given_and_to_no_other() {
        let (distro, _hash, msg) = distro_message("x");
        let packed = pack_message(&Arc::new(Mutex::new(msg))).unwrap();
        let other = Identity::new(true);
        // The key must produce the message's destination: a held distro that is not the owed one is refused.
        let err = build_propagation_upload(&other.get_public_key().unwrap(), &packed, 0).unwrap_err();
        assert!(err.contains("does not produce"), "{err}");
        assert!(build_propagation_upload(&[1, 2, 3], &packed, 0).is_err());
        assert!(build_propagation_upload(&distro.get_public_key().unwrap(), &packed[..40], 0).is_err());
        // The owed distro's own key works whatever else the device holds.
        assert!(build_propagation_upload(&distro.get_public_key().unwrap(), &packed, 0).is_ok());
    }

    #[test]
    fn the_wrapper_picks_the_smallest_bin_header() {
        for (len, header) in [(10usize, vec![0xc4, 10u8]), (255, vec![0xc4, 255]), (256, vec![0xc5, 1, 0]), (65_535, vec![0xc5, 255, 255]), (65_536, vec![0xc6, 0, 1, 0, 0])] {
            let data = vec![7u8; len];
            let payload = propagation_payload(1.5, &data);
            assert_eq!(&payload[11..11 + header.len()], &header[..], "len {len}");
            assert_eq!(payload.len(), 11 + header.len() + len);
        }
        let payload = propagation_payload(1_767_225_600.25, b"abc");
        // The timestamp is a float 64, the shape the node's msgpack reads as [f64, [bin]].
        let value = rmpv::decode::read_value(&mut &payload[..]).unwrap();
        assert_eq!(
            value,
            Value::Array(vec![Value::F64(1_767_225_600.25), Value::Array(vec![Value::Binary(b"abc".to_vec())])])
        );
    }
}
