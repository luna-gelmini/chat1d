#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "chat1_ffi.h"
#include "chat1_server_config.h"

int main(void) {
    uint64_t depth_id = 0;
    uint64_t overflow_id = 0;

    assert(chat1_conn_alloc(&depth_id) == CHAT1_CONN_OK);
    assert(depth_id != 0);
    assert(chat1_conn_queue_push(depth_id, 128) == CHAT1_CONN_OK);

    for (uint32_t i = 1; i < CHAT1_TX_QUEUE_DEPTH; ++i) {
        assert(chat1_conn_queue_push(depth_id, 1) == CHAT1_CONN_OK);
    }

    assert(chat1_conn_queue_push(depth_id, 1) == CHAT1_CONN_QUEUE_ERR_QUEUE_FULL);

    assert(chat1_conn_alloc(&overflow_id) == CHAT1_CONN_OK);
    assert(overflow_id != 0);
    assert(chat1_conn_queue_push(overflow_id, UINT32_MAX) == CHAT1_CONN_OK);
    assert(chat1_conn_queue_push(overflow_id, 1) ==
           CHAT1_CONN_QUEUE_ERR_BYTES_IN_FLIGHT_OVERFLOW);

    assert(chat1_conn_queue_push(UINT64_C(0xdeadbeef), 1) ==
           CHAT1_CONN_QUEUE_ERR_UNKNOWN_CONNECTION);

    printf("ok conn table\n");
    return 0;
}
