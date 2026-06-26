#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "chat1_ffi.h"

void chat1_frame_reader_init(chat1_frame_reader *r) {
    if (!r) {
        return;
    }
    r->fill = 0;
    r->scan = 0;
    r->skipping = 0;
    r->too_big_pending = 0;
}

static void reader_compact_pending(chat1_frame_reader *r) {
    if (r->scan == 0) {
        return;
    }
    if (r->scan >= r->fill) {
        r->fill = 0;
        r->scan = 0;
        return;
    }
    memmove(r->buf, r->buf + r->scan, r->fill - r->scan);
    r->fill -= r->scan;
    r->scan = 0;
}

int chat1_frame_reader_feed(chat1_frame_reader *r, const void *data, uint32_t len) {
    const char *src;
    uint32_t i;

    if (!r || (!data && len > 0)) {
        return CHAT1_READER_ERR_NULL;
    }

    reader_compact_pending(r);

    src = (const char *)data;

    for (i = 0; i < len; ++i) {
        char c = src[i];

        if (r->skipping) {
            if (c == '\n') {
                r->skipping = 0;
                r->too_big_pending = 1;
            }
            continue;
        }

        if (r->fill >= CHAT1_WIRE_MAX_LINE && c != '\n') {
            r->fill = 0;
            r->skipping = 1;
            continue;
        }

        r->buf[r->fill++] = c;
    }

    return CHAT1_READER_OK;
}

int chat1_frame_reader_next(chat1_frame_reader *r, const char **line_out, uint32_t *line_len_out) {
    uint32_t i;

    if (!r || !line_out || !line_len_out) {
        return CHAT1_READER_ERR_NULL;
    }

    reader_compact_pending(r);

    if (r->too_big_pending) {
        r->too_big_pending = 0;
        *line_out = NULL;
        *line_len_out = 0;
        return CHAT1_READER_ERR_TOO_BIG;
    }

    for (i = 0; i < r->fill; ++i) {
        if (r->buf[i] == '\n') {
            *line_out = r->buf;
            *line_len_out = i;
            r->scan = i + 1;
            return CHAT1_READER_HAVE_FRAME;
        }
    }

    *line_out = NULL;
    *line_len_out = 0;
    return CHAT1_READER_NO_FRAME;
}
