#define _POSIX_C_SOURCE 200809L

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "chat1_ffi.h"

static char cap[65536];
static size_t cap_len;

static int cap_write(void *ctx, int fd, const char *buf, size_t len) {
    (void)ctx;
    (void)fd;
    if (cap_len + len >= sizeof(cap)) {
        return -1;
    }
    memcpy(cap + cap_len, buf, len);
    cap_len += len;
    cap[cap_len] = '\0';
    return 0;
}

static void reset_cap(void) {
    cap_len = 0;
    cap[0] = '\0';
}

#define MID2 "2222222222222222222222222222222222222222222222222222222222222222"
#define MID1 "1111111111111111111111111111111111111111111111111111111111111111"
#define MID3 "3333333333333333333333333333333333333333333333333333333333333333"
#define AUTH "21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9"
#define SIG86 "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

int main(void) {
    const char *path = "/tmp/chat1-test-want-replay.log";
    char shardpath[64];

    assert(chat1_shard_log_path(7u, shardpath, sizeof(shardpath)) == CHAT1_LOG_OK);
    assert(strcmp(shardpath, "/tmp/chat1-shard-7.log") == 0);

    unlink(path);
    {
        FILE *f = fopen(path, "w");
        assert(f);
        fprintf(f,
                "MSG\tgeneral\t%s\t%s\t2000\taGVsbG8\tx\n"
                "ATTACH\tgeneral\t%s\t%s\t1500\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t42\t-\t-\t%s\n"
                "MSG\tgeneral\t%s\t%s\t1000\taGVsbG8\ty\n",
                MID1, AUTH, MID3, AUTH, SIG86, MID2, AUTH);
        fclose(f);
    }

    reset_cap();
    assert(chat1_log_want_replay(cap_write, NULL, -1, path, "general", "-") == 0);
    assert(strstr(cap, "MSG\tgeneral\t" MID2) != NULL);
    assert(strstr(cap, "ATTACH\tgeneral\t") != NULL);
    assert(strstr(cap, "MSG\tgeneral\t" MID1) != NULL);
    assert(strstr(cap, "MSG\tgeneral\t" MID2) < strstr(cap, "ATTACH\tgeneral\t"));
    assert(strstr(cap, "ATTACH\tgeneral\t") < strstr(cap, "MSG\tgeneral\t" MID1));
    assert(strstr(cap, "END\tgeneral\n") != NULL);

    reset_cap();
    assert(chat1_log_want_replay(cap_write, NULL, -1, path, "general", MID2) == 0);
    assert(strstr(cap, "MSG\tgeneral\t" MID2) == NULL);
    assert(strstr(cap, "ATTACH\tgeneral\t") != NULL);
    assert(strstr(cap, "MSG\tgeneral\t" MID1) != NULL);
    assert(strstr(cap, "END\tgeneral\n") != NULL);

    reset_cap();
    assert(chat1_log_want_replay(cap_write, NULL, -1, path, "general", MID1) == 0);
    assert(strstr(cap, "MSG\t") == NULL);
    assert(strcmp(cap, "END\tgeneral\n") == 0);

    unlink(path);

    reset_cap();
    assert(chat1_log_want_replay(cap_write, NULL, -1, "/tmp/chat1-shard-missing-999999.log", "general", "-") == 0);
    assert(strcmp(cap, "END\tgeneral\n") == 0);

    printf("ok log want replay\n");
    return 0;
}
