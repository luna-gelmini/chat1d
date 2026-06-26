#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <openssl/sha.h>
#include <openssl/evp.h>
#include <time.h>

#include "chat1_ffi.h"
#include "chat1_server_config.h"

static int write_all(void *tls_ctx, int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = chat1_tls_write(tls_ctx, fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static void log_ev(const char *level, const char *event, const char *k1, const char *v1, const char *k2, const char *v2) {
    time_t now = time(NULL);
    if (!k1) k1 = "none";
    if (!v1) v1 = "-";
    if (!k2) k2 = "none";
    if (!v2) v2 = "-";
    fprintf(stderr, "ts=%lld level=%s event=%s %s=%s %s=%s\n",
            (long long)now, level, event, k1, v1, k2, v2);
}

static void send_err(void *tls_ctx, int fd, const char *code, const char *text) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "ERR\t%s\t%s\n", code, text);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        write_all(tls_ctx, fd, buf, (size_t)n);
        log_ev("warn", "err_sent", "code", code, "text", text);
    }
}

static int b64url_decode_local(const char *in, uint8_t *out, size_t out_cap, size_t *out_len) {
    size_t n = strlen(in);
    char tmp[128];
    uint8_t buf[128];
    int decoded;
    if (n + 4 >= sizeof(tmp)) return -1;
    for (size_t i = 0; i < n; ++i) {
        char c = in[i];
        tmp[i] = (c == '-') ? '+' : (c == '_') ? '/' : c;
    }
    size_t pad = (4 - (n % 4)) % 4;
    for (size_t i = 0; i < pad; ++i) tmp[n + i] = '=';
    tmp[n + pad] = '\0';
    decoded = EVP_DecodeBlock(buf, (const unsigned char *)tmp, (int)(n + pad));
    if (decoded < 0) return -1;
    while (pad > 0 && decoded > 0 && buf[decoded - 1] == 0) {
        decoded--;
        pad--;
    }
    if ((size_t)decoded > out_cap) return -1;
    memcpy(out, buf, (size_t)decoded);
    *out_len = (size_t)decoded;
    return 0;
}

static int derive_author_id_hex(const char *pubkey_b64, char *out_hex) {
    uint8_t raw[64];
    size_t raw_len = 0;
    unsigned char hash[SHA256_DIGEST_LENGTH];
    static const char *hx = "0123456789abcdef";
    if (b64url_decode_local(pubkey_b64, raw, sizeof(raw), &raw_len) != 0 || raw_len != 32) return -1;
    SHA256(raw, raw_len, hash);
    for (int i = 0; i < SHA256_DIGEST_LENGTH; ++i) {
        out_hex[i * 2] = hx[(hash[i] >> 4) & 0xF];
        out_hex[i * 2 + 1] = hx[hash[i] & 0xF];
    }
    out_hex[CHAT1_SHA256_HEX_LEN] = '\0';
    return 0;
}

static int handle_hello(void *tls_ctx, int conn_fd, uint64_t conn_id, const chat1_hello_frame *hello) {
    char resp[256];
    int len;
    if (hello->has_pubkey) {
        char author_id[CHAT1_SHA256_HEX_LEN + 1];
        if (derive_author_id_hex(hello->pubkey_b64, author_id) == 0) {
            chat1_auth_key_put(author_id, hello->pubkey_b64);
            chat1_conn_set_author(conn_id, author_id);
            log_ev("info", "hello_key_registered", "author_id", author_id, "client", hello->client_id);
        }
    }
    len = snprintf(resp, sizeof(resp), "HELLO\tchat1d\t1\t0\n");
    if (len <= 0 || (size_t)len >= sizeof(resp)) return CHAT1_SERVE_ERR_DISPATCH;
    return write_all(tls_ctx, conn_fd, resp, (size_t)len) == 0 ? CHAT1_SERVE_OK : CHAT1_SERVE_ERR_DISPATCH;
}

static int handle_msg(void *tls_ctx, int conn_fd, uint32_t shard_index, uint64_t conn_id, const chat1_ingress_event *msg_in) {
    chat1_ingress_batch *batch = (chat1_ingress_batch *)calloc(1, sizeof(*batch));
    int rc;

    if (!batch) return CHAT1_SERVE_ERR_DISPATCH;

    batch->shard_index = shard_index;
    batch->local_count = 1;
    memcpy(&batch->events[0], msg_in, sizeof(*msg_in));
    batch->events[0].connection_id = conn_id;
    if (chat1_verify_msg_signature(&batch->events[0]) != CHAT1_ROUTE_OK) {
        send_err(tls_ctx, conn_fd, "bad-signature", "msg rejected");
        free(batch);
        log_ev("warn", "msg_rejected", "reason", "bad-signature", "room", msg_in->room_id);
        return CHAT1_SERVE_OK;
    }

    rc = chat1_shard_process_batch(batch);
    if (rc == CHAT1_ROUTE_OK) {
        chat1_fanout_msg_to_subscribers(msg_in->room_hash, &batch->events[0]);
        log_ev("info", "msg_committed", "room", msg_in->room_id, "author", msg_in->author_id);
    }
    free(batch);

    return (rc == CHAT1_ROUTE_OK) ? CHAT1_SERVE_OK : CHAT1_SERVE_ERR_DISPATCH;
}

static int handle_attach(void *tls_ctx, int conn_fd, uint32_t shard_index, uint64_t conn_id, const chat1_attach_event *in) {
    chat1_attach_event ev = *in;

    ev.connection_id = conn_id;
    if (chat1_verify_attach_signature(&ev) != CHAT1_ROUTE_OK) {
        send_err(tls_ctx, conn_fd, "bad-signature", "attach rejected");
        log_ev("warn", "attach_rejected", "reason", "bad-signature", "room", in->room_id);
        return CHAT1_SERVE_OK;
    }

    if (chat1_attach_dispatch(shard_index, &ev) != CHAT1_ROUTE_OK) {
        return CHAT1_SERVE_ERR_DISPATCH;
    }

    log_ev("info", "attach_committed", "room", in->room_id, "author", in->author_id);
    return CHAT1_SERVE_OK;
}

static uint32_t shard_count_env(void) {
    const char *v = getenv("CHAT1_SHARD_COUNT");
    int n;
    if (!v || !*v) {
        return 1u;
    }
    n = atoi(v);
    return n <= 0 ? 1u : (uint32_t)n;
}

static int handle_want(void *tls_ctx, int conn_fd, uint32_t shard_index, const chat1_room_msg_frame *want) {
    char path[128];
    uint32_t nshards = shard_count_env();
    const char *room_id = want->room_id;
    const char *since = want->msg_id;

    if (chat1_shard_log_path(shard_index, path, sizeof(path)) != CHAT1_LOG_OK) {
        return CHAT1_SERVE_ERR_DISPATCH;
    }

    if (chat1_room_owner(room_id, nshards) != shard_index) {
        char buf[CHAT1_MAX_ROOM_ID + 32];
        int m = snprintf(buf, sizeof(buf), "END\t%s\n", room_id);
        if (m <= 0 || (size_t)m >= sizeof(buf)) {
            return CHAT1_SERVE_ERR_DISPATCH;
        }
        return write_all(tls_ctx, conn_fd, buf, (size_t)m) == 0 ? CHAT1_SERVE_OK : CHAT1_SERVE_ERR_DISPATCH;
    }

    if (chat1_log_want_replay(write_all, tls_ctx, conn_fd, path, room_id, since) != 0) {
        return CHAT1_SERVE_ERR_DISPATCH;
    }
    return CHAT1_SERVE_OK;
}

static int handle_list_resp(void *tls_ctx, int conn_fd) {
    char buf[16384];
    int n = chat1_presence_format_list(buf, sizeof(buf));
    if (n <= 0) {
        n = snprintf(buf, sizeof(buf), "ROOMS\t\n");
        if (n <= 0 || (size_t)n >= sizeof(buf)) return CHAT1_SERVE_ERR_DISPATCH;
    }
    return write_all(tls_ctx, conn_fd, buf, (size_t)n) == 0 ? CHAT1_SERVE_OK : CHAT1_SERVE_ERR_DISPATCH;
}

static int handle_frame(void *tls_ctx, int conn_fd, uint32_t shard_index, uint64_t conn_id,
                        const char *line, uint32_t line_len) {
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(line, line_len, &pf);

    if (rc != CHAT1_WIRE_OK) {
        if (rc == CHAT1_WIRE_ERR_UNSUPPORTED_VERB) {
            send_err(tls_ctx, conn_fd, "unsupported-command", "verb");
        } else {
            send_err(tls_ctx, conn_fd, "bad-frame", "parse");
        }
        return CHAT1_SERVE_OK;
    }

    switch (pf.verb) {
    case CHAT1_WIRE_VERB_HELLO:
        return handle_hello(tls_ctx, conn_fd, conn_id, &pf.u.hello);

    case CHAT1_WIRE_VERB_SUB:
    {
        int sa = chat1_sub_add(pf.u.sub.room_hash, conn_id);
        if (sa == CHAT1_SUB_ERR_FULL) {
            send_err(tls_ctx, conn_fd, "too-large", "sub full");
        } else {
            chat1_presence_on_sub(pf.u.sub.room_id, pf.u.sub.room_hash, conn_id);
        }
        log_ev("info", "sub", "room", pf.u.sub.room_id, "conn", "-");
        return CHAT1_SERVE_OK;
    }

    case CHAT1_WIRE_VERB_UNSUB:
        chat1_sub_remove(pf.u.sub.room_hash, conn_id);
        chat1_presence_on_unsub(pf.u.sub.room_hash, conn_id);
        log_ev("info", "unsub", "room", pf.u.sub.room_id, "conn", "-");
        return CHAT1_SERVE_OK;

    case CHAT1_WIRE_VERB_MSG:
        return handle_msg(tls_ctx, conn_fd, shard_index, conn_id, &pf.u.msg);

    case CHAT1_WIRE_VERB_ATTACH:
        return handle_attach(tls_ctx, conn_fd, shard_index, conn_id, &pf.u.attach);

    case CHAT1_WIRE_VERB_PING:
    {
        char pong[96];
        int n = snprintf(pong, sizeof(pong), "PONG\t%s\n", pf.u.nonce.nonce);
        if (n > 0 && (size_t)n < sizeof(pong)) {
            write_all(tls_ctx, conn_fd, pong, (size_t)n);
        }
        log_ev("debug", "ping", "nonce", pf.u.nonce.nonce, "conn", "-");
        return CHAT1_SERVE_OK;
    }

    case CHAT1_WIRE_VERB_BYE:
        return CHAT1_SERVE_OK;
    case CHAT1_WIRE_VERB_HAVE:
        return CHAT1_SERVE_OK;
    case CHAT1_WIRE_VERB_WANT:
        return handle_want(tls_ctx, conn_fd, shard_index, &pf.u.room_msg);
    case CHAT1_WIRE_VERB_END:
        return CHAT1_SERVE_OK;
    case CHAT1_WIRE_VERB_LIST:
        return handle_list_resp(tls_ctx, conn_fd);
    case CHAT1_WIRE_VERB_ROOM:
        chat1_presence_room_set(pf.u.room_meta.room_id, strcmp(pf.u.room_meta.visibility, "private") == 0 ? 1 : 0);
        return CHAT1_SERVE_OK;

    default:
        return CHAT1_SERVE_OK;
    }
}

static int drain_connection(void *tls_ctx, int conn_fd, uint32_t shard_index, uint64_t conn_id) {
    chat1_frame_reader *reader = (chat1_frame_reader *)calloc(1, sizeof(*reader));
    char buf[8192];
    int rc = CHAT1_SERVE_OK;

    if (!reader) return CHAT1_SERVE_ERR_READ;

    chat1_frame_reader_init(reader);

    for (;;) {
        ssize_t n = chat1_tls_read(tls_ctx, conn_fd, buf, sizeof(buf));
        const char *line;
        uint32_t line_len;
        int next_rc;

        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            rc = CHAT1_SERVE_ERR_READ;
            break;
        }

        if (chat1_frame_reader_feed(reader, buf, (uint32_t)n) != CHAT1_READER_OK) {
            rc = CHAT1_SERVE_ERR_READ;
            break;
        }

        for (;;) {
            next_rc = chat1_frame_reader_next(reader, &line, &line_len);
            if (next_rc == CHAT1_READER_HAVE_FRAME) {
                int hrc = handle_frame(tls_ctx, conn_fd, shard_index, conn_id, line, line_len);
                if (hrc != CHAT1_SERVE_OK) { rc = hrc; goto done; }
                continue;
            }
            if (next_rc == CHAT1_READER_ERR_TOO_BIG) continue;
            break;
        }
    }

done:
    free(reader);
    return rc;
}

int chat1_serve_once(int listener_fd, uint32_t shard_index) {
    int conn_fd;
    uint64_t conn_id;
    int rc;
    void *tls_ctx = NULL;

    if (listener_fd < 0) return CHAT1_SERVE_ERR_ACCEPT;

    for (;;) {
        conn_fd = accept(listener_fd, NULL, NULL);
        if (conn_fd >= 0) break;
        if (errno == EINTR) continue;
        return CHAT1_SERVE_ERR_ACCEPT;
    }

    if (chat1_conn_alloc(&conn_id) != CHAT1_CONN_OK) {
        close(conn_fd);
        return CHAT1_SERVE_ERR_DISPATCH;
    }
    if (chat1_tls_accept_fd(conn_fd, &tls_ctx) != 0) {
        chat1_conn_free(conn_id);
        close(conn_fd);
        return CHAT1_SERVE_ERR_DISPATCH;
    }

    chat1_conn_set_fd(conn_id, conn_fd);
    rc = drain_connection(tls_ctx, conn_fd, shard_index, conn_id);
    chat1_presence_on_disconnect(conn_id);
    chat1_sub_remove_all(conn_id);
    chat1_conn_free(conn_id);
    chat1_tls_close(tls_ctx);
    close(conn_fd);
    return rc;
}

int chat1_serve_loop(int listener_fd, uint32_t shard_index) {
    typedef struct {
        int fd;
        uint64_t conn_id;
        chat1_frame_reader reader;
    } chat1_ep_conn;
    struct epoll_event ev, events[64];
    chat1_ep_conn *conns = NULL;
    int epfd;

    if (listener_fd < 0) return CHAT1_SERVE_ERR_ACCEPT;
    if (chat1_tls_server_enabled()) {
        return chat1_serve_threaded(listener_fd, shard_index, 0);
    }
    conns = (chat1_ep_conn *)calloc(CHAT1_MAX_CONNECTIONS_PER_SHARD, sizeof(*conns));
    if (!conns) {
        return CHAT1_SERVE_ERR_DISPATCH;
    }
    for (uint32_t i = 0; i < CHAT1_MAX_CONNECTIONS_PER_SHARD; ++i) conns[i].fd = -1;
    epfd = epoll_create1(0);
    if (epfd < 0) {
        free(conns);
        return CHAT1_SERVE_ERR_ACCEPT;
    }
    fcntl(listener_fd, F_SETFL, fcntl(listener_fd, F_GETFL, 0) | O_NONBLOCK);
    memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN;
    ev.data.u32 = 0xFFFFFFFFu;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, listener_fd, &ev) != 0) {
        close(epfd);
        free(conns);
        return CHAT1_SERVE_ERR_ACCEPT;
    }

    for (;;) {
        int n = epoll_wait(epfd, events, 64, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(epfd);
            free(conns);
            return CHAT1_SERVE_ERR_ACCEPT;
        }
        for (int i = 0; i < n; ++i) {
            if (events[i].data.u32 == 0xFFFFFFFFu) {
                for (;;) {
                    int cfd = accept(listener_fd, NULL, NULL);
                    if (cfd < 0) break;
                    uint64_t cid;
                    if (chat1_conn_alloc(&cid) != CHAT1_CONN_OK) {
                        close(cfd);
                        continue;
                    }
                    chat1_conn_set_fd(cid, cfd);
                    int slot = -1;
                    for (uint32_t s = 0; s < CHAT1_MAX_CONNECTIONS_PER_SHARD; ++s) {
                        if (conns[s].fd < 0) { slot = (int)s; break; }
                    }
                    if (slot < 0) {
                        chat1_conn_free(cid);
                        close(cfd);
                        continue;
                    }
                    conns[slot].fd = cfd;
                    conns[slot].conn_id = cid;
                    chat1_frame_reader_init(&conns[slot].reader);
                    fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL, 0) | O_NONBLOCK);
                    memset(&ev, 0, sizeof(ev));
                    ev.events = EPOLLIN | EPOLLRDHUP | EPOLLHUP;
                    ev.data.u32 = (uint32_t)slot;
                    if (epoll_ctl(epfd, EPOLL_CTL_ADD, cfd, &ev) != 0) {
                        chat1_presence_on_disconnect(conns[slot].conn_id);
                        chat1_sub_remove_all(conns[slot].conn_id);
                        chat1_conn_free(conns[slot].conn_id);
                        close(conns[slot].fd);
                        conns[slot].fd = -1;
                    }
                }
            } else {
                uint32_t slot = events[i].data.u32;
                if (slot >= CHAT1_MAX_CONNECTIONS_PER_SHARD || conns[slot].fd < 0) continue;
                if (events[i].events & (EPOLLRDHUP | EPOLLHUP)) {
                    epoll_ctl(epfd, EPOLL_CTL_DEL, conns[slot].fd, NULL);
                    chat1_presence_on_disconnect(conns[slot].conn_id);
                    chat1_sub_remove_all(conns[slot].conn_id);
                    chat1_conn_free(conns[slot].conn_id);
                    close(conns[slot].fd);
                    conns[slot].fd = -1;
                    continue;
                }
                for (;;) {
                    char buf[8192];
                    ssize_t rn = read(conns[slot].fd, buf, sizeof(buf));
                    if (rn < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                        epoll_ctl(epfd, EPOLL_CTL_DEL, conns[slot].fd, NULL);
                        chat1_presence_on_disconnect(conns[slot].conn_id);
                        chat1_sub_remove_all(conns[slot].conn_id);
                        chat1_conn_free(conns[slot].conn_id);
                        close(conns[slot].fd);
                        conns[slot].fd = -1;
                        break;
                    }
                    if (rn == 0) {
                        epoll_ctl(epfd, EPOLL_CTL_DEL, conns[slot].fd, NULL);
                        chat1_presence_on_disconnect(conns[slot].conn_id);
                        chat1_sub_remove_all(conns[slot].conn_id);
                        chat1_conn_free(conns[slot].conn_id);
                        close(conns[slot].fd);
                        conns[slot].fd = -1;
                        break;
                    }
                    chat1_frame_reader_feed(&conns[slot].reader, buf, (uint32_t)rn);
                    for (;;) {
                        const char *line;
                        uint32_t line_len;
                        int nrc = chat1_frame_reader_next(&conns[slot].reader, &line, &line_len);
                        if (nrc == CHAT1_READER_HAVE_FRAME) {
                            handle_frame(NULL, conns[slot].fd, shard_index, conns[slot].conn_id, line, line_len);
                            continue;
                        }
                        if (nrc == CHAT1_READER_ERR_TOO_BIG) continue;
                        break;
                    }
                }
            }
        }
    }
}

typedef struct {
    int conn_fd;
    uint32_t shard_index;
    uint64_t conn_id;
    void *tls_ctx;
} chat1_thread_arg;

static void *serve_thread(void *arg) {
    chat1_thread_arg *ta = (chat1_thread_arg *)arg;
    drain_connection(ta->tls_ctx, ta->conn_fd, ta->shard_index, ta->conn_id);
    chat1_presence_on_disconnect(ta->conn_id);
    chat1_sub_remove_all(ta->conn_id);
    chat1_conn_free(ta->conn_id);
    chat1_tls_close(ta->tls_ctx);
    close(ta->conn_fd);
    free(ta);
    return NULL;
}

int chat1_serve_threaded(int listener_fd, uint32_t shard_index, int max_accept) {
    int accepted = 0;
    pthread_t *threads = NULL;
    int thread_count = 0;

    if (listener_fd < 0) return CHAT1_SERVE_ERR_ACCEPT;

    if (max_accept > 0) {
        threads = (pthread_t *)calloc((size_t)max_accept, sizeof(pthread_t));
        if (!threads) return CHAT1_SERVE_ERR_DISPATCH;
    }

    while (max_accept <= 0 || accepted < max_accept) {
        int conn_fd;
        uint64_t conn_id;
        chat1_thread_arg *ta;
        pthread_t tid;
        void *tls_ctx = NULL;

        for (;;) {
            conn_fd = accept(listener_fd, NULL, NULL);
            if (conn_fd >= 0) break;
            if (errno == EINTR) continue;
            free(threads);
            return CHAT1_SERVE_ERR_ACCEPT;
        }

        if (chat1_conn_alloc(&conn_id) != CHAT1_CONN_OK) {
            close(conn_fd);
            accepted++;
            continue;
        }
        if (chat1_tls_accept_fd(conn_fd, &tls_ctx) != 0) {
            chat1_conn_free(conn_id);
            close(conn_fd);
            accepted++;
            continue;
        }

        chat1_conn_set_fd(conn_id, conn_fd);

        ta = (chat1_thread_arg *)malloc(sizeof(*ta));
        if (!ta) {
            chat1_conn_free(conn_id);
            close(conn_fd);
            accepted++;
            continue;
        }

        ta->conn_fd = conn_fd;
        ta->shard_index = shard_index;
        ta->conn_id = conn_id;
        ta->tls_ctx = tls_ctx;

        if (pthread_create(&tid, NULL, serve_thread, ta) != 0) {
            free(ta);
            chat1_conn_free(conn_id);
            chat1_tls_close(tls_ctx);
            close(conn_fd);
            accepted++;
            continue;
        }

        if (threads) threads[thread_count++] = tid;
        accepted++;
    }

    for (int i = 0; i < thread_count; ++i) {
        pthread_join(threads[i], NULL);
    }

    free(threads);
    return CHAT1_SERVE_OK;
}
