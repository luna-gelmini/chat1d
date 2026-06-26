#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>

#include "chat1_ffi.h"
#include "chat1_server_config.h"

typedef struct {
    uint64_t id;
    uint32_t queue_depth;
    uint32_t bytes_in_flight;
    int fd;
    int in_use;
    char author_id[CHAT1_SHA256_HEX_LEN + 1];
} chat1_conn_slot;

static chat1_conn_slot slots[CHAT1_MAX_CONNECTIONS_PER_SHARD];
static uint64_t next_id = 1;
static pthread_mutex_t conn_mu = PTHREAD_MUTEX_INITIALIZER;

static chat1_conn_slot *chat1_conn_find(uint64_t id) {
    for (uint32_t i = 0; i < CHAT1_MAX_CONNECTIONS_PER_SHARD; ++i) {
        if (slots[i].in_use && slots[i].id == id) {
            return &slots[i];
        }
    }

    return NULL;
}

int chat1_conn_alloc(uint64_t *id_out) {
    if (!id_out) {
        return CHAT1_CONN_ALLOC_ERR;
    }

    pthread_mutex_lock(&conn_mu);
    for (uint32_t i = 0; i < CHAT1_MAX_CONNECTIONS_PER_SHARD; ++i) {
        if (!slots[i].in_use) {
            slots[i].in_use = 1;
            slots[i].id = next_id++;
            slots[i].queue_depth = 0;
            slots[i].bytes_in_flight = 0;
            slots[i].fd = -1;
            slots[i].author_id[0] = '\0';
            *id_out = slots[i].id;
            pthread_mutex_unlock(&conn_mu);
            return CHAT1_CONN_OK;
        }
    }
    pthread_mutex_unlock(&conn_mu);

    return CHAT1_CONN_ALLOC_ERR;
}

int chat1_conn_queue_push(uint64_t id, uint32_t payload_len) {
    int rc = CHAT1_CONN_OK;
    pthread_mutex_lock(&conn_mu);
    chat1_conn_slot *slot = chat1_conn_find(id);

    if (!slot) {
        rc = CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
        goto done;
    }

    if (slot->queue_depth >= CHAT1_TX_QUEUE_DEPTH) {
        rc = CHAT1_CONN_QUEUE_ERR_QUEUE_FULL;
        goto done;
    }

    if (UINT32_MAX - slot->bytes_in_flight < payload_len) {
        rc = CHAT1_CONN_QUEUE_ERR_BYTES_IN_FLIGHT_OVERFLOW;
        goto done;
    }

    slot->queue_depth += 1;
    slot->bytes_in_flight += payload_len;
done:
    pthread_mutex_unlock(&conn_mu);
    return rc;
}

void chat1_conn_table_reset(void) {
    pthread_mutex_lock(&conn_mu);
    for (uint32_t i = 0; i < CHAT1_MAX_CONNECTIONS_PER_SHARD; ++i) {
        slots[i].in_use = 0;
    }
    next_id = 1;
    pthread_mutex_unlock(&conn_mu);
}

int chat1_conn_free(uint64_t id) {
    int rc = CHAT1_CONN_OK;
    pthread_mutex_lock(&conn_mu);
    chat1_conn_slot *slot = chat1_conn_find(id);
    if (!slot) {
        rc = CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
        goto done;
    }
    slot->in_use = 0;
done:
    pthread_mutex_unlock(&conn_mu);
    return rc;
}

int chat1_conn_set_fd(uint64_t id, int fd) {
    int rc = CHAT1_CONN_OK;
    pthread_mutex_lock(&conn_mu);
    chat1_conn_slot *slot = chat1_conn_find(id);
    if (!slot) {
        rc = CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
        goto done;
    }
    slot->fd = fd;
done:
    pthread_mutex_unlock(&conn_mu);
    return rc;
}

int chat1_conn_get_fd(uint64_t id, int *fd_out) {
    int rc = CHAT1_CONN_OK;
    chat1_conn_slot *slot;
    if (!fd_out) return CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
    pthread_mutex_lock(&conn_mu);
    slot = chat1_conn_find(id);
    if (!slot) {
        rc = CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
        goto done;
    }
    *fd_out = slot->fd;
done:
    pthread_mutex_unlock(&conn_mu);
    return rc;
}

int chat1_conn_set_author(uint64_t id, const char *author_id_hex) {
    int rc = CHAT1_CONN_OK;
    pthread_mutex_lock(&conn_mu);
    chat1_conn_slot *slot = chat1_conn_find(id);
    if (!slot) {
        rc = CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
        goto done;
    }
    if (!author_id_hex || author_id_hex[0] == '\0') {
        slot->author_id[0] = '\0';
    } else {
        strncpy(slot->author_id, author_id_hex, CHAT1_SHA256_HEX_LEN);
        slot->author_id[CHAT1_SHA256_HEX_LEN] = '\0';
    }
done:
    pthread_mutex_unlock(&conn_mu);
    return rc;
}

int chat1_conn_get_author(uint64_t id, char *out_hex, size_t out_len) {
    int rc = CHAT1_CONN_OK;
    if (!out_hex || out_len == 0) return CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
    pthread_mutex_lock(&conn_mu);
    chat1_conn_slot *slot = chat1_conn_find(id);
    if (!slot) {
        rc = CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
        goto done;
    }
    if (out_len <= (size_t)CHAT1_SHA256_HEX_LEN) {
        rc = CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION;
        goto done;
    }
    strncpy(out_hex, slot->author_id, out_len - 1);
    out_hex[out_len - 1] = '\0';
done:
    pthread_mutex_unlock(&conn_mu);
    return rc;
}
