#include <stdint.h>
#include <string.h>
#include <pthread.h>

#include "chat1_ffi.h"

typedef struct {
    uint64_t room_hash;
    uint64_t conn_ids[CHAT1_MAX_SUBS_PER_ROOM];
    uint32_t count;
    int in_use;
} chat1_room_sub;

static chat1_room_sub rooms[CHAT1_MAX_ROOMS];
static pthread_mutex_t rooms_mu = PTHREAD_MUTEX_INITIALIZER;

void chat1_sub_table_init(void) {
    pthread_mutex_lock(&rooms_mu);
    memset(rooms, 0, sizeof(rooms));
    pthread_mutex_unlock(&rooms_mu);
}

static chat1_room_sub *find_room(uint64_t room_hash) {
    for (uint32_t i = 0; i < CHAT1_MAX_ROOMS; ++i) {
        if (rooms[i].in_use && rooms[i].room_hash == room_hash) {
            return &rooms[i];
        }
    }
    return NULL;
}

static chat1_room_sub *alloc_room(uint64_t room_hash) {
    for (uint32_t i = 0; i < CHAT1_MAX_ROOMS; ++i) {
        if (!rooms[i].in_use) {
            rooms[i].in_use = 1;
            rooms[i].room_hash = room_hash;
            rooms[i].count = 0;
            return &rooms[i];
        }
    }
    return NULL;
}

int chat1_sub_add(uint64_t room_hash, uint64_t conn_id) {
    int rc = CHAT1_SUB_OK;
    pthread_mutex_lock(&rooms_mu);
    chat1_room_sub *r = find_room(room_hash);
    if (!r) {
        r = alloc_room(room_hash);
        if (!r) {
            rc = CHAT1_SUB_ERR_FULL;
            goto done;
        }
    }

    for (uint32_t i = 0; i < r->count; ++i) {
        if (r->conn_ids[i] == conn_id) {
            rc = CHAT1_SUB_ERR_DUPLICATE;
            goto done;
        }
    }

    if (r->count >= CHAT1_MAX_SUBS_PER_ROOM) {
        rc = CHAT1_SUB_ERR_FULL;
        goto done;
    }

    r->conn_ids[r->count++] = conn_id;
done:
    pthread_mutex_unlock(&rooms_mu);
    return rc;
}

int chat1_sub_remove(uint64_t room_hash, uint64_t conn_id) {
    int rc = CHAT1_SUB_ERR_NOT_FOUND;
    pthread_mutex_lock(&rooms_mu);
    chat1_room_sub *r = find_room(room_hash);
    if (!r) goto done;

    for (uint32_t i = 0; i < r->count; ++i) {
        if (r->conn_ids[i] == conn_id) {
            r->conn_ids[i] = r->conn_ids[r->count - 1];
            r->count--;
            if (r->count == 0) r->in_use = 0;
            rc = CHAT1_SUB_OK;
            goto done;
        }
    }
done:
    pthread_mutex_unlock(&rooms_mu);
    return rc;
}

void chat1_sub_remove_all(uint64_t conn_id) {
    pthread_mutex_lock(&rooms_mu);
    for (uint32_t i = 0; i < CHAT1_MAX_ROOMS; ++i) {
        if (!rooms[i].in_use) continue;
        for (uint32_t j = 0; j < rooms[i].count; ++j) {
            if (rooms[i].conn_ids[j] == conn_id) {
                rooms[i].conn_ids[j] = rooms[i].conn_ids[rooms[i].count - 1];
                rooms[i].count--;
                if (rooms[i].count == 0) rooms[i].in_use = 0;
                break;
            }
        }
    }
    pthread_mutex_unlock(&rooms_mu);
}

void chat1_sub_rooms_for_conn(uint64_t conn_id, uint64_t *hashes_out, uint32_t max, uint32_t *n_out) {
    if (!hashes_out || !n_out || max == 0) return;
    *n_out = 0;
    pthread_mutex_lock(&rooms_mu);
    for (uint32_t i = 0; i < CHAT1_MAX_ROOMS; ++i) {
        if (!rooms[i].in_use) continue;
        for (uint32_t j = 0; j < rooms[i].count; ++j) {
            if (rooms[i].conn_ids[j] == conn_id) {
                if (*n_out < max) {
                    hashes_out[*n_out] = rooms[i].room_hash;
                    (*n_out)++;
                }
                break;
            }
        }
    }
    pthread_mutex_unlock(&rooms_mu);
}

int chat1_sub_list(uint64_t room_hash, uint64_t *out, uint32_t max, uint32_t *count) {
    chat1_room_sub *r;

    if (!out || !count) return CHAT1_SUB_ERR_NOT_FOUND;

    pthread_mutex_lock(&rooms_mu);
    *count = 0;
    r = find_room(room_hash);
    if (!r) {
        pthread_mutex_unlock(&rooms_mu);
        return CHAT1_SUB_OK;
    }

    uint32_t n = r->count < max ? r->count : max;
    memcpy(out, r->conn_ids, n * sizeof(uint64_t));
    *count = n;
    pthread_mutex_unlock(&rooms_mu);
    return CHAT1_SUB_OK;
}
