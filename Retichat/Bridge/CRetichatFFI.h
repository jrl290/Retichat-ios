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
int32_t rns_transport_request_path(const uint8_t *dest_hash, uint32_t len);
int32_t rns_transport_hops_to(const uint8_t *dest_hash, uint32_t len);

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
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_open(uint64_t client,
                            const uint8_t *dest_hash, uint32_t dest_len);

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

#pragma mark - LXMF Announce

int32_t lxmf_client_announce(uint64_t client);
int32_t lxmf_client_watch(uint64_t client, const uint8_t *dest_hash, uint32_t dest_len);

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
int32_t retichat_transport_request_path(const uint8_t *dest_hash, uint32_t len);
int32_t retichat_transport_hops_to(const uint8_t *dest_hash, uint32_t len);

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

#endif /* CRetichatFFI_h */
