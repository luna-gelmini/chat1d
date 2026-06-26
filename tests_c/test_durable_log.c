#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "chat1_ffi.h"

static void chat1_build_test_path(char *buf, size_t buf_size) {
    int written = snprintf(buf, buf_size, "/tmp/chat1-durable-log-%ld.log", (long)getpid());
    assert(written > 0);
    assert((size_t)written < buf_size);
}

static void chat1_fill_event(chat1_ingress_event *event,
                             const char *room_id,
                             const char *msg_id,
                             const char *author_id,
                             uint64_t ts_ms,
                             const char *body_b64,
                             const char *sig_b64) {
    size_t body_len = strlen(body_b64);

    memset(event, 0, sizeof(*event));
    event->ts_ms = ts_ms;
    event->body_len = (uint32_t)body_len;
    memcpy(event->room_id, room_id, strlen(room_id));
    memcpy(event->msg_id, msg_id, strlen(msg_id));
    memcpy(event->author_id, author_id, strlen(author_id));
    memcpy(event->body_b64, body_b64, body_len);
    memcpy(event->sig_b64, sig_b64, strlen(sig_b64));
}

static size_t chat1_expected_record(char *buf, size_t buf_size, const chat1_ingress_event *event) {
    int written = snprintf(buf,
                           buf_size,
                           "MSG\t%s\t%s\t%s\t%llu\t%s\t%s\n",
                           event->room_id,
                           event->msg_id,
                           event->author_id,
                           (unsigned long long)event->ts_ms,
                           event->body_b64,
                           event->sig_b64);

    assert(written > 0);
    assert((size_t)written < buf_size);
    return (size_t)written;
}

static void chat1_test_rejects_empty_path(void) {
    chat1_ingress_event event;

    chat1_fill_event(&event,
                     "#general",
                     "msg-empty-path",
                     "author-empty-path",
                     1770000123456ULL,
                     "x",
                     "sig-empty-path");

    assert(chat1_log_open("") == CHAT1_LOG_ERR_OPEN);
    assert(chat1_log_append_event("", &event) == CHAT1_LOG_ERR_OPEN);
}

static void chat1_test_append_event_creates_missing_file(void) {
    chat1_ingress_event event;
    char path[128];
    char expected[256];
    char contents[256];
    size_t expected_len;
    ssize_t read_len;
    int fd;

    chat1_fill_event(&event,
                     "#general",
                     "msg-hello",
                     "author-hello",
                     1770000123456ULL,
                     "hello",
                     "sig-hello");
    expected_len = chat1_expected_record(expected, sizeof(expected), &event);
    chat1_build_test_path(path, sizeof(path));
    unlink(path);

    assert(chat1_log_append_event(path, &event) == 0);

    fd = open(path, O_RDONLY);
    assert(fd >= 0);
    read_len = read(fd, contents, sizeof(contents));
    assert(read_len == (ssize_t)expected_len);
    assert(close(fd) == 0);

    assert(memcmp(contents, expected, expected_len) == 0);
    assert(unlink(path) == 0);
}

int main(void) {
    chat1_ingress_event first;
    chat1_ingress_event second;
    char first_expected[256];
    char second_expected[256];
    size_t first_expected_len;
    size_t second_expected_len;
    char path[128];
    char contents[512];
    ssize_t read_len;
    int fd;

    chat1_test_rejects_empty_path();
    chat1_test_append_event_creates_missing_file();

    chat1_fill_event(&first,
                     "#general",
                     "msg-hello",
                     "author-hello",
                     1770000123456ULL,
                     "hello",
                     "sig-hello");
    chat1_fill_event(&second,
                     "#general",
                     "msg-world",
                     "author-world",
                     1770000123457ULL,
                     "world",
                     "sig-world");
    first_expected_len = chat1_expected_record(first_expected, sizeof(first_expected), &first);
    second_expected_len = chat1_expected_record(second_expected, sizeof(second_expected), &second);
    chat1_build_test_path(path, sizeof(path));
    unlink(path);

    assert(chat1_log_open(path) == 0);
    assert(chat1_log_append_event(path, &first) == 0);
    assert(chat1_log_append_event(path, &second) == 0);

    fd = open(path, O_RDONLY);
    assert(fd >= 0);
    read_len = read(fd, contents, sizeof(contents));
    assert(read_len == (ssize_t)(first_expected_len + second_expected_len));
    assert(close(fd) == 0);

    assert(memcmp(contents, first_expected, first_expected_len) == 0);
    assert(memcmp(contents + first_expected_len, second_expected, second_expected_len) == 0);
    assert(unlink(path) == 0);

    printf("ok durable log\n");
    return 0;
}
