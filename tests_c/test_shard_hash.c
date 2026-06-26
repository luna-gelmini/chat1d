#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "chat1_ffi.h"

static uint32_t init_max_events = 0;
static uint32_t init_max_body_bytes = 0;

int chat1_engine_ingest_batch(const chat1_ingress_batch *batch, chat1_fanout_desc *fanout_out, uint32_t *fanout_count) {
    assert(batch != NULL);
    assert(fanout_out != NULL);
    assert(fanout_count != NULL);
    *fanout_count = 0;
    return CHAT1_ROUTE_ERR_UNIMPLEMENTED;
}

void chat1_room_engine_init_c(uint32_t max_events, uint32_t max_body_bytes) {
    init_max_events = max_events;
    init_max_body_bytes = max_body_bytes;
}

int main(void) {
    chat1_ingress_batch batch = {0};
    uint32_t a = chat1_room_owner("#general", 4);
    uint32_t b = chat1_room_owner("#general", 4);
    uint32_t c = chat1_room_owner("#random", 4);

    chat1_room_engine_init_c(16, 4096);

    assert(a < 4);
    assert(b < 4);
    assert(c < 4);
    assert(a == b);
    assert(chat1_room_owner("#general", 0) == CHAT1_SHARD_OWNER_INVALID);
    assert(init_max_events == 16);
    assert(init_max_body_bytes == 4096);
    assert(chat1_shard_process_batch(NULL) == CHAT1_ROUTE_ERR_INVALID);
    assert(chat1_shard_process_batch(&batch) == CHAT1_ROUTE_ERR_UNIMPLEMENTED);
    assert(chat1_route_batch_to_owner(NULL) == CHAT1_ROUTE_ERR_INVALID);
    assert(chat1_route_batch_to_owner(&batch) == CHAT1_ROUTE_ERR_UNIMPLEMENTED);
    printf("ok shard hash\n");
    return 0;
}
