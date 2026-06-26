#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "chat1_ffi.h"

#define MSG_FIELD_COUNT 6
#define ATTACH_FIELD_COUNT 9

static int is_lowhex(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

static int is_b64url(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '_';
}

static int is_room_char(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '.' || c == '_' ||
           c == '#' || c == '-';
}

static int parse_ts_ms(const char *s, size_t len, uint64_t *out) {
    uint64_t v = 0;
    size_t i;

    if (len == 0) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (len == 1 && s[0] == '0') {
        *out = 0;
        return CHAT1_WIRE_OK;
    }

    if (s[0] < '1' || s[0] > '9') {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    for (i = 0; i < len; ++i) {
        char c = s[i];
        if (c < '0' || c > '9') {
            return CHAT1_WIRE_ERR_FIELD_FORMAT;
        }
        if (v > (UINT64_MAX - (uint64_t)(c - '0')) / 10ULL) {
            return CHAT1_WIRE_ERR_FIELD_FORMAT;
        }
        v = v * 10ULL + (uint64_t)(c - '0');
    }

    *out = v;
    return CHAT1_WIRE_OK;
}

static int charset_ok(const char *s, size_t len, int (*pred)(char)) {
    size_t i;
    for (i = 0; i < len; ++i) {
        if (!pred(s[i])) {
            return 0;
        }
    }
    return 1;
}

static uint64_t fnv1a(const char *s, size_t len) {
    uint64_t h = 1469598103934665603ULL;
    size_t i;
    for (i = 0; i < len; ++i) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static int attach_mime_ok(const char *s, size_t len) {
    size_t i;
    if (len == 1 && s[0] == '-') {
        return 1;
    }
    if (len == 0 || len > CHAT1_ATTACH_MIME_MAX) {
        return 0;
    }
    for (i = 0; i < len; ++i) {
        char c = s[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '.' || c == '/' || c == '+' || c == '-') {
            continue;
        }
        return 0;
    }
    return 1;
}

static int attach_name_ok(const char *s, size_t len) {
    size_t i;
    if (len == 1 && s[0] == '-') {
        return 1;
    }
    if (len == 0 || len > CHAT1_ATTACH_NAME_MAX) {
        return 0;
    }
    for (i = 0; i < len; ++i) {
        char c = s[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '.' || c == '_' || c == '-') {
            continue;
        }
        return 0;
    }
    return 1;
}

int chat1_parse_msg_frame(const char *line, uint32_t len, chat1_ingress_event *out) {
    const char *fields[MSG_FIELD_COUNT];
    size_t flen[MSG_FIELD_COUNT];
    size_t verb_len;
    size_t cursor;
    size_t f;

    if (!line || !out) {
        return CHAT1_WIRE_ERR_NULL;
    }

    if (len > CHAT1_WIRE_MAX_LINE) {
        return CHAT1_WIRE_ERR_BAD_FRAME;
    }

    if (len > 0 && line[len - 1] == '\r') {
        len -= 1;
    }

    {
        size_t i;
        for (i = 0; i < len; ++i) {
            if (line[i] == '\n' || line[i] == '\r') {
                return CHAT1_WIRE_ERR_BAD_FRAME;
            }
        }
    }

    {
        const char *tab = memchr(line, '\t', len);
        if (!tab) {
            return CHAT1_WIRE_ERR_BAD_FRAME;
        }
        verb_len = (size_t)(tab - line);
    }

    if (verb_len != 3 || memcmp(line, "MSG", 3) != 0) {
        return CHAT1_WIRE_ERR_UNSUPPORTED_VERB;
    }

    cursor = verb_len + 1;

    for (f = 0; f < MSG_FIELD_COUNT; ++f) {
        const char *start = line + cursor;
        size_t remaining = len - cursor;
        const char *tab = memchr(start, '\t', remaining);
        size_t fl;

        if (f + 1 < MSG_FIELD_COUNT) {
            if (!tab) {
                return CHAT1_WIRE_ERR_BAD_FRAME;
            }
            fl = (size_t)(tab - start);
        } else {
            if (tab) {
                return CHAT1_WIRE_ERR_BAD_FRAME;
            }
            fl = remaining;
        }

        if (fl == 0) {
            return CHAT1_WIRE_ERR_BAD_FRAME;
        }

        fields[f] = start;
        flen[f] = fl;
        cursor += fl + 1;
    }

    if (flen[0] > CHAT1_MAX_ROOM_ID) {
        return CHAT1_WIRE_ERR_FIELD_LEN;
    }
    if (!charset_ok(fields[0], flen[0], is_room_char)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (flen[1] != CHAT1_SHA256_HEX_LEN) {
        return CHAT1_WIRE_ERR_FIELD_LEN;
    }
    if (!charset_ok(fields[1], flen[1], is_lowhex)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (flen[2] != CHAT1_SHA256_HEX_LEN) {
        return CHAT1_WIRE_ERR_FIELD_LEN;
    }
    if (!charset_ok(fields[2], flen[2], is_lowhex)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    {
        uint64_t ts = 0;
        int rc = parse_ts_ms(fields[3], flen[3], &ts);
        if (rc != CHAT1_WIRE_OK) {
            return rc;
        }
        out->ts_ms = ts;
    }

    if (flen[4] > CHAT1_MAX_BODY_BYTES) {
        return CHAT1_WIRE_ERR_FIELD_LEN;
    }
    if (!charset_ok(fields[4], flen[4], is_b64url)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (flen[5] != CHAT1_ED25519_SIG_B64_LEN) {
        return CHAT1_WIRE_ERR_FIELD_LEN;
    }
    if (!charset_ok(fields[5], flen[5], is_b64url)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    out->connection_id = 0;
    out->room_hash = fnv1a(fields[0], flen[0]);
    out->body_len = (uint32_t)flen[4];

    memcpy(out->room_id, fields[0], flen[0]);
    out->room_id[flen[0]] = '\0';

    memcpy(out->msg_id, fields[1], flen[1]);
    out->msg_id[flen[1]] = '\0';

    memcpy(out->author_id, fields[2], flen[2]);
    out->author_id[flen[2]] = '\0';

    memcpy(out->body_b64, fields[4], flen[4]);
    out->body_b64[flen[4]] = '\0';

    memcpy(out->sig_b64, fields[5], flen[5]);
    out->sig_b64[flen[5]] = '\0';

    return CHAT1_WIRE_OK;
}

int chat1_parse_attach_frame(const char *line, uint32_t len, chat1_attach_event *out) {
    const char *fields[ATTACH_FIELD_COUNT];
    size_t flen[ATTACH_FIELD_COUNT];
    size_t verb_len;
    size_t cursor;
    size_t f;

    if (!line || !out) {
        return CHAT1_WIRE_ERR_NULL;
    }

    if (len > CHAT1_WIRE_MAX_LINE) {
        return CHAT1_WIRE_ERR_BAD_FRAME;
    }

    if (len > 0 && line[len - 1] == '\r') {
        len -= 1;
    }

    {
        size_t i;
        for (i = 0; i < len; ++i) {
            if (line[i] == '\n' || line[i] == '\r') {
                return CHAT1_WIRE_ERR_BAD_FRAME;
            }
        }
    }

    {
        const char *tab = memchr(line, '\t', len);
        if (!tab) {
            return CHAT1_WIRE_ERR_BAD_FRAME;
        }
        verb_len = (size_t)(tab - line);
    }

    if (verb_len != 6 || memcmp(line, "ATTACH", 6) != 0) {
        return CHAT1_WIRE_ERR_UNSUPPORTED_VERB;
    }

    cursor = verb_len + 1;

    for (f = 0; f < ATTACH_FIELD_COUNT; ++f) {
        const char *start = line + cursor;
        size_t remaining = len - cursor;
        const char *tab = memchr(start, '\t', remaining);
        size_t fl;

        if (f + 1 < ATTACH_FIELD_COUNT) {
            if (!tab) {
                return CHAT1_WIRE_ERR_BAD_FRAME;
            }
            fl = (size_t)(tab - start);
        } else {
            if (tab) {
                return CHAT1_WIRE_ERR_BAD_FRAME;
            }
            fl = remaining;
        }

        if (fl == 0) {
            return CHAT1_WIRE_ERR_BAD_FRAME;
        }

        fields[f] = start;
        flen[f] = fl;
        cursor += fl + 1;
    }

    if (flen[0] > CHAT1_MAX_ROOM_ID) {
        return CHAT1_WIRE_ERR_FIELD_LEN;
    }
    if (!charset_ok(fields[0], flen[0], is_room_char)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (flen[1] != CHAT1_SHA256_HEX_LEN || !charset_ok(fields[1], flen[1], is_lowhex)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (flen[2] != CHAT1_SHA256_HEX_LEN || !charset_ok(fields[2], flen[2], is_lowhex)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    {
        uint64_t ts = 0;
        int rc = parse_ts_ms(fields[3], flen[3], &ts);
        if (rc != CHAT1_WIRE_OK) {
            return rc;
        }
        out->ts_ms = ts;
    }

    if (flen[4] != CHAT1_CID_HEX_LEN || !charset_ok(fields[4], flen[4], is_lowhex)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    {
        uint64_t bl = 0;
        int rc = parse_ts_ms(fields[5], flen[5], &bl);
        if (rc != CHAT1_WIRE_OK) {
            return rc;
        }
        out->byte_len = bl;
    }

    if (!attach_mime_ok(fields[6], flen[6])) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (!attach_name_ok(fields[7], flen[7])) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    if (flen[8] != CHAT1_ED25519_SIG_B64_LEN || !charset_ok(fields[8], flen[8], is_b64url)) {
        return CHAT1_WIRE_ERR_FIELD_FORMAT;
    }

    out->connection_id = 0;
    out->room_hash = fnv1a(fields[0], flen[0]);

    memcpy(out->room_id, fields[0], flen[0]);
    out->room_id[flen[0]] = '\0';

    memcpy(out->msg_id, fields[1], flen[1]);
    out->msg_id[flen[1]] = '\0';

    memcpy(out->author_id, fields[2], flen[2]);
    out->author_id[flen[2]] = '\0';

    memcpy(out->cid_hex, fields[4], flen[4]);
    out->cid_hex[flen[4]] = '\0';

    memcpy(out->mime, fields[6], flen[6]);
    out->mime[flen[6]] = '\0';

    memcpy(out->filename, fields[7], flen[7]);
    out->filename[flen[7]] = '\0';

    memcpy(out->sig_b64, fields[8], flen[8]);
    out->sig_b64[flen[8]] = '\0';

    return CHAT1_WIRE_OK;
}

static int parse_hello_fields(const char *line, uint32_t len, size_t after_verb, chat1_hello_frame *out) {
    const char *f1_start, *f2_start, *f3_start, *f4_start = NULL;
    size_t f1_len, f2_len, f3_len, f4_len = 0;
    const char *tab1, *tab2, *tab3;
    uint64_t ver;

    f1_start = line + after_verb;
    tab1 = memchr(f1_start, '\t', len - after_verb);
    if (!tab1) return CHAT1_WIRE_ERR_BAD_FRAME;
    f1_len = (size_t)(tab1 - f1_start);

    f2_start = tab1 + 1;
    tab2 = memchr(f2_start, '\t', len - (size_t)(f2_start - line));
    if (!tab2) return CHAT1_WIRE_ERR_BAD_FRAME;
    f2_len = (size_t)(tab2 - f2_start);

    f3_start = tab2 + 1;
    tab3 = memchr(f3_start, '\t', len - (size_t)(f3_start - line));
    if (tab3) {
        f3_len = (size_t)(tab3 - f3_start);
        f4_start = tab3 + 1;
        f4_len = len - (size_t)(f4_start - line);
        if (memchr(f4_start, '\t', f4_len)) return CHAT1_WIRE_ERR_BAD_FRAME;
    } else {
        f3_len = len - (size_t)(f3_start - line);
    }

    if (f1_len == 0 || f1_len > CHAT1_MAX_CLIENT_ID) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (f2_len == 0) return CHAT1_WIRE_ERR_BAD_FRAME;
    if (f3_len == 0 || f3_len > CHAT1_MAX_NONCE) return CHAT1_WIRE_ERR_FIELD_LEN;

    if (parse_ts_ms(f2_start, f2_len, &ver) != CHAT1_WIRE_OK) return CHAT1_WIRE_ERR_FIELD_FORMAT;

    memcpy(out->client_id, f1_start, f1_len);
    out->client_id[f1_len] = '\0';
    out->protocol_version = (uint32_t)ver;
    memcpy(out->nonce, f3_start, f3_len);
    out->nonce[f3_len] = '\0';
    out->has_pubkey = 0;
    out->pubkey_b64[0] = '\0';
    if (f4_start) {
        if (f4_len != CHAT1_PUBKEY_B64_LEN) return CHAT1_WIRE_ERR_FIELD_LEN;
        if (!charset_ok(f4_start, f4_len, is_b64url)) return CHAT1_WIRE_ERR_FIELD_FORMAT;
        memcpy(out->pubkey_b64, f4_start, f4_len);
        out->pubkey_b64[f4_len] = '\0';
        out->has_pubkey = 1;
    }

    return CHAT1_WIRE_OK;
}

static int parse_sub_fields(const char *line, uint32_t len, size_t after_verb, chat1_sub_frame *out) {
    const char *room_start = line + after_verb;
    size_t room_len = len - after_verb;

    if (memchr(room_start, '\t', room_len)) return CHAT1_WIRE_ERR_BAD_FRAME;
    if (room_len == 0 || room_len > CHAT1_MAX_ROOM_ID) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (!charset_ok(room_start, room_len, is_room_char)) return CHAT1_WIRE_ERR_FIELD_FORMAT;

    memcpy(out->room_id, room_start, room_len);
    out->room_id[room_len] = '\0';
    out->room_hash = fnv1a(room_start, room_len);

    return CHAT1_WIRE_OK;
}

static int parse_want_fields(const char *line, uint32_t len, size_t after_verb, chat1_room_msg_frame *out) {
    const char *room_start = line + after_verb;
    const char *tab = memchr(room_start, '\t', len - after_verb);
    const char *since_start;
    size_t room_len, since_len;

    if (!tab) return CHAT1_WIRE_ERR_BAD_FRAME;
    room_len = (size_t)(tab - room_start);
    since_start = tab + 1;
    since_len = len - (size_t)(since_start - line);
    if (memchr(since_start, '\t', since_len)) return CHAT1_WIRE_ERR_BAD_FRAME;

    if (room_len == 0 || room_len > CHAT1_MAX_ROOM_ID) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (!charset_ok(room_start, room_len, is_room_char)) return CHAT1_WIRE_ERR_FIELD_FORMAT;

    memcpy(out->room_id, room_start, room_len);
    out->room_id[room_len] = '\0';
    out->room_hash = fnv1a(room_start, room_len);

    if (since_len == 1 && since_start[0] == '-') {
        out->msg_id[0] = '-';
        out->msg_id[1] = '\0';
        return CHAT1_WIRE_OK;
    }

    if (since_len != CHAT1_SHA256_HEX_LEN) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (!charset_ok(since_start, since_len, is_lowhex)) return CHAT1_WIRE_ERR_FIELD_FORMAT;
    memcpy(out->msg_id, since_start, since_len);
    out->msg_id[since_len] = '\0';
    return CHAT1_WIRE_OK;
}

static int parse_room_msg_fields(const char *line, uint32_t len, size_t after_verb, chat1_room_msg_frame *out) {
    const char *room_start = line + after_verb;
    const char *tab = memchr(room_start, '\t', len - after_verb);
    const char *msg_start;
    size_t room_len, msg_len;

    if (!tab) return CHAT1_WIRE_ERR_BAD_FRAME;
    room_len = (size_t)(tab - room_start);
    msg_start = tab + 1;
    msg_len = len - (size_t)(msg_start - line);
    if (memchr(msg_start, '\t', msg_len)) return CHAT1_WIRE_ERR_BAD_FRAME;

    if (room_len == 0 || room_len > CHAT1_MAX_ROOM_ID) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (!charset_ok(room_start, room_len, is_room_char)) return CHAT1_WIRE_ERR_FIELD_FORMAT;

    if (msg_len != CHAT1_SHA256_HEX_LEN) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (!charset_ok(msg_start, msg_len, is_lowhex)) return CHAT1_WIRE_ERR_FIELD_FORMAT;

    memcpy(out->room_id, room_start, room_len);
    out->room_id[room_len] = '\0';
    out->room_hash = fnv1a(room_start, room_len);
    memcpy(out->msg_id, msg_start, msg_len);
    out->msg_id[msg_len] = '\0';
    return CHAT1_WIRE_OK;
}

static int parse_room_meta_fields(const char *line, uint32_t len, size_t after_verb, chat1_room_meta_frame *out) {
    const char *p = line + after_verb;
    const char *t1 = memchr(p, '\t', len - after_verb);
    size_t mode_len;
    const char *rid;
    size_t rid_len;

    if (!t1) return CHAT1_WIRE_ERR_BAD_FRAME;
    mode_len = (size_t)(t1 - p);
    if (mode_len == 0 || mode_len >= sizeof(out->visibility)) return CHAT1_WIRE_ERR_FIELD_LEN;
    memcpy(out->visibility, p, mode_len);
    out->visibility[mode_len] = '\0';
    if (strcmp(out->visibility, "open") != 0 && strcmp(out->visibility, "private") != 0) return CHAT1_WIRE_ERR_FIELD_FORMAT;

    rid = t1 + 1;
    rid_len = len - (size_t)(rid - line);
    if (memchr(rid, '\t', rid_len)) return CHAT1_WIRE_ERR_BAD_FRAME;
    if (rid_len == 0 || rid_len > CHAT1_MAX_ROOM_ID) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (!charset_ok(rid, rid_len, is_room_char)) return CHAT1_WIRE_ERR_FIELD_FORMAT;
    memcpy(out->room_id, rid, rid_len);
    out->room_id[rid_len] = '\0';
    return CHAT1_WIRE_OK;
}

static int parse_nonce_field(const char *line, uint32_t len, size_t after_verb, chat1_nonce_frame *out) {
    const char *start = line + after_verb;
    size_t n = len - after_verb;
    if (memchr(start, '\t', n)) return CHAT1_WIRE_ERR_BAD_FRAME;
    if (n == 0 || n > CHAT1_MAX_NONCE) return CHAT1_WIRE_ERR_FIELD_LEN;
    if (!charset_ok(start, n, is_b64url)) return CHAT1_WIRE_ERR_FIELD_FORMAT;
    memcpy(out->nonce, start, n);
    out->nonce[n] = '\0';
    return CHAT1_WIRE_OK;
}

int chat1_parse_frame(const char *line, uint32_t len, chat1_parsed_frame *out) {
    const char *tab;
    size_t verb_len, after_verb;

    if (!line || !out) return CHAT1_WIRE_ERR_NULL;
    if (len > CHAT1_WIRE_MAX_LINE) return CHAT1_WIRE_ERR_BAD_FRAME;

    if (len > 0 && line[len - 1] == '\r') len -= 1;

    {
        size_t i;
        for (i = 0; i < len; ++i) {
            if (line[i] == '\n' || line[i] == '\r') return CHAT1_WIRE_ERR_BAD_FRAME;
        }
    }

    tab = memchr(line, '\t', len);
    if (!tab) {
        if (len == 4 && memcmp(line, "PING", 4) == 0) {
            out->verb = CHAT1_WIRE_VERB_PING;
            return CHAT1_WIRE_OK;
        }
        if (len == 4 && memcmp(line, "PONG", 4) == 0) {
            out->verb = CHAT1_WIRE_VERB_PONG;
            return CHAT1_WIRE_OK;
        }
        if (len == 3 && memcmp(line, "BYE", 3) == 0) {
            out->verb = CHAT1_WIRE_VERB_BYE;
            return CHAT1_WIRE_OK;
        }
        if (len == 3 && memcmp(line, "END", 3) == 0) {
            out->verb = CHAT1_WIRE_VERB_END;
            return CHAT1_WIRE_OK;
        }
        if (len == 4 && memcmp(line, "LIST", 4) == 0) {
            out->verb = CHAT1_WIRE_VERB_LIST;
            return CHAT1_WIRE_OK;
        }
        return CHAT1_WIRE_ERR_BAD_FRAME;
    }

    verb_len = (size_t)(tab - line);
    after_verb = verb_len + 1;

    if (verb_len == 3 && memcmp(line, "MSG", 3) == 0) {
        out->verb = CHAT1_WIRE_VERB_MSG;
        return chat1_parse_msg_frame(line, len, &out->u.msg);
    }

    if (verb_len == 6 && memcmp(line, "ATTACH", 6) == 0) {
        int rc = chat1_parse_attach_frame(line, len, &out->u.attach);
        if (rc == CHAT1_WIRE_OK) {
            out->verb = CHAT1_WIRE_VERB_ATTACH;
        }
        return rc;
    }

    if (verb_len == 5 && memcmp(line, "HELLO", 5) == 0) {
        int rc = parse_hello_fields(line, len, after_verb, &out->u.hello);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_HELLO;
        return rc;
    }

    if (verb_len == 3 && memcmp(line, "SUB", 3) == 0) {
        int rc = parse_sub_fields(line, len, after_verb, &out->u.sub);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_SUB;
        return rc;
    }

    if (verb_len == 5 && memcmp(line, "UNSUB", 5) == 0) {
        int rc = parse_sub_fields(line, len, after_verb, &out->u.sub);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_UNSUB;
        return rc;
    }
    if (verb_len == 4 && memcmp(line, "ROOM", 4) == 0) {
        int rc = parse_room_meta_fields(line, len, after_verb, &out->u.room_meta);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_ROOM;
        return rc;
    }
    if (verb_len == 4 && memcmp(line, "HAVE", 4) == 0) {
        int rc = parse_room_msg_fields(line, len, after_verb, &out->u.room_msg);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_HAVE;
        return rc;
    }
    if (verb_len == 4 && memcmp(line, "PING", 4) == 0) {
        int rc = parse_nonce_field(line, len, after_verb, &out->u.nonce);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_PING;
        return rc;
    }
    if (verb_len == 4 && memcmp(line, "PONG", 4) == 0) {
        int rc = parse_nonce_field(line, len, after_verb, &out->u.nonce);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_PONG;
        return rc;
    }
    if (verb_len == 4 && memcmp(line, "WANT", 4) == 0) {
        int rc = parse_want_fields(line, len, after_verb, &out->u.room_msg);
        if (rc == CHAT1_WIRE_OK) out->verb = CHAT1_WIRE_VERB_WANT;
        return rc;
    }

    return CHAT1_WIRE_ERR_UNSUPPORTED_VERB;
}

uint64_t chat1_room_hash_of_id(const char *room_id) {
    return fnv1a(room_id, strlen(room_id));
}
