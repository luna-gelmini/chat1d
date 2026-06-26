#define _POSIX_C_SOURCE 200809L

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "chat1_ffi.h"
#include "chat1_server_config.h"

#if defined(__GNUC__)
__attribute__((used))
#endif
static uint32_t (*const chat1_shard_contract_room_owner_ref)(const char *, uint32_t) =
    chat1_room_owner;

int chat1_listener_open(int port);

static int parse_int_env(const char *name, int fallback) {
    const char *v = getenv(name);
    if (!v || !*v) return fallback;
    return atoi(v);
}

int main(void) {
    int listener_fd;
    int port = parse_int_env("CHAT1_PORT", CHAT1_DEFAULT_PORT);
    uint32_t shard_index = (uint32_t)parse_int_env("CHAT1_SHARD_INDEX", 0);

    signal(SIGPIPE, SIG_IGN);

    if (chat1_tls_init() != 0) {
        fprintf(stderr, "chat1d: tls init failed\n");
        return 1;
    }
    chat1_auth_keys_init();
    chat1_presence_init();
    if (chat1_tls_server_config_from_env() != 0) {
        fprintf(stderr, "chat1d: tls server config failed (set CHAT1_TLS_CERT and CHAT1_TLS_KEY)\n");
        return 1;
    }

    chat1_room_engine_init_c(CHAT1_ROOM_CAPACITY, CHAT1_BODY_ARENA_BYTES);

    listener_fd = chat1_listener_open(port);
    if (listener_fd < 0) {
        fprintf(stderr, "chat1d: listener open failed on port %d\n", port);
        return 1;
    }

    fprintf(stderr, "chat1d: shard=%u listening on port %d\n", shard_index, port);

    if (chat1_serve_loop(listener_fd, shard_index) != CHAT1_SERVE_OK) {
        fprintf(stderr, "chat1d: serve loop terminated with error\n");
        close(listener_fd);
        return 1;
    }

    close(listener_fd);
    return 0;
}
