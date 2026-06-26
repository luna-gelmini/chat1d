#include <stdint.h>
#include <stdio.h>

#include "chat1_ffi.h"

int chat1_fanout_send(const chat1_fanout_desc *fanout, uint32_t fanout_count);

int chat1_attach_dispatch(uint32_t shard_index, const chat1_attach_event *ev) {
    char path[64];
    int rc;

    if (!ev) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    rc = chat1_shard_log_path(shard_index, path, sizeof(path));
    if (rc != CHAT1_LOG_OK) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    rc = chat1_log_append_attach_event(path, ev);
    if (rc != CHAT1_LOG_OK) {
        return rc;
    }

    return chat1_fanout_attach_to_subscribers(ev->room_hash, ev);
}

static int chat1_commit_then_fanout(uint32_t shard_index,
                                    const chat1_ingress_batch *batch,
                                    const chat1_fanout_desc *fanout,
                                    uint32_t fanout_count) {
    char path[64];
    int rc = chat1_shard_log_path(shard_index, path, sizeof(path));
    uint32_t i;

    if (rc != CHAT1_LOG_OK) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    for (i = 0; i < batch->local_count; ++i) {
        rc = chat1_log_append_event(path, &batch->events[i]);
        if (rc != CHAT1_LOG_OK) {
            return rc;
        }
    }

    return chat1_fanout_send(fanout, fanout_count);
}

int chat1_ingress_dispatch(const chat1_ingress_batch *batch) {
    chat1_fanout_desc fanout[CHAT1_MAX_FANOUT];
    uint32_t fanout_count = 0;
    int rc;

    if (!batch) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    rc = chat1_engine_ingest_batch(batch, fanout, &fanout_count);
    if (rc != CHAT1_ROUTE_OK) {
        return rc;
    }

    if (batch->local_count == 0) {
        return CHAT1_ROUTE_OK;
    }

    return chat1_commit_then_fanout(batch->shard_index,
                                    batch,
                                    fanout,
                                    fanout_count);
}
