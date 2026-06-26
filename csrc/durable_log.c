#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "chat1_ffi.h"

static int chat1_log_sync_parent_dir(const char *path) {
    char *path_copy;
    char *slash;
    int dir_fd;
    int saved_errno;

    if (!path) {
        errno = EINVAL;
        return -1;
    }

    if (path[0] == '\0') {
        errno = EINVAL;
        return -1;
    }

    path_copy = strdup(path);
    if (!path_copy) {
        return -1;
    }

    slash = strrchr(path_copy, '/');
    if (!slash) {
        path_copy[0] = '.';
        path_copy[1] = '\0';
    } else if (slash == path_copy) {
        slash[1] = '\0';
    } else {
        *slash = '\0';
    }

    dir_fd = open(path_copy, O_RDONLY | O_DIRECTORY);
    saved_errno = errno;
    free(path_copy);
    errno = saved_errno;

    if (dir_fd < 0) {
        return -1;
    }

    if (fsync(dir_fd) != 0) {
        saved_errno = errno;
        close(dir_fd);
        errno = saved_errno;
        return -1;
    }

    if (close(dir_fd) != 0) {
        return -1;
    }

    return 0;
}

static int chat1_log_open_fd(const char *path, int *created_out) {
    int fd;

    if (!path) {
        errno = EINVAL;
        return -1;
    }

    if (created_out) {
        *created_out = 0;
    }

    fd = open(path, O_CREAT | O_EXCL | O_APPEND | O_WRONLY, 0644);
    if (fd >= 0) {
        if (created_out) {
            *created_out = 1;
        }
        return fd;
    }

    if (errno != EEXIST) {
        return -1;
    }

    return open(path, O_APPEND | O_WRONLY, 0644);
}

static int chat1_log_write_all(int fd, const void *buf, uint32_t len) {
    const char *cursor = (const char *)buf;
    uint32_t remaining = len;

    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);

        if (written < 0) {
            return CHAT1_LOG_ERR_WRITE;
        }

        cursor += (size_t)written;
        remaining -= (uint32_t)written;
    }

    return CHAT1_LOG_OK;
}

int chat1_log_open(const char *path) {
    int created = 0;
    int fd = chat1_log_open_fd(path, &created);

    if (fd < 0) {
        return CHAT1_LOG_ERR_OPEN;
    }

    if (created) {
        if (fdatasync(fd) != 0) {
            close(fd);
            return CHAT1_LOG_ERR_FDATASYNC;
        }

        if (chat1_log_sync_parent_dir(path) != 0) {
            close(fd);
            return CHAT1_LOG_ERR_FDATASYNC;
        }
    }

    if (close(fd) != 0) {
        return CHAT1_LOG_ERR_OPEN;
    }

    return CHAT1_LOG_OK;
}

int chat1_log_append(const char *path, const void *buf, uint32_t len) {
    int created = 0;
    int fd = chat1_log_open_fd(path, &created);
    int rc;

    if (fd < 0) {
        return CHAT1_LOG_ERR_OPEN;
    }

    rc = chat1_log_write_all(fd, buf, len);
    if (rc != CHAT1_LOG_OK) {
        close(fd);
        return rc;
    }


    if (fdatasync(fd) != 0) {
        close(fd);
        return CHAT1_LOG_ERR_FDATASYNC;
    }

    if (created && chat1_log_sync_parent_dir(path) != 0) {
        close(fd);
        return CHAT1_LOG_ERR_FDATASYNC;
    }

    if (close(fd) != 0) {
        return CHAT1_LOG_ERR_WRITE;
    }

    return CHAT1_LOG_OK;
}

int chat1_log_append_event(const char *path, const chat1_ingress_event *event) {
    char record[4352];
    int created = 0;
    int fd;
    int written;
    int rc;

    if (!event) {
        return CHAT1_LOG_ERR_WRITE;
    }

    written = snprintf(record,
                       sizeof(record),
                       "MSG\t%s\t%s\t%s\t%llu\t%.*s\t%s\n",
                       event->room_id,
                       event->msg_id,
                       event->author_id,
                       (unsigned long long)event->ts_ms,
                       (int)event->body_len,
                       event->body_b64,
                       event->sig_b64);
    if (written < 0 || (size_t)written >= sizeof(record)) {
        return CHAT1_LOG_ERR_WRITE;
    }

    fd = chat1_log_open_fd(path, &created);
    if (fd < 0) {
        return CHAT1_LOG_ERR_OPEN;
    }

    rc = chat1_log_write_all(fd, record, (uint32_t)written);
    if (rc != CHAT1_LOG_OK) {
        close(fd);
        return rc;
    }


    if (fdatasync(fd) != 0) {
        close(fd);
        return CHAT1_LOG_ERR_FDATASYNC;
    }

    if (created && chat1_log_sync_parent_dir(path) != 0) {
        close(fd);
        return CHAT1_LOG_ERR_FDATASYNC;
    }

    if (close(fd) != 0) {
        return CHAT1_LOG_ERR_WRITE;
    }

    return CHAT1_LOG_OK;
}

int chat1_log_append_attach_event(const char *path, const chat1_attach_event *event) {
    char record[8192];
    int created = 0;
    int fd;
    int written;
    int rc;

    if (!event) {
        return CHAT1_LOG_ERR_WRITE;
    }

    written = snprintf(record,
                       sizeof(record),
                       "ATTACH\t%s\t%s\t%s\t%llu\t%s\t%llu\t%s\t%s\t%s\n",
                       event->room_id,
                       event->msg_id,
                       event->author_id,
                       (unsigned long long)event->ts_ms,
                       event->cid_hex,
                       (unsigned long long)event->byte_len,
                       event->mime,
                       event->filename,
                       event->sig_b64);
    if (written < 0 || (size_t)written >= sizeof(record)) {
        return CHAT1_LOG_ERR_WRITE;
    }

    fd = chat1_log_open_fd(path, &created);
    if (fd < 0) {
        return CHAT1_LOG_ERR_OPEN;
    }

    rc = chat1_log_write_all(fd, record, (uint32_t)written);
    if (rc != CHAT1_LOG_OK) {
        close(fd);
        return rc;
    }

    if (fdatasync(fd) != 0) {
        close(fd);
        return CHAT1_LOG_ERR_FDATASYNC;
    }

    if (created && chat1_log_sync_parent_dir(path) != 0) {
        close(fd);
        return CHAT1_LOG_ERR_FDATASYNC;
    }

    if (close(fd) != 0) {
        return CHAT1_LOG_ERR_WRITE;
    }

    return CHAT1_LOG_OK;
}

typedef struct {
    uint64_t ts_ms;
    char msg_id[CHAT1_SHA256_HEX_LEN + 1];
    char *wire;
    size_t wire_len;
} chat1_replay_row;

static void replay_free_rows(chat1_replay_row *rows, size_t n) {
    size_t i;
    if (!rows) {
        return;
    }
    for (i = 0; i < n; ++i) {
        free(rows[i].wire);
    }
    free(rows);
}

static int replay_cmp(const void *a, const void *b) {
    const chat1_replay_row *x = (const chat1_replay_row *)a;
    const chat1_replay_row *y = (const chat1_replay_row *)b;
    if (x->ts_ms < y->ts_ms) {
        return -1;
    }
    if (x->ts_ms > y->ts_ms) {
        return 1;
    }
    return strcmp(x->msg_id, y->msg_id);
}

static int parse_msg_log_row(const char *line, size_t linelen, const char *want_room, chat1_replay_row *out) {
    const char *end;
    const char *p;
    const char *t;
    size_t room_len;
    size_t want_len;
    size_t total_wire;

    while (linelen > 0 && (line[linelen - 1] == '\n' || line[linelen - 1] == '\r')) {
        linelen--;
    }
    end = line + linelen;

    if (linelen < 8 || memcmp(line, "MSG\t", 4) != 0) {
        return -1;
    }

    p = line + 4;
    t = memchr(p, '\t', (size_t)(end - p));
    if (!t) {
        return -1;
    }
    room_len = (size_t)(t - p);
    want_len = strlen(want_room);
    if (room_len != want_len || memcmp(p, want_room, room_len) != 0) {
        return -1;
    }
    p = t + 1;

    t = memchr(p, '\t', (size_t)(end - p));
    if (!t || (size_t)(t - p) != CHAT1_SHA256_HEX_LEN) {
        return -1;
    }
    memcpy(out->msg_id, p, CHAT1_SHA256_HEX_LEN);
    out->msg_id[CHAT1_SHA256_HEX_LEN] = '\0';
    p = t + 1;

    t = memchr(p, '\t', (size_t)(end - p));
    if (!t) {
        return -1;
    }
    p = t + 1;

    t = memchr(p, '\t', (size_t)(end - p));
    if (!t) {
        return -1;
    }
    {
        char tsbuf[32];
        size_t tsl = (size_t)(t - p);
        if (tsl >= sizeof(tsbuf)) {
            return -1;
        }
        memcpy(tsbuf, p, tsl);
        tsbuf[tsl] = '\0';
        out->ts_ms = (uint64_t)strtoull(tsbuf, NULL, 10);
    }
    p = t + 1;

    t = memchr(p, '\t', (size_t)(end - p));
    if (!t) {
        return -1;
    }
    p = t + 1;

    if (p > end) {
        return -1;
    }

    total_wire = (size_t)(end - line);
    out->wire = (char *)malloc(total_wire + 2);
    if (!out->wire) {
        return -2;
    }
    memcpy(out->wire, line, total_wire);
    out->wire[total_wire] = '\n';
    out->wire[total_wire + 1] = '\0';
    out->wire_len = total_wire + 1;
    return 0;
}

static int parse_attach_log_row(const char *line, size_t linelen, const char *want_room, chat1_replay_row *out) {
    chat1_attach_event ev;
    const char *end;
    size_t total_wire;

    while (linelen > 0 && (line[linelen - 1] == '\n' || line[linelen - 1] == '\r')) {
        linelen--;
    }

    if (chat1_parse_attach_frame(line, (uint32_t)linelen, &ev) != CHAT1_WIRE_OK) {
        return -1;
    }

    if (strcmp(ev.room_id, want_room) != 0) {
        return -1;
    }

    out->ts_ms = ev.ts_ms;
    memcpy(out->msg_id, ev.msg_id, CHAT1_SHA256_HEX_LEN + 1);

    end = line + linelen;
    total_wire = (size_t)(end - line);
    out->wire = (char *)malloc(total_wire + 2);
    if (!out->wire) {
        return -2;
    }
    memcpy(out->wire, line, total_wire);
    out->wire[total_wire] = '\n';
    out->wire[total_wire + 1] = '\0';
    out->wire_len = total_wire + 1;
    return 0;
}

static int rows_push(chat1_replay_row **rows, size_t *n, size_t *cap, chat1_replay_row *row) {
    if (*n >= *cap) {
        size_t nc = *cap ? *cap * 2u : 16u;
        chat1_replay_row *nr = (chat1_replay_row *)realloc(*rows, nc * sizeof(chat1_replay_row));
        if (!nr) {
            return -1;
        }
        *rows = nr;
        *cap = nc;
    }
    (*rows)[*n] = *row;
    (*n)++;
    return 0;
}

int chat1_shard_log_path(uint32_t shard_index, char *path, size_t path_size) {
    int w;

    if (!path || path_size == 0) {
        return CHAT1_LOG_ERR_OPEN;
    }

    w = snprintf(path, path_size, "/tmp/chat1-shard-%u.log", shard_index);
    if (w <= 0 || (size_t)w >= path_size) {
        return CHAT1_LOG_ERR_OPEN;
    }

    return CHAT1_LOG_OK;
}

int chat1_log_want_replay(int (*write_fn)(void *ctx, int fd, const char *buf, size_t len),
                          void *write_ctx,
                          int conn_fd,
                          const char *log_path,
                          const char *room_id,
                          const char *since_msg_id) {
    FILE *f;
    char *line = NULL;
    size_t linecap = 0;
    ssize_t nr;
    chat1_replay_row *rows = NULL;
    size_t n = 0;
    size_t cap = 0;
    size_t i;
    size_t start = 0;
    char endbuf[CHAT1_MAX_ROOM_ID + 32];
    int en;
    int wrc;

    if (!write_fn || !log_path || !room_id || !since_msg_id) {
        return -1;
    }

    f = fopen(log_path, "r");
    if (!f) {
        if (errno != ENOENT) {
            return -1;
        }
        goto send_end_only;
    }

    while ((nr = getline(&line, &linecap, f)) > 0) {
        chat1_replay_row row;
        int pr;

        memset(&row, 0, sizeof(row));
        pr = parse_msg_log_row(line, (size_t)nr, room_id, &row);
        if (pr == -1) {
            pr = parse_attach_log_row(line, (size_t)nr, room_id, &row);
        }
        if (pr == -2) {
            fclose(f);
            free(line);
            replay_free_rows(rows, n);
            return -1;
        }
        if (pr != 0) {
            continue;
        }
        if (rows_push(&rows, &n, &cap, &row) != 0) {
            fclose(f);
            free(line);
            replay_free_rows(rows, n);
            return -1;
        }
    }

    free(line);
    line = NULL;
    fclose(f);

    if (n > 1) {
        qsort(rows, n, sizeof(rows[0]), replay_cmp);
    }

    if (strcmp(since_msg_id, "-") != 0) {
        int found = 0;
        for (i = 0; i < n; ++i) {
            if (strcmp(rows[i].msg_id, since_msg_id) == 0) {
                start = i + 1;
                found = 1;
                break;
            }
        }
        if (!found) {
            start = 0;
        }
    }

    for (i = start; i < n; ++i) {
        wrc = write_fn(write_ctx, conn_fd, rows[i].wire, rows[i].wire_len);
        if (wrc != 0) {
            replay_free_rows(rows, n);
            return -1;
        }
    }

    replay_free_rows(rows, n);

send_end_only:
    en = snprintf(endbuf, sizeof(endbuf), "END\t%s\n", room_id);
    if (en <= 0 || (size_t)en >= sizeof(endbuf)) {
        return -1;
    }
    wrc = write_fn(write_ctx, conn_fd, endbuf, (size_t)en);
    return wrc != 0 ? -1 : 0;
}
