#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "chat1_ffi.h"

static int chat1_engine_called = 0;
static int chat1_fanout_called = 0;

static int chat1_contains_bytes(const char *haystack, size_t haystack_len, const char *needle, size_t needle_len) {
    size_t i;

    if (needle_len == 0) {
        return 1;
    }

    if (haystack_len < needle_len) {
        return 0;
    }

    for (i = 0; i + needle_len <= haystack_len; ++i) {
        if (memcmp(haystack + i, needle, needle_len) == 0) {
            return 1;
        }
    }

    return 0;
}

int chat1_engine_ingest_batch(const chat1_ingress_batch *batch,
                              chat1_fanout_desc *fanout_out,
                              uint32_t *fanout_count) {
    assert(batch != NULL);
    assert(fanout_out != NULL);
    assert(fanout_count != NULL);
    assert(batch->local_count == 1);
    assert(batch->shard_index == 7);
    assert(batch->events[0].body_len == 5);
    assert(memcmp(batch->events[0].body_b64, "hello", 5) == 0);

    chat1_engine_called = 1;
    fanout_out[0].target_connection_id = 42;
    fanout_out[0].payload_len = 5;
    *fanout_count = 1;
    return CHAT1_ROUTE_OK;
}

int chat1_fanout_send(const chat1_fanout_desc *fanout, uint32_t fanout_count) {
    char buf[256];
    ssize_t read_len;
    int fd;

    assert(chat1_engine_called == 1);
    assert(fanout != NULL);
    assert(fanout_count == 1);
    assert(fanout[0].target_connection_id == 42);
    assert(fanout[0].payload_len == 5);

    fd = open("/tmp/chat1-shard-7.log", O_RDONLY);
    assert(fd >= 0);
    read_len = read(fd, buf, sizeof(buf));
    assert(read_len > 0);
    assert(close(fd) == 0);

    assert(chat1_contains_bytes(buf, (size_t)read_len, "MSG\t", 4) == 1);
    assert(chat1_contains_bytes(buf, (size_t)read_len, "\thello\t", 7) == 1);
    assert(buf[read_len - 1] == '\n');

    chat1_fanout_called = 1;
    return CHAT1_ROUTE_OK;
}

int chat1_fanout_attach_to_subscribers(uint64_t room_hash, const chat1_attach_event *ev) {
    (void)room_hash;
    (void)ev;
    return CHAT1_ROUTE_OK;
}

int main(void) {
    chat1_ingress_batch batch = {0};

    batch.shard_index = 7;
    batch.local_count = 1;
    batch.events[0].ts_ms = 1770000123456ULL;
    batch.events[0].body_len = 5;
    memcpy(batch.events[0].room_id, "#general", 8);
    memcpy(batch.events[0].msg_id, "msg-hello", 9);
    memcpy(batch.events[0].author_id, "author-hello", 12);
    memcpy(batch.events[0].body_b64, "hello", 5);
    memcpy(batch.events[0].sig_b64, "sig-hello", 9);

    unlink("/tmp/chat1-shard-7.log");
    assert(chat1_shard_process_batch(&batch) == CHAT1_ROUTE_OK);
    assert(chat1_engine_called == 1);
    assert(chat1_fanout_called == 1);
    assert(unlink("/tmp/chat1-shard-7.log") == 0);
    printf("ok durable before fanout\n");
    return 0;
}
