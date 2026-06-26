#include <stdio.h>
#include <string.h>
#include <assert.h>

#include "chat1_ffi.h"

static int tests_run = 0;
static int tests_passed = 0;

#define RUN(name) do { \
    printf("  %s ... ", #name); \
    name(); \
    printf("ok\n"); \
    tests_passed++; \
    tests_run++; \
} while(0)

static void test_hello_valid(void) {
    const char *frame = "HELLO\talice\t1\tabc123";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_HELLO);
    assert(strcmp(pf.u.hello.client_id, "alice") == 0);
    assert(pf.u.hello.protocol_version == 1);
    assert(strcmp(pf.u.hello.nonce, "abc123") == 0);
}

static void test_hello_missing_nonce(void) {
    const char *frame = "HELLO\talice\t1";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_BAD_FRAME);
}

static void test_hello_extra_field(void) {
    const char *frame = "HELLO\talice\t1\tnonce\textra";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_FIELD_LEN);
}

static void test_hello_empty_client_id(void) {
    const char *frame = "HELLO\t\t1\tnonce";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_FIELD_LEN);
}

static void test_hello_bad_version(void) {
    const char *frame = "HELLO\talice\txyz\tnonce";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_FIELD_FORMAT);
}

static void test_hello_with_pubkey(void) {
    const char *frame = "HELLO\talice\t1\tnonce\t11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_HELLO);
    assert(pf.u.hello.has_pubkey == 1);
}

static void test_sub_valid(void) {
    const char *frame = "SUB\tgeneral";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_SUB);
    assert(strcmp(pf.u.sub.room_id, "general") == 0);
    assert(pf.u.sub.room_hash != 0);
}

static void test_sub_empty_room(void) {
    const char *frame = "SUB\t";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_FIELD_LEN);
}

static void test_sub_bad_char(void) {
    const char *frame = "SUB\troom with space";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_FIELD_FORMAT);
}

static void test_sub_extra_tab(void) {
    const char *frame = "SUB\tgeneral\textra";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_BAD_FRAME);
}

static void test_unsub_valid(void) {
    const char *frame = "UNSUB\tgeneral";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_UNSUB);
    assert(strcmp(pf.u.sub.room_id, "general") == 0);
}

static void test_ping(void) {
    const char *frame = "PING\tn123";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_PING);
    assert(strcmp(pf.u.nonce.nonce, "n123") == 0);
}

static void test_pong(void) {
    const char *frame = "PONG\tn123";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_PONG);
    assert(strcmp(pf.u.nonce.nonce, "n123") == 0);
}

static void test_bye(void) {
    const char *frame = "BYE";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_BYE);
}

static void test_end(void) {
    const char *frame = "END";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_END);
}

static void test_have(void) {
    const char *frame =
        "HAVE\tgeneral\t"
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_HAVE);
    assert(strcmp(pf.u.room_msg.room_id, "general") == 0);
}

static void test_want(void) {
    const char *frame =
        "WANT\tgeneral\t"
        "cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_WANT);
    assert(strcmp(pf.u.room_msg.msg_id, "cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe") == 0);
}

static void test_msg_via_generic(void) {
    const char *frame =
        "MSG\tgeneral\t"
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t"
        "cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe\t"
        "1715100000000\t"
        "aGVsbG8\t"
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_MSG);
    assert(strcmp(pf.u.msg.room_id, "general") == 0);
}

static void test_unknown_verb(void) {
    const char *frame = "KICK\tuser123";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_ERR_UNSUPPORTED_VERB);
}

static void test_null_inputs(void) {
    chat1_parsed_frame pf;
    assert(chat1_parse_frame(NULL, 0, &pf) == CHAT1_WIRE_ERR_NULL);
    assert(chat1_parse_frame("PING", 4, NULL) == CHAT1_WIRE_ERR_NULL);
}

static void test_crlf_hello(void) {
    const char *frame = "HELLO\talice\t1\tnonce\r";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_HELLO);
}

static void test_embedded_newline(void) {
    const char frame[] = "SUB\tgen\neral";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, sizeof(frame) - 1, &pf);
    assert(rc == CHAT1_WIRE_ERR_BAD_FRAME);
}

static void test_want_dash(void) {
    const char *frame = "WANT\tgeneral\t-";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_WANT);
    assert(strcmp(pf.u.room_msg.room_id, "general") == 0);
    assert(strcmp(pf.u.room_msg.msg_id, "-") == 0);
}

static void test_attach_parse(void) {
    const char *frame =
        "ATTACH\tgeneral\t"
        "abababababababababababababababababababababababababababababababab\t"
        "cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe\t"
        "1715100000000\t"
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t"
        "42\t"
        "-\t"
        "-\t"
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    chat1_parsed_frame pf;
    int rc = chat1_parse_frame(frame, (uint32_t)strlen(frame), &pf);
    assert(rc == CHAT1_WIRE_OK);
    assert(pf.verb == CHAT1_WIRE_VERB_ATTACH);
    assert(strcmp(pf.u.attach.room_id, "general") == 0);
    assert(strcmp(pf.u.attach.mime, "-") == 0);
    assert(pf.u.attach.byte_len == 42ull);
}

int main(void) {
    printf("test_parse_frame:\n");
    RUN(test_hello_valid);
    RUN(test_hello_missing_nonce);
    RUN(test_hello_extra_field);
    RUN(test_hello_empty_client_id);
    RUN(test_hello_bad_version);
    RUN(test_hello_with_pubkey);
    RUN(test_sub_valid);
    RUN(test_sub_empty_room);
    RUN(test_sub_bad_char);
    RUN(test_sub_extra_tab);
    RUN(test_unsub_valid);
    RUN(test_ping);
    RUN(test_pong);
    RUN(test_bye);
    RUN(test_end);
    RUN(test_have);
    RUN(test_want);
    RUN(test_want_dash);
    RUN(test_attach_parse);
    RUN(test_msg_via_generic);
    RUN(test_unknown_verb);
    RUN(test_null_inputs);
    RUN(test_crlf_hello);
    RUN(test_embedded_newline);
    printf("ok %d/%d\n", tests_passed, tests_run);
    return 0;
}
