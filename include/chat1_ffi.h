#ifndef CHAT1_FFI_H
#define CHAT1_FFI_H


#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#define CHAT1_MAX_BATCH 256
#define CHAT1_MAX_ROOM_ID 64
#define CHAT1_MAX_BODY_BYTES 4096
#define CHAT1_MAX_FANOUT 4096
#define CHAT1_SHA256_HEX_LEN 64
#define CHAT1_CID_HEX_LEN 64
#define CHAT1_ATTACH_MIME_MAX 64
#define CHAT1_ATTACH_NAME_MAX 128
#define CHAT1_ED25519_SIG_B64_LEN 86

#define CHAT1_SHARD_OWNER_INVALID UINT32_MAX
#define CHAT1_ROUTE_OK 0
#define CHAT1_ROUTE_ERR_INVALID (-1)
#define CHAT1_ROUTE_ERR_UNIMPLEMENTED (-2)
#define CHAT1_ROUTE_ERR_NOOP (-3)
#define CHAT1_CONN_OK 0
#define CHAT1_CONN_ALLOC_ERR (-1)
#define CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION (-1)
#define CHAT1_CONN_QUEUE_ERR_QUEUE_FULL (-2)
#define CHAT1_CONN_QUEUE_ERR_BYTES_IN_FLIGHT_OVERFLOW (-3)
#define CHAT1_LOG_OK 0
#define CHAT1_LOG_ERR_OPEN (-1)
#define CHAT1_LOG_ERR_WRITE (-2)
#define CHAT1_LOG_ERR_FDATASYNC (-3)
#define CHAT1_WIRE_OK 0
#define CHAT1_WIRE_ERR_NULL (-1)
#define CHAT1_WIRE_ERR_BAD_FRAME (-2)
#define CHAT1_WIRE_ERR_UNSUPPORTED_VERB (-3)
#define CHAT1_WIRE_ERR_FIELD_LEN (-4)
#define CHAT1_WIRE_ERR_FIELD_FORMAT (-5)
#define CHAT1_WIRE_MAX_LINE 65535
#define CHAT1_READER_BUF_BYTES (CHAT1_WIRE_MAX_LINE + 1)
#define CHAT1_READER_OK 0
#define CHAT1_READER_ERR_NULL (-1)
#define CHAT1_READER_ERR_OVERFLOW (-2)
#define CHAT1_READER_ERR_TOO_BIG (-3)
#define CHAT1_READER_NO_FRAME 0
#define CHAT1_READER_HAVE_FRAME 1

typedef struct {
    uint64_t connection_id;
    uint64_t room_hash;
    uint64_t ts_ms;
    uint64_t byte_len;
    char room_id[CHAT1_MAX_ROOM_ID + 1];
    char msg_id[CHAT1_SHA256_HEX_LEN + 1];
    char author_id[CHAT1_SHA256_HEX_LEN + 1];
    char cid_hex[CHAT1_CID_HEX_LEN + 1];
    char mime[CHAT1_ATTACH_MIME_MAX + 1];
    char filename[CHAT1_ATTACH_NAME_MAX + 1];
    char sig_b64[CHAT1_ED25519_SIG_B64_LEN + 1];
} chat1_attach_event;

typedef struct {
    uint64_t connection_id;
    uint64_t room_hash;
    uint64_t ts_ms;
    uint32_t body_len;
    char room_id[CHAT1_MAX_ROOM_ID + 1];
    char body_b64[CHAT1_MAX_BODY_BYTES + 1];
    char author_id[CHAT1_SHA256_HEX_LEN + 1];
    char msg_id[CHAT1_SHA256_HEX_LEN + 1];
    char sig_b64[CHAT1_ED25519_SIG_B64_LEN + 1];
} chat1_ingress_event;

typedef struct {
    uint32_t shard_index;
    uint32_t local_count;
    chat1_ingress_event events[CHAT1_MAX_BATCH];
} chat1_ingress_batch;

typedef struct {
    uint64_t target_connection_id;
    uint64_t store_slot;
    uint32_t payload_offset;
    uint32_t payload_len;
} chat1_fanout_desc;


uint32_t chat1_room_owner(const char *room_id, uint32_t shard_count);

int chat1_shard_process_batch(const chat1_ingress_batch *batch);

int chat1_route_batch_to_owner(const chat1_ingress_batch *batch);

int chat1_conn_alloc(uint64_t *id_out);

int chat1_conn_queue_push(uint64_t id, uint32_t payload_len);

int chat1_log_open(const char *path);

int chat1_log_append(const char *path, const void *buf, uint32_t len);

int chat1_log_append_event(const char *path, const chat1_ingress_event *event);
int chat1_log_append_attach_event(const char *path, const chat1_attach_event *event);
int chat1_shard_log_path(uint32_t shard_index, char *path, size_t path_size);
int chat1_log_want_replay(int (*write_fn)(void *ctx, int fd, const char *buf, size_t len),
                          void *write_ctx,
                          int conn_fd,
                          const char *log_path,
                          const char *room_id,
                          const char *since_msg_id);

int chat1_engine_ingest_batch(const chat1_ingress_batch *batch, chat1_fanout_desc *fanout_out, uint32_t *fanout_count);

void chat1_room_engine_init_c(uint32_t max_events, uint32_t max_body_bytes);

#define CHAT1_MAX_CLIENT_ID 64
#define CHAT1_MAX_NONCE 64
#define CHAT1_PUBKEY_B64_LEN 43
#define CHAT1_WIRE_VERB_MSG 1
#define CHAT1_WIRE_VERB_HELLO 2
#define CHAT1_WIRE_VERB_SUB 3
#define CHAT1_WIRE_VERB_UNSUB 4
#define CHAT1_WIRE_VERB_PING 5
#define CHAT1_WIRE_VERB_PONG 6
#define CHAT1_WIRE_VERB_BYE 7
#define CHAT1_WIRE_VERB_HAVE 8
#define CHAT1_WIRE_VERB_WANT 9
#define CHAT1_WIRE_VERB_END 10
#define CHAT1_WIRE_VERB_ATTACH 11
#define CHAT1_WIRE_VERB_LIST 12
#define CHAT1_WIRE_VERB_ROOM 13

typedef struct {
    char client_id[CHAT1_MAX_CLIENT_ID + 1];
    char nonce[CHAT1_MAX_NONCE + 1];
    uint32_t protocol_version;
    uint8_t has_pubkey;
    char pubkey_b64[CHAT1_PUBKEY_B64_LEN + 1];
} chat1_hello_frame;

typedef struct {
    char room_id[CHAT1_MAX_ROOM_ID + 1];
    uint64_t room_hash;
} chat1_sub_frame;

typedef struct {
    char visibility[8];
    char room_id[CHAT1_MAX_ROOM_ID + 1];
} chat1_room_meta_frame;

typedef struct {
    char nonce[CHAT1_MAX_NONCE + 1];
} chat1_nonce_frame;

typedef struct {
    char room_id[CHAT1_MAX_ROOM_ID + 1];
    uint64_t room_hash;
    char msg_id[CHAT1_SHA256_HEX_LEN + 1];
} chat1_room_msg_frame;

typedef struct {
    int verb;
    union {
        chat1_ingress_event msg;
        chat1_attach_event attach;
        chat1_hello_frame hello;
        chat1_sub_frame sub;
        chat1_nonce_frame nonce;
        chat1_room_msg_frame room_msg;
        chat1_room_meta_frame room_meta;
    } u;
} chat1_parsed_frame;

int chat1_parse_msg_frame(const char *line, uint32_t len, chat1_ingress_event *out);
int chat1_parse_attach_frame(const char *line, uint32_t len, chat1_attach_event *out);
int chat1_parse_frame(const char *line, uint32_t len, chat1_parsed_frame *out);

uint64_t chat1_room_hash_of_id(const char *room_id);

void chat1_presence_init(void);
void chat1_presence_room_set(const char *room_id, int is_private);
void chat1_presence_on_sub(const char *room_id, uint64_t room_hash, uint64_t conn_id);
void chat1_presence_on_unsub(uint64_t room_hash, uint64_t conn_id);
void chat1_presence_on_disconnect(uint64_t conn_id);
int chat1_presence_format_list(char *buf, size_t cap);

typedef struct {
    uint32_t fill;
    uint32_t scan;
    uint8_t skipping;
    uint8_t too_big_pending;
    char buf[CHAT1_READER_BUF_BYTES];
} chat1_frame_reader;

void chat1_frame_reader_init(chat1_frame_reader *r);
int chat1_frame_reader_feed(chat1_frame_reader *r, const void *data, uint32_t len);
int chat1_frame_reader_next(chat1_frame_reader *r, const char **line_out, uint32_t *line_len_out);

#define CHAT1_SERVE_OK 0
#define CHAT1_SERVE_ERR_ACCEPT (-1)
#define CHAT1_SERVE_ERR_READ (-2)
#define CHAT1_SERVE_ERR_DISPATCH (-3)

int chat1_serve_once(int listener_fd, uint32_t shard_index);
int chat1_serve_loop(int listener_fd, uint32_t shard_index);
int chat1_serve_threaded(int listener_fd, uint32_t shard_index, int max_accept);

#define CHAT1_SUB_OK 0
#define CHAT1_SUB_ERR_FULL (-1)
#define CHAT1_SUB_ERR_DUPLICATE (-2)
#define CHAT1_SUB_ERR_NOT_FOUND (-3)
#define CHAT1_MAX_SUBS_PER_ROOM 256
#define CHAT1_MAX_ROOMS 4096

void chat1_sub_table_init(void);
int chat1_sub_add(uint64_t room_hash, uint64_t conn_id);
int chat1_sub_remove(uint64_t room_hash, uint64_t conn_id);
void chat1_sub_remove_all(uint64_t conn_id);
void chat1_sub_rooms_for_conn(uint64_t conn_id, uint64_t *hashes_out, uint32_t max, uint32_t *n_out);
int chat1_sub_list(uint64_t room_hash, uint64_t *out, uint32_t max, uint32_t *count);

void chat1_conn_table_reset(void);
int chat1_conn_free(uint64_t id);
int chat1_conn_set_fd(uint64_t id, int fd);
int chat1_conn_get_fd(uint64_t id, int *fd_out);
int chat1_conn_set_author(uint64_t id, const char *author_id_hex);
int chat1_conn_get_author(uint64_t id, char *out_hex, size_t out_len);

int chat1_fanout_msg_to_subscribers(uint64_t room_hash, const chat1_ingress_event *ev);
int chat1_fanout_attach_to_subscribers(uint64_t room_hash, const chat1_attach_event *ev);
int chat1_attach_dispatch(uint32_t shard_index, const chat1_attach_event *ev);
void chat1_auth_keys_init(void);
int chat1_auth_key_put(const char *author_id_hex, const char *pubkey_b64);
int chat1_auth_key_get(const char *author_id_hex, char *pubkey_b64_out, uint32_t out_len);
int chat1_verify_msg_signature(const chat1_ingress_event *ev);
int chat1_verify_attach_signature(const chat1_attach_event *ev);
int chat1_tls_init(void);
int chat1_tls_server_config(const char *cert_path, const char *key_path);
int chat1_tls_server_config_from_env(void);
int chat1_tls_accept_fd(int fd, void **tls_out);
int chat1_tls_server_enabled(void);
ssize_t chat1_tls_read(void *tls_ctx, int fd, void *buf, size_t len);
ssize_t chat1_tls_write(void *tls_ctx, int fd, const void *buf, size_t len);
void chat1_tls_close(void *tls_ctx);

#endif
