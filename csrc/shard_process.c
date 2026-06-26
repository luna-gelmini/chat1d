#include <stdint.h>

#include "chat1_ffi.h"

int chat1_ingress_dispatch(const chat1_ingress_batch *batch);

static uint64_t chat1_hash_room(const char *room_id) {
    uint64_t h = 1469598103934665603ULL;

    if (!room_id) {
        return h;
    }

    while (*room_id) {
        h ^= (unsigned char)*room_id++;
        h *= 1099511628211ULL;
    }

    return h;
}

uint32_t chat1_room_owner(const char *room_id, uint32_t shard_count) {
    if (shard_count == 0) {
        return CHAT1_SHARD_OWNER_INVALID;
    }

    return (uint32_t)(chat1_hash_room(room_id) % shard_count);
}

int chat1_shard_process_batch(const chat1_ingress_batch *batch) {
    if (!batch) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    return chat1_ingress_dispatch(batch);
}
