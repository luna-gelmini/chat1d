#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "chat1_ffi.h"

#define PRES_MAX_ROOMS 256
#define PRES_MAX_MEMBERS 48
#define PRES_TAG_LEN 12

typedef struct {
    char author_id[CHAT1_SHA256_HEX_LEN + 1];
    uint8_t live;
    int used;
} pres_member;

typedef struct {
    uint64_t room_hash;
    char room_id[CHAT1_MAX_ROOM_ID + 1];
    uint8_t is_private;
    pres_member mem[PRES_MAX_MEMBERS];
    int in_use;
} pres_room;

static pres_room g_rooms[PRES_MAX_ROOMS];
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

void chat1_presence_init(void) {
    pthread_mutex_lock(&g_mu);
    memset(g_rooms, 0, sizeof(g_rooms));
    pthread_mutex_unlock(&g_mu);
}

static int find_room_i(uint64_t rh) {
    for (int i = 0; i < PRES_MAX_ROOMS; ++i) {
        if (g_rooms[i].in_use && g_rooms[i].room_hash == rh) return i;
    }
    return -1;
}

static int alloc_room_i(uint64_t rh, const char *room_id, int is_private) {
    for (int i = 0; i < PRES_MAX_ROOMS; ++i) {
        if (!g_rooms[i].in_use) {
            g_rooms[i].in_use = 1;
            g_rooms[i].room_hash = rh;
            strncpy(g_rooms[i].room_id, room_id, CHAT1_MAX_ROOM_ID);
            g_rooms[i].room_id[CHAT1_MAX_ROOM_ID] = '\0';
            g_rooms[i].is_private = is_private ? 1u : 0u;
            memset(g_rooms[i].mem, 0, sizeof(g_rooms[i].mem));
            return i;
        }
    }
    return -1;
}

static void author_tag(const char *author_id, char *tag, size_t tag_cap) {
    size_t n = strlen(author_id);
    if (n > PRES_TAG_LEN) n = PRES_TAG_LEN;
    if (n == 0) {
        if (tag_cap > 0) tag[0] = '\0';
        return;
    }
    memcpy(tag, author_id, n);
    tag[n] = '\0';
}

static pres_member *find_member(pres_room *r, const char *author_id) {
    for (int j = 0; j < PRES_MAX_MEMBERS; ++j) {
        if (r->mem[j].used && strcmp(r->mem[j].author_id, author_id) == 0) return &r->mem[j];
    }
    return NULL;
}

static pres_member *alloc_member(pres_room *r, const char *author_id) {
    pres_member *m = find_member(r, author_id);
    if (m) return m;
    for (int j = 0; j < PRES_MAX_MEMBERS; ++j) {
        if (!r->mem[j].used) {
            r->mem[j].used = 1;
            strncpy(r->mem[j].author_id, author_id, CHAT1_SHA256_HEX_LEN);
            r->mem[j].author_id[CHAT1_SHA256_HEX_LEN] = '\0';
            r->mem[j].live = 0;
            return &r->mem[j];
        }
    }
    return NULL;
}

void chat1_presence_room_set(const char *room_id, int is_private) {
    if (!room_id || !room_id[0]) return;
    uint64_t rh = chat1_room_hash_of_id(room_id);
    pthread_mutex_lock(&g_mu);
    int i = find_room_i(rh);
    if (i < 0) i = alloc_room_i(rh, room_id, is_private);
    if (i >= 0) {
        g_rooms[i].is_private = is_private ? 1u : 0u;
        strncpy(g_rooms[i].room_id, room_id, CHAT1_MAX_ROOM_ID);
        g_rooms[i].room_id[CHAT1_MAX_ROOM_ID] = '\0';
    }
    pthread_mutex_unlock(&g_mu);
}

void chat1_presence_on_sub(const char *room_id, uint64_t room_hash, uint64_t conn_id) {
    char author[CHAT1_SHA256_HEX_LEN + 1];
    if (chat1_conn_get_author(conn_id, author, sizeof(author)) != CHAT1_CONN_OK || author[0] == '\0') {
        strncpy(author, "?", sizeof(author) - 1);
        author[sizeof(author) - 1] = '\0';
    }
    pthread_mutex_lock(&g_mu);
    int i = find_room_i(room_hash);
    if (i < 0) i = alloc_room_i(room_hash, room_id, 0);
    if (i < 0) {
        pthread_mutex_unlock(&g_mu);
        return;
    }
    pres_member *m = alloc_member(&g_rooms[i], author);
    if (m) m->live = 1;
    pthread_mutex_unlock(&g_mu);
}

void chat1_presence_on_unsub(uint64_t room_hash, uint64_t conn_id) {
    char author[CHAT1_SHA256_HEX_LEN + 1];
    if (chat1_conn_get_author(conn_id, author, sizeof(author)) != CHAT1_CONN_OK || author[0] == '\0') {
        strncpy(author, "?", sizeof(author) - 1);
        author[sizeof(author) - 1] = '\0';
    }
    pthread_mutex_lock(&g_mu);
    int i = find_room_i(room_hash);
    if (i >= 0) {
        pres_member *m = find_member(&g_rooms[i], author);
        if (m) m->live = 0;
    }
    pthread_mutex_unlock(&g_mu);
}

void chat1_presence_on_disconnect(uint64_t conn_id) {
    char author[CHAT1_SHA256_HEX_LEN + 1];
    if (chat1_conn_get_author(conn_id, author, sizeof(author)) != CHAT1_CONN_OK || author[0] == '\0') {
        strncpy(author, "?", sizeof(author) - 1);
        author[sizeof(author) - 1] = '\0';
    }
    uint64_t hrs[CHAT1_MAX_ROOMS];
    uint32_t nh = 0;
    chat1_sub_rooms_for_conn(conn_id, hrs, CHAT1_MAX_ROOMS, &nh);
    pthread_mutex_lock(&g_mu);
    for (uint32_t k = 0; k < nh; ++k) {
        int i = find_room_i(hrs[k]);
        if (i < 0) continue;
        pres_member *m = find_member(&g_rooms[i], author);
        if (m) m->live = 0;
    }
    pthread_mutex_unlock(&g_mu);
}

static void append_csv(char *dst, size_t dst_cap, size_t *dst_len, const char *tag) {
    size_t dl = *dst_len;
    if (dl >= dst_cap - 1) return;
    if (dl > 0) {
        dst[dl++] = ',';
        dst[dl] = '\0';
    }
    size_t tl = strlen(tag);
    if (dl + tl >= dst_cap) return;
    memcpy(dst + dl, tag, tl);
    dl += tl;
    dst[dl] = '\0';
    *dst_len = dl;
}

int chat1_presence_format_list(char *buf, size_t cap) {
    if (!buf || cap < 16) return -1;
    size_t w = 0;
    int n = snprintf(buf, cap, "ROOMS\t");
    if (n <= 0 || (size_t)n >= cap) return -1;
    w = (size_t)n;
    int first = 1;

    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < PRES_MAX_ROOMS; ++i) {
        pres_room *r = &g_rooms[i];
        if (!r->in_use) continue;

        char on_tags[512];
        char off_tags[512];
        size_t on_len = 0, off_len = 0;
        on_tags[0] = '\0';
        off_tags[0] = '\0';

        for (int j = 0; j < PRES_MAX_MEMBERS; ++j) {
            if (!r->mem[j].used) continue;
            char tag[PRES_TAG_LEN + 4];
            author_tag(r->mem[j].author_id, tag, sizeof(tag));
            if (tag[0] == '\0') continue;
            if (r->mem[j].live)
                append_csv(on_tags, sizeof(on_tags), &on_len, tag);
            else
                append_csv(off_tags, sizeof(off_tags), &off_len, tag);
        }

        int m = snprintf(buf + w, cap - w, "%s%s;%c;%s;%s", first ? "" : "|", r->room_id, r->is_private ? 'p' : 'o',
                         on_len ? on_tags : "-", off_len ? off_tags : "-");
        if (m <= 0 || (size_t)m >= cap - w) {
            pthread_mutex_unlock(&g_mu);
            return -1;
        }
        w += (size_t)m;
        first = 0;
    }
    pthread_mutex_unlock(&g_mu);

    if (w + 2 >= cap) return -1;
    buf[w++] = '\n';
    buf[w] = '\0';
    return (int)w;
}
