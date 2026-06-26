#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "chat1_ffi.h"

static int write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

int chat1_fanout_send(const chat1_fanout_desc *fanout, uint32_t fanout_count) {
    if (fanout_count > 0 && !fanout) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    return CHAT1_ROUTE_OK;
}

int chat1_fanout_msg_to_subscribers(uint64_t room_hash, const chat1_ingress_event *ev) {
    uint64_t subs[CHAT1_MAX_SUBS_PER_ROOM];
    uint32_t sub_count = 0;
    char frame_buf[CHAT1_WIRE_MAX_LINE + 2];
    int frame_len;

    if (!ev) return CHAT1_ROUTE_ERR_INVALID;

    chat1_sub_list(room_hash, subs, CHAT1_MAX_SUBS_PER_ROOM, &sub_count);
    if (sub_count == 0) return CHAT1_ROUTE_OK;

    frame_len = snprintf(frame_buf, sizeof(frame_buf),
        "MSG\t%s\t%s\t%s\t%lu\t%s\t%s\n",
        ev->room_id, ev->msg_id, ev->author_id,
        (unsigned long)ev->ts_ms,
        ev->body_b64, ev->sig_b64);

    if (frame_len <= 0 || (size_t)frame_len >= sizeof(frame_buf)) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    for (uint32_t i = 0; i < sub_count; ++i) {
        int fd = -1;
        if (chat1_conn_get_fd(subs[i], &fd) != CHAT1_CONN_OK || fd < 0) continue;
        write_all(fd, frame_buf, (size_t)frame_len);
    }

    return CHAT1_ROUTE_OK;
}

int chat1_fanout_attach_to_subscribers(uint64_t room_hash, const chat1_attach_event *ev) {
    uint64_t subs[CHAT1_MAX_SUBS_PER_ROOM];
    uint32_t sub_count = 0;
    char frame_buf[CHAT1_WIRE_MAX_LINE + 2];
    int frame_len;

    if (!ev) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    chat1_sub_list(room_hash, subs, CHAT1_MAX_SUBS_PER_ROOM, &sub_count);
    if (sub_count == 0) {
        return CHAT1_ROUTE_OK;
    }

    frame_len = snprintf(frame_buf, sizeof(frame_buf),
                         "ATTACH\t%s\t%s\t%s\t%llu\t%s\t%llu\t%s\t%s\t%s\n",
                         ev->room_id,
                         ev->msg_id,
                         ev->author_id,
                         (unsigned long long)ev->ts_ms,
                         ev->cid_hex,
                         (unsigned long long)ev->byte_len,
                         ev->mime,
                         ev->filename,
                         ev->sig_b64);

    if (frame_len <= 0 || (size_t)frame_len >= sizeof(frame_buf)) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    for (uint32_t i = 0; i < sub_count; ++i) {
        int fd = -1;
        if (chat1_conn_get_fd(subs[i], &fd) != CHAT1_CONN_OK || fd < 0) {
            continue;
        }
        write_all(fd, frame_buf, (size_t)frame_len);
    }

    return CHAT1_ROUTE_OK;
}
