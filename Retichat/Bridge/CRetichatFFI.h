//
//  CRetichatFFI.h
//  Retichat
//
//  C header for the Rust FFI static library (libretichat_ffi.a).
//  Included via the bridging header so Swift can call these functions.
//
//  Three API layers:
//    rns_*      — Universal Reticulum transport client API (from Reticulum-rust/cffi).
//    lxmf_*     — Universal high-level LXMF client API (from LXMF-rust/cffi).
//    retichat_* — App-specific transport utilities (thin wrappers, legacy compat).
//

#ifndef CRetichatFFI_h
#define CRetichatFFI_h

#include <stdint.h>

// ===========================================================================
//  Reticulum Transport API — universal, language-bridge-friendly
// ===========================================================================

#pragma mark - RNS Library

char *rns_last_error(void);
void  rns_free_string(char *ptr);
void  rns_free_bytes(uint8_t *ptr, uint32_t len);

#pragma mark - RNS Client Lifecycle

uint64_t rns_client_start(const char *config_dir,
                           const char *identity_path,
                           int32_t create_identity,
                           int32_t log_level);

int32_t rns_client_shutdown(uint64_t client);

#pragma mark - RNS Client Queries

uint64_t rns_client_identity_handle(uint64_t client);
int32_t  rns_client_identity_hash(uint64_t client, uint8_t *out_buf, uint32_t buf_len);
int32_t  rns_client_dest_hash(uint64_t client,
                               const char *app_name,
                               const char *aspects,
                               uint8_t *out_buf, uint32_t buf_len);
void     rns_client_persist(uint64_t client);

#pragma mark - RNS Transport

int32_t rns_transport_has_path(const uint8_t *dest_hash, uint32_t len);
int32_t rns_identity_known(const uint8_t *dest_hash, uint32_t len);
int32_t rns_transport_request_path(const uint8_t *dest_hash, uint32_t len);
int32_t rns_transport_hops_to(const uint8_t *dest_hash, uint32_t len);

/// Query whether a configured interface is currently online.
/// Returns: 1 = online, 0 = offline, -1 = unknown / no such interface.
int32_t rns_interface_online(const char *name);

#pragma mark - RNS Settings

void    rns_set_drop_announces(int32_t enabled);
int32_t rns_set_keepalive_interval(double secs);

#pragma mark - RNS Network Connectivity

/// Signal that network connectivity has been restored.
/// Wakes all TCP client reconnect loops for an immediate retry.
void rns_nudge_reconnect(void);

#pragma mark - RNS Identity (standalone)

uint64_t rns_identity_from_bytes(const uint8_t *bytes, uint32_t len);
int32_t  rns_identity_public_key(uint64_t handle, uint8_t *out_buf, uint32_t buf_len);
int32_t  rns_identity_destroy(uint64_t handle);

#pragma mark - RNS Packet

int32_t rns_packet_send_to_hash(const uint8_t *dest_hash, uint32_t dest_hash_len,
                                 const char *app_name,
                                 const char *aspects,
                                 const uint8_t *payload, uint32_t payload_len);

#pragma mark - RNS Link Request

/// Blocking — call from a background thread.
/// Returns response bytes (free with rns_free_bytes), or NULL.
uint8_t *rns_link_request(const uint8_t *dest_hash, uint32_t dest_hash_len,
                           const char *app_name,
                           const char *aspects,
                           uint64_t identity_handle,
                           const char *path,
                           const uint8_t *payload, uint32_t payload_len,
                           double timeout_secs,
                           uint32_t *out_len);

// ===========================================================================
//  LXMF Client API — universal, high-level, language-bridge-friendly
// ===========================================================================

#pragma mark - LXMF Library

char *lxmf_last_error(void);
void  lxmf_free_string(char *ptr);
void  lxmf_free_bytes(uint8_t *ptr, uint32_t len);

#pragma mark - LXMF Client Lifecycle

uint64_t lxmf_client_start(const char *config_dir,
                            const char *storage_path,
                            const char *identity_path,
                            int32_t create_identity,
                            const char *display_name,
                            int32_t log_level,
                            int32_t stamp_cost);

int32_t lxmf_client_shutdown(uint64_t client);

#pragma mark - LXMF Client Callbacks

typedef void (*lxmf_delivery_callback_t)(
    void *context,
    const uint8_t *hash, uint32_t hash_len,
    const uint8_t *src_hash, uint32_t src_len,
    const uint8_t *dest_hash, uint32_t dest_len,
    const char *title,
    const char *content,
    double timestamp,
    int32_t signature_valid,
    const uint8_t *fields_raw, uint32_t fields_len
);

typedef void (*lxmf_announce_callback_t)(
    void *context,
    const uint8_t *dest_hash, uint32_t dest_len,
    const char *display_name
);

typedef void (*lxmf_sync_complete_callback_t)(
    void *context,
    uint32_t message_count
);

typedef void (*lxmf_message_state_callback_t)(
    void *context,
    const uint8_t *msg_hash, uint32_t hash_len,
    uint8_t state
);

typedef void (*lxmf_app_link_status_callback_t)(
    void *context,
    const uint8_t *dest_hash, uint32_t hash_len,
    uint8_t status
);

/// APP_LINK request completion callback (async variant).
///
/// Fires exactly once per `lxmf_app_link_request_async` invocation.
///
/// `status`:
///   0 = success — `bytes`/`bytes_len` describe the response payload.
///       Pointer is only valid for the duration of the callback; copy
///       before returning.
///   1 = timeout
///   2 = failed (peer rejected / link torn down before response)
///   3 = error (link not active, invalid args; check `lxmf_last_error`)
typedef void (*lxmf_app_link_request_callback_t)(
    void *context,
    const uint8_t *bytes, uint32_t bytes_len,
    int32_t status
);

int32_t lxmf_client_set_delivery_callback(uint64_t client,
                                           lxmf_delivery_callback_t callback,
                                           void *context);

int32_t lxmf_client_set_announce_callback(uint64_t client,
                                           lxmf_announce_callback_t callback,
                                           void *context);

int32_t lxmf_client_set_sync_complete_callback(uint64_t client,
                                                lxmf_sync_complete_callback_t callback,
                                                void *context);

int32_t lxmf_client_set_message_state_callback(uint64_t client,
                                                lxmf_message_state_callback_t callback,
                                                void *context);

#pragma mark - LXMF Client Queries

uint64_t lxmf_client_identity_handle(uint64_t client);
int32_t lxmf_client_identity_hash(uint64_t client, uint8_t *out_buf, uint32_t buf_len);
int32_t lxmf_client_dest_hash(uint64_t client, uint8_t *out_buf, uint32_t buf_len);

#pragma mark - LXMF Propagation

int32_t lxmf_client_sync(uint64_t client, const uint8_t *node_hash, uint32_t node_len);
int32_t lxmf_client_propagation_state(uint64_t client);
float   lxmf_client_propagation_progress(uint64_t client);
int32_t lxmf_client_cancel_propagation(uint64_t client);

#pragma mark - LXMF Peer Link Status

/// Query the current direct-link status for a peer.
/// Returns: 0 = no link / closed, 1 = pending (establishing), 2 = active, -1 on error.
int32_t lxmf_peer_link_status(uint64_t client, const uint8_t *dest_hash, uint32_t dest_len);

#pragma mark - LXMF App Links

/// Open an app link.  Watches dest, requests path, establishes link
/// when path arrives.  Push-driven (no polling).  Link kept alive
/// automatically and exempt from inactivity cleanup.
///
/// `app_name` and `aspects_csv` describe the destination identity that the
/// router must resolve when (re)establishing the link. Examples:
///   app_name="lxmf", aspects_csv="delivery"  — peer chat link.
///   app_name="rfed", aspects_csv="channel"   — rfed channel link.
///   app_name="rfed", aspects_csv="notify"    — rfed notify link.
/// `aspects_csv` is `.`-separated; pass "" if the app has no aspects.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_open(uint64_t client,
                            const uint8_t *dest_hash, uint32_t dest_len,
                            const char *app_name,
                            const char *aspects_csv);

/// Close an app link.  Tears down the direct link.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_close(uint64_t client,
                             const uint8_t *dest_hash, uint32_t dest_len);

/// Query app link status.
///   0 = not tracked (NONE)
///   1 = path requested (PATH_REQUESTED)
///   2 = link establishing (ESTABLISHING)
///   3 = link active, ready to send (ACTIVE)
///   4 = disconnected, will reconnect on next announce (DISCONNECTED)
///  -1 = parameter error
int32_t lxmf_app_link_status(uint64_t client,
                              const uint8_t *dest_hash, uint32_t dest_len);

/// Register an app-link reconnect handler for a non-LXMF destination aspect.
///
/// The built-in announce handler only fires for `lxmf.delivery`; call this for
/// every extra aspect (e.g. "rfed.channel", "rfed.notify") so that when that
/// destination announces the router re-establishes any open app-link to it.
/// Call once per aspect during startup.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_register_reconnect(uint64_t client,
                                          const char *aspect_filter);

/// Register an APP_LINK status callback on the global registry.
///
/// The callback fires whenever an APP_LINK transitions state.  Status byte:
///   0 = NONE, 1 = PATH_REQUESTED, 2 = ESTABLISHING,
///   3 = ACTIVE, 4 = DISCONNECTED.
///
/// Multiple callbacks may be registered.  The callback runs on the link
/// actor thread and MUST NOT block — copy any data and dispatch off-thread.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_register_status_callback(uint64_t client,
                                                lxmf_app_link_status_callback_t callback,
                                                void *context);

/// Notify the router that the host's network reachability state has
/// changed (interface up/down, Wi-Fi <-> cellular, VPN flipped, etc.).
///
/// Triggers ONE fresh app-link establishment attempt for every registered
/// app-link that is not currently active or already establishing. The
/// router does not retry on its own — call this from a network-state
/// observer (NWPathMonitor on iOS, ConnectivityManager on Android).
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_network_changed(uint64_t client);

/// Send a blocking request on an existing app-link.
///
/// Reuses the persistent app-link opened by `lxmf_app_link_open` instead of
/// opening a fresh outbound link per request.  The link must already be in
/// the ACTIVE state (call `lxmf_app_link_status` first) — returns NULL with
/// `lxmf_last_error` describing the reason if not.
///
/// Blocking call — invoke from a background thread.
/// Returns response bytes (free with `lxmf_free_bytes`) or NULL on error
/// / timeout / link not active.
uint8_t *lxmf_app_link_request(uint64_t client,
                                const uint8_t *dest_hash, uint32_t dest_len,
                                const char *path,
                                const uint8_t *payload, uint32_t payload_len,
                                double timeout_secs,
                                uint32_t *out_len);

/// Non-blocking variant of `lxmf_app_link_request`.
///
/// Issues a request on the existing app-link to `dest_hash` and fires
/// `callback(context, bytes, bytes_len, status)` exactly once when the
/// response arrives, the request fails, or `timeout_secs` elapses.
///
/// Returns 0 on success (callback will fire), -1 on immediate error
/// (callback will NOT fire; check `lxmf_last_error`).
///
/// Preferred over the blocking variant when called from cooperative
/// concurrency contexts (Swift async, Kotlin coroutines): avoids parking
/// a high-QoS pool thread on a Default-QoS Rust receive. See
/// DESIGN_PRINCIPLES.md §1.
int32_t lxmf_app_link_request_async(uint64_t client,
                                     const uint8_t *dest_hash, uint32_t dest_len,
                                     const char *path,
                                     const uint8_t *payload, uint32_t payload_len,
                                     double timeout_secs,
                                     lxmf_app_link_request_callback_t callback,
                                     void *context);

#pragma mark - LXMF Announce

int32_t lxmf_client_announce(uint64_t client);
int32_t lxmf_client_watch(uint64_t client, const uint8_t *dest_hash, uint32_t dest_len);

/// Opt this client's delivery destination into Transport's auto-announce
/// daemon. Transport will then re-announce automatically:
///   * once on every interface false→true `online` transition, and
///   * every `refresh_secs` seconds (pass 0.0 to disable periodic
///     refresh and only re-announce on interface up-edges).
/// Idempotent: a second call updates the entry. Returns 0 on success.
int32_t lxmf_client_publish(uint64_t client, double refresh_secs);

/// Remove this client's delivery destination from the auto-announce
/// daemon. Returns 0 on success.
int32_t lxmf_client_unpublish(uint64_t client);

/// Look up the cached display name for a destination hash (from its last announce).
/// Writes a NUL-terminated UTF-8 string into out_buf.
/// Returns the number of bytes written (including NUL), or 0 if unknown / buffer too small.
int32_t lxmf_client_recall_display_name(uint64_t client,
                                         const uint8_t *dest_hash, uint32_t dest_len,
                                         char *out_buf, uint32_t buf_len);

#pragma mark - LXMF Messages

uint64_t lxmf_message_new(uint64_t client,
                           const uint8_t *dest_hash, uint32_t dest_len,
                           const char *content, const char *title,
                           uint8_t method);

int32_t lxmf_message_add_field(uint64_t msg, uint8_t key, const char *value);
int32_t lxmf_message_add_field_bool(uint64_t msg, uint8_t key, int32_t value);
int32_t lxmf_message_add_attachment(uint64_t msg, const char *filename,
                                     const uint8_t *data, uint32_t data_len);
int32_t lxmf_message_send(uint64_t client, uint64_t msg);
/// Send via the top-level AppLinks::send pipeline (iface-race + 2 s
/// liveness cache; no client/router handle required — uses the global
/// router registered by lxmf_router_create).
int32_t lxmf_message_send_via_app_links(uint64_t msg);
/// Forget the cached liveness winner for `dest_hash` so the next
/// lxmf_message_send_via_app_links re-races interfaces. Call on
/// known network-state changes (WiFi→cellular, etc).
int32_t lxmf_app_links_invalidate_liveness(const uint8_t *dest_hash, uint32_t dest_len);
int32_t lxmf_message_state(uint64_t msg);
float   lxmf_message_progress(uint64_t msg);
int32_t lxmf_message_hash(uint64_t msg, uint8_t *out_buf, uint32_t buf_len);
int32_t lxmf_message_destroy(uint64_t msg);

#pragma mark - LXMF Utility

int32_t lxmf_client_process_outbound(uint64_t client);
void    lxmf_client_persist(uint64_t client);

// ===========================================================================
//  Retichat Utilities — transport, identity, packet, settings
// ===========================================================================

#pragma mark - Identity (standalone)

/// Load identity from raw bytes. Returns handle or 0.
uint64_t retichat_identity_from_bytes(const uint8_t *bytes, uint32_t len);

/// Get identity public key. Writes to out_buf (>= 64 bytes). Returns count or -1.
int32_t retichat_identity_public_key(uint64_t handle, uint8_t *out_buf, uint32_t buf_len);

/// Sign data with the identity's Ed25519 signing key. Writes 64-byte sig to out_sig. Returns 64 or -1.
int32_t retichat_identity_sign(uint64_t handle, const uint8_t *data, uint32_t data_len, uint8_t *out_sig, uint32_t sig_buf_len);

/// Destroy a standalone identity handle. Do NOT call for identities owned by lxmf_client.
int32_t retichat_identity_destroy(uint64_t handle);

#pragma mark - Transport

int32_t retichat_transport_has_path(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_identity_known(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_transport_request_path(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_transport_hops_to(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_transport_path_interface_online(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_transport_drop_path(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_transport_save_paths(void);

#pragma mark - Settings

void    retichat_set_drop_announces(int32_t enabled);
void    retichat_watch_announce(const uint8_t *dest_hash, uint32_t len);
void    retichat_unwatch_announce(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_set_keepalive_interval(double secs);

#pragma mark - Raw packet send

int32_t retichat_packet_send_to_hash(const uint8_t *dest_hash, uint32_t dest_hash_len,
                                      const char *app_name,
                                      const char *aspects,
                                      const uint8_t *payload, uint32_t payload_len);

#pragma mark - Link request

/// Blocking — call from a background thread.
/// Returns response bytes (free with lxmf_free_bytes), or NULL.
uint8_t *retichat_link_request(const uint8_t *dest_hash, uint32_t dest_hash_len,
                                const char *app_name,
                                const char *aspects,
                                uint64_t identity_handle,
                                const char *path,
                                const uint8_t *payload, uint32_t payload_len,
                                double timeout_secs,
                                uint32_t *out_len);

#pragma mark - RFed Delivery (inbound channel blobs)

/// Callback type fired when a channel blob arrives at the local rfed.delivery endpoint.
/// Called on a Reticulum worker thread — dispatch to main thread if needed.
typedef void (*rfed_blob_callback_t)(const uint8_t *data, uint32_t len, void *ctx);

/// Register an inbound rfed.delivery destination so the rfed server can push
/// channel blobs to this device.  identity_handle must come from
/// lxmf_client_identity_handle().  Returns 0 on success, -1 on error.
int32_t retichat_rfed_delivery_start(uint64_t identity_handle,
                                      rfed_blob_callback_t callback,
                                      void *ctx);

/// Announce the local rfed.delivery destination.  Call at startup and on
/// foreground transitions to trigger flush of deferred blobs from the server.
/// Returns 0 on success, -1 on error.
int32_t retichat_rfed_delivery_announce(void);

/// Stop the local rfed.delivery endpoint and deregister from transport.
int32_t retichat_rfed_delivery_stop(void);

#pragma mark - Channel Crypto

/// Encrypt `plaintext` for the named channel.
/// Derives the channel keypair deterministically from `name` (e.g. "public.general").
/// Returns heap-allocated ciphertext (free with lxmf_free_bytes), or NULL on error.
uint8_t *retichat_channel_encrypt(const char *name,
                                   const uint8_t *plaintext, uint32_t plaintext_len,
                                   uint32_t *out_len);

/// Decrypt ciphertext for the named channel.
/// Derives the channel keypair deterministically from `name`.
/// Returns heap-allocated plaintext (free with lxmf_free_bytes), or NULL on error.
uint8_t *retichat_channel_decrypt(const char *name,
                                   const uint8_t *ciphertext, uint32_t ciphertext_len,
                                   uint32_t *out_len);

/// Compute a PoW stamp for a channel SEND packet.
/// `payload` = channel_hash(16) | ciphertext (everything before the stamp).
/// `cost` = required leading-zero bits (must match rfed's stamp_cost). Pass 0 for no stamp.
/// Returns heap-allocated 32-byte stamp (free with lxmf_free_bytes), or NULL when cost == 0.
uint8_t *retichat_compute_channel_stamp(const uint8_t *payload, uint32_t payload_len,
                                         uint32_t cost,
                                         uint32_t *out_len);

#pragma mark - Channel LXMF Pack / Unpack
//
// CHANNEL MESSAGES ARE LXMF PACKAGES.  Wire format is identical to what an
// LXMF propagation node stores and delivers:
//     [ channel_hash(16) | EC_encrypted(source_hash || signature || msgpack_payload) ]
//

/// Build an LXMF message addressed to the channel destination and pack it
/// into `lxmf_data` (the bytes RFed routes opaquely).
///
/// `name`           — channel name (e.g. "public.general")
/// `sender_handle`  — local user identity handle
/// `content`        — message body (UTF-8)
/// `title`          — optional title (UTF-8); pass NULL/0 for none
///
/// Returns heap-allocated lxmf_data (free with lxmf_free_bytes) starting with
/// the 16-byte channel_hash, or NULL on error.
uint8_t *retichat_channel_lxm_pack(const char *name,
                                    uint64_t sender_handle,
                                    const uint8_t *content, uint32_t content_len,
                                    const uint8_t *title,   uint32_t title_len,
                                    uint32_t *out_len);

/// Unpack an LXMF channel message.
/// Input is `lxmf_data` (16-byte channel_hash + EC_encrypted tail).
///
/// Returns a heap-allocated buffer (free with lxmf_free_bytes) with layout:
///     [0..16]   source_hash
///     [16..24]  timestamp_ms_be (u64)
///     [24]      signature_validated (1=ok, 0=not)
///     [25]      unverified_reason   (0=ok, 1=SOURCE_UNKNOWN, 2=SIGNATURE_INVALID)
///     [26..28]  title_len_be   (u16)
///     [28..32]  content_len_be (u32)
///     [32..32+t]   title bytes
///     [32+t..]     content bytes
uint8_t *retichat_channel_lxm_unpack(const char *name,
                                      const uint8_t *lxmf_data, uint32_t lxmf_data_len,
                                      uint32_t *out_len);

#pragma mark - RNS RNode callback interface (BLE / Serial via native bridge)

/// Radio configuration for an RNode interface.
/// `_set` flags select whether the matching optional value is applied.
typedef struct RnsRNodeRadioConfig {
    uint64_t frequency;
    uint32_t bandwidth;
    uint8_t  txpower;
    uint8_t  sf;
    uint8_t  cr;
    uint8_t  flow_control;       // 0 = off, non-zero = on
    uint8_t  st_alock_set;       // 0 = none, 1 = use st_alock_pct
    float    st_alock_pct;
    uint8_t  lt_alock_set;
    float    lt_alock_pct;
    uint8_t  id_beacon_set;      // 0 = none, 1 = use id_interval_secs + id_callsign
    uint64_t id_interval_secs;
    const uint8_t *id_callsign;  // may be NULL when id_beacon_set == 0
    uint32_t id_callsign_len;
} RnsRNodeRadioConfig;

/// Latest device telemetry snapshot.
typedef struct RnsRNodeStats {
    uint8_t  online;
    uint8_t  detected;
    uint8_t  frequency_set;     uint64_t frequency;
    uint8_t  bandwidth_set;     uint32_t bandwidth;
    uint8_t  txpower_set;       uint8_t  txpower;
    uint8_t  sf_set;            uint8_t  sf;
    uint8_t  cr_set;            uint8_t  cr;
    uint8_t  rssi_set;          int16_t  rssi;
    uint8_t  snr_set;           float    snr;
    uint8_t  q_set;             float    q;
    uint8_t  rx_packets_set;    uint32_t rx_packets;
    uint8_t  tx_packets_set;    uint32_t tx_packets;
    float    airtime_short;
    float    airtime_long;
    float    channel_load_short;
    float    channel_load_long;
    uint8_t  battery_state;
    uint8_t  battery_percent;
    uint8_t  temperature_set;   int8_t   temperature;
    uint8_t  firmware_maj;
    uint8_t  firmware_min;
} RnsRNodeStats;

/// TX callback signature: invoked from Rust when KISS-framed bytes are ready
/// to be written to the radio. The bridge is responsible for any link-MTU
/// chunking (e.g. 20-byte BLE writes). Return non-zero on success.
typedef int32_t (*RnsRNodeSendFn)(void *user_data, const uint8_t *data, uint32_t len);

/// Register an RNode callback interface. Spawns the read loop and runs the
/// DETECT/init handshake (~3s while bytes are fed in).
/// Returns a handle (>0) or 0 on error (check rns_last_error).
uint64_t rns_rnode_iface_register(const char *name,
                                  RnsRNodeSendFn send_fn,
                                  void *user_data,
                                  const RnsRNodeRadioConfig *cfg);

/// Build the RNode interface and spawn its read loop, but do NOT run the
/// DETECT/init handshake. Lets the bridge obtain the handle (and start
/// feeding RX bytes via rns_rnode_iface_feed) BEFORE blocking inside the
/// handshake. Call rns_rnode_iface_configure next.
/// Returns a handle (>0) or 0 on error (check rns_last_error).
uint64_t rns_rnode_iface_create(const char *name,
                                RnsRNodeSendFn send_fn,
                                void *user_data,
                                const RnsRNodeRadioConfig *cfg);

/// Run the DETECT/init handshake on a previously-created RNode handle and
/// wire it into the Transport. Blocks for ~2-4 seconds while DETECT/setup
/// bytes are exchanged with the device. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_configure(uint64_t handle);

/// Push RX bytes (received from the radio) into the read loop. Returns 0 on
/// success, -1 on error.
int32_t  rns_rnode_iface_feed(uint64_t handle, const uint8_t *data, uint32_t len);

/// Fetch the latest device telemetry into `out`. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_get_stats(uint64_t handle, RnsRNodeStats *out);

/// Send the configured ID-beacon callsign immediately. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_id_beacon_now(uint64_t handle);

/// Deregister and tear down the Transport binding. The bridge must stop
/// calling rns_rnode_iface_feed before invoking this. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_deregister(uint64_t handle);

#endif /* CRetichatFFI_h */
