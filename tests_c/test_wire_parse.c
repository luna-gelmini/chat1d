#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "chat1_ffi.h"

static const char ROOM[]  = "#general";
static const char MSGID[] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
static const char AUTH[]  = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
static const char BODY[]  = "aGVsbG8";
static const char SIG[]   = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

static int build_msg(char *buf, size_t cap,
                     const char *room, const char *msgid, const char *auth,
                     const char *ts, const char *body, const char *sig) {
    int n = snprintf(buf, cap, "MSG\t%s\t%s\t%s\t%s\t%s\t%s",
                     room, msgid, auth, ts, body, sig);
    assert(n > 0 && (size_t)n < cap);
    return n;
}

static void test_valid_msg(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1770000000123", BODY, SIG);

    int rc = chat1_parse_msg_frame(line, (uint32_t)n, &ev);
    assert(rc == CHAT1_WIRE_OK);
    assert(strcmp(ev.room_id, ROOM) == 0);
    assert(strcmp(ev.msg_id, MSGID) == 0);
    assert(strcmp(ev.author_id, AUTH) == 0);
    assert(strcmp(ev.body_b64, BODY) == 0);
    assert(strcmp(ev.sig_b64, SIG) == 0);
    assert(ev.ts_ms == 1770000000123ULL);
    assert(ev.body_len == strlen(BODY));
    assert(ev.room_hash != 0);
    assert(ev.connection_id == 0);
    printf("ok valid msg\n");
}

static void test_ts_zero(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "0", BODY, SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_OK);
    assert(ev.ts_ms == 0);
    printf("ok ts zero\n");
}

static void test_ts_leading_zero(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "01", BODY, SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_FIELD_FORMAT);
    printf("ok ts leading zero rejected\n");
}

static void test_crlf_tolerated(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1", BODY, SIG);
    line[n] = '\r';
    line[n + 1] = '\0';
    assert(chat1_parse_msg_frame(line, (uint32_t)(n + 1), &ev) == CHAT1_WIRE_OK);
    printf("ok trailing CR tolerated\n");
}

static void test_embedded_lf_rejected(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1", BODY, SIG);
    line[5] = '\n';
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_BAD_FRAME);
    printf("ok embedded LF rejected\n");
}

static void test_too_few_fields(void) {
    const char *line = "MSG\t#general\tabc";
    chat1_ingress_event ev;
    assert(chat1_parse_msg_frame(line, (uint32_t)strlen(line), &ev) == CHAT1_WIRE_ERR_BAD_FRAME);
    printf("ok too few fields rejected\n");
}

static void test_too_many_fields(void) {
    char line[1024];
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1", BODY, SIG);
    n += snprintf(line + n, sizeof(line) - n, "\textra");
    chat1_ingress_event ev;
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_BAD_FRAME);
    printf("ok too many fields rejected\n");
}

static void test_unsupported_verb(void) {
    const char *line = "PING\t1";
    chat1_ingress_event ev;
    assert(chat1_parse_msg_frame(line, (uint32_t)strlen(line), &ev) == CHAT1_WIRE_ERR_UNSUPPORTED_VERB);
    printf("ok unsupported verb rejected\n");
}

static void test_empty_field(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1", "", SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_BAD_FRAME);
    printf("ok empty body rejected\n");
}

static void test_bad_msg_id_len(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, "deadbeef", AUTH, "1", BODY, SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_FIELD_LEN);
    printf("ok short msg_id rejected\n");
}

static void test_bad_msg_id_charset(void) {
    char bad[65];
    memset(bad, 'g', 64);
    bad[64] = '\0';
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, bad, AUTH, "1", BODY, SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_FIELD_FORMAT);
    printf("ok bad msg_id charset rejected\n");
}

static void test_bad_room_charset(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), "bad room", MSGID, AUTH, "1", BODY, SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_FIELD_FORMAT);
    printf("ok bad room charset rejected\n");
}

static void test_bad_sig_len(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1", BODY, "AAA");
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_FIELD_LEN);
    printf("ok short sig rejected\n");
}

static void test_bad_body_charset(void) {
    char line[1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1", "has space", SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_FIELD_FORMAT);
    printf("ok bad body charset rejected\n");
}

static void test_null_inputs(void) {
    chat1_ingress_event ev;
    char line[16] = "MSG\t";
    assert(chat1_parse_msg_frame(NULL, 4, &ev) == CHAT1_WIRE_ERR_NULL);
    assert(chat1_parse_msg_frame(line, 4, NULL) == CHAT1_WIRE_ERR_NULL);
    printf("ok null inputs rejected\n");
}

static void test_no_tab(void) {
    const char *line = "MSGonly";
    chat1_ingress_event ev;
    assert(chat1_parse_msg_frame(line, (uint32_t)strlen(line), &ev) == CHAT1_WIRE_ERR_BAD_FRAME);
    printf("ok no tab rejected\n");
}

static void test_oversize_body(void) {
    char body[CHAT1_MAX_BODY_BYTES + 2];
    memset(body, 'A', sizeof(body) - 1);
    body[sizeof(body) - 1] = '\0';
    char line[CHAT1_MAX_BODY_BYTES + 1024];
    chat1_ingress_event ev;
    int n = build_msg(line, sizeof(line), ROOM, MSGID, AUTH, "1", body, SIG);
    assert(chat1_parse_msg_frame(line, (uint32_t)n, &ev) == CHAT1_WIRE_ERR_FIELD_LEN);
    printf("ok oversize body rejected\n");
}

int main(void) {
    test_valid_msg();
    test_ts_zero();
    test_ts_leading_zero();
    test_crlf_tolerated();
    test_embedded_lf_rejected();
    test_too_few_fields();
    test_too_many_fields();
    test_unsupported_verb();
    test_empty_field();
    test_bad_msg_id_len();
    test_bad_msg_id_charset();
    test_bad_room_charset();
    test_bad_sig_len();
    test_bad_body_charset();
    test_null_inputs();
    test_no_tab();
    test_oversize_body();
    printf("ok wire parse\n");
    return 0;
}
