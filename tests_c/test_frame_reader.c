#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "chat1_ffi.h"

static int feed_str(chat1_frame_reader *r, const char *s) {
    return chat1_frame_reader_feed(r, s, (uint32_t)strlen(s));
}

static void test_init_empty(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;

    chat1_frame_reader_init(&r);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_NO_FRAME);
    printf("ok init empty\n");
}

static void test_single_frame(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;

    chat1_frame_reader_init(&r);
    assert(feed_str(&r, "hello\n") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 5);
    assert(memcmp(line, "hello", 5) == 0);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_NO_FRAME);
    printf("ok single frame\n");
}

static void test_multiple_frames_one_feed(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;

    chat1_frame_reader_init(&r);
    assert(feed_str(&r, "a\nbb\nccc\n") == CHAT1_READER_OK);

    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 1 && line[0] == 'a');

    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 2 && memcmp(line, "bb", 2) == 0);

    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 3 && memcmp(line, "ccc", 3) == 0);

    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_NO_FRAME);
    printf("ok multiple frames one feed\n");
}

static void test_split_across_feeds(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;

    chat1_frame_reader_init(&r);
    assert(feed_str(&r, "par") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_NO_FRAME);

    assert(feed_str(&r, "tial\nmore") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 7 && memcmp(line, "partial", 7) == 0);

    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_NO_FRAME);

    assert(feed_str(&r, "\n") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 4 && memcmp(line, "more", 4) == 0);
    printf("ok split across feeds\n");
}

static void test_byte_at_a_time(void) {
    chat1_frame_reader r;
    const char *src = "byte\n";
    const char *line;
    uint32_t len;
    size_t i;

    chat1_frame_reader_init(&r);
    for (i = 0; i < strlen(src); ++i) {
        assert(chat1_frame_reader_feed(&r, src + i, 1) == CHAT1_READER_OK);
    }
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 4 && memcmp(line, "byte", 4) == 0);
    printf("ok byte at a time\n");
}

static void test_crlf_kept_in_line(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;

    chat1_frame_reader_init(&r);
    assert(feed_str(&r, "abc\r\n") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 4);
    assert(line[3] == '\r');
    printf("ok crlf preserved for parser\n");
}

static void test_oversize_then_recover(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;
    size_t big_len = CHAT1_WIRE_MAX_LINE + 100;
    char *big = malloc(big_len + 2);
    assert(big);
    memset(big, 'X', big_len);
    big[big_len] = '\n';
    big[big_len + 1] = '\0';

    chat1_frame_reader_init(&r);
    assert(chat1_frame_reader_feed(&r, big, (uint32_t)(big_len + 1)) == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_ERR_TOO_BIG);

    assert(feed_str(&r, "next\n") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 4 && memcmp(line, "next", 4) == 0);

    free(big);
    printf("ok oversize then recover\n");
}

static void test_oversize_split_feeds(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;
    char chunk[1024];
    size_t total;

    memset(chunk, 'Y', sizeof(chunk));
    chat1_frame_reader_init(&r);

    total = 0;
    while (total < (size_t)CHAT1_WIRE_MAX_LINE + 5000) {
        assert(chat1_frame_reader_feed(&r, chunk, sizeof(chunk)) == CHAT1_READER_OK);
        total += sizeof(chunk);
        assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_NO_FRAME ||
               r.too_big_pending == 0);
    }
    assert(feed_str(&r, "\n") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_ERR_TOO_BIG);

    assert(feed_str(&r, "ok\n") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 2 && memcmp(line, "ok", 2) == 0);
    printf("ok oversize split feeds\n");
}

static void test_empty_line(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;

    chat1_frame_reader_init(&r);
    assert(feed_str(&r, "\n") == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == 0);
    printf("ok empty line\n");
}

static void test_max_size_line_fits(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;
    char *big = malloc(CHAT1_WIRE_MAX_LINE + 2);
    assert(big);
    memset(big, 'M', CHAT1_WIRE_MAX_LINE);
    big[CHAT1_WIRE_MAX_LINE] = '\n';

    chat1_frame_reader_init(&r);
    assert(chat1_frame_reader_feed(&r, big, CHAT1_WIRE_MAX_LINE + 1) == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(len == CHAT1_WIRE_MAX_LINE);

    free(big);
    printf("ok max size line fits\n");
}

static void test_null_inputs(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;

    chat1_frame_reader_init(&r);
    assert(chat1_frame_reader_feed(NULL, "x", 1) == CHAT1_READER_ERR_NULL);
    assert(chat1_frame_reader_feed(&r, NULL, 1) == CHAT1_READER_ERR_NULL);
    assert(chat1_frame_reader_feed(&r, NULL, 0) == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(NULL, &line, &len) == CHAT1_READER_ERR_NULL);
    assert(chat1_frame_reader_next(&r, NULL, &len) == CHAT1_READER_ERR_NULL);
    assert(chat1_frame_reader_next(&r, &line, NULL) == CHAT1_READER_ERR_NULL);
    printf("ok null inputs\n");
}

static void test_parser_integration(void) {
    chat1_frame_reader r;
    const char *line;
    uint32_t len;
    chat1_ingress_event ev;
    char frame[1024];
    int n = snprintf(frame, sizeof(frame),
        "MSG\t#general\t%s\t%s\t1770000000000\taGVsbG8\t%s\n",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    assert(n > 0 && (size_t)n < sizeof(frame));

    chat1_frame_reader_init(&r);
    assert(chat1_frame_reader_feed(&r, frame, (uint32_t)n) == CHAT1_READER_OK);
    assert(chat1_frame_reader_next(&r, &line, &len) == CHAT1_READER_HAVE_FRAME);
    assert(chat1_parse_msg_frame(line, len, &ev) == CHAT1_WIRE_OK);
    assert(strcmp(ev.room_id, "#general") == 0);
    assert(ev.ts_ms == 1770000000000ULL);
    printf("ok parser integration\n");
}

int main(void) {
    test_init_empty();
    test_single_frame();
    test_multiple_frames_one_feed();
    test_split_across_feeds();
    test_byte_at_a_time();
    test_crlf_kept_in_line();
    test_oversize_then_recover();
    test_oversize_split_feeds();
    test_empty_line();
    test_max_size_line_fits();
    test_null_inputs();
    test_parser_integration();
    printf("ok frame reader\n");
    return 0;
}
