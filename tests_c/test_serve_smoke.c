#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "chat1_ffi.h"

#define TEST_SHARD 42u
#define LOG_PATH "/tmp/chat1-shard-42.log"

static const char ROOM[]  = "general";
static const char MSGID[] = "6d132e83884b1b52086c5fec5cad584c00d88c61b4506157da037e4f07539322";
static const char AUTH[]  = "21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9";
static const char BODY[]  = "aGVsbG8";
static const char SIG[]   = "l6on5V73Zud-lyHhcvUZRUbmhyoro5IWyfEPZ3fquLrLRHe1mzoTlCeVXkuY98mV_rRnXFS_Ex-5DwQS-aL6Cg";

static int open_listener_ephemeral(uint16_t *port_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    struct sockaddr_in addr;
    socklen_t alen = sizeof(addr);

    assert(fd >= 0);
    assert(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) == 0);

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;

    assert(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(fd, 16) == 0);

    memset(&addr, 0, sizeof(addr));
    assert(getsockname(fd, (struct sockaddr *)&addr, &alen) == 0);
    *port_out = ntohs(addr.sin_port);
    return fd;
}

static int connect_loopback(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    assert(fd >= 0);
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    assert(connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    return fd;
}

static void send_all(int fd, const char *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);
        if (n < 0 && errno == EINTR) continue;
        assert(n > 0);
        sent += (size_t)n;
    }
}

static int read_file(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY);
    ssize_t n;
    if (fd < 0) return -1;
    n = read(fd, buf, cap - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    return (int)n;
}

static int contains(const char *hay, size_t hlen, const char *needle) {
    size_t nlen = strlen(needle);
    size_t i;
    if (nlen == 0) return 1;
    if (hlen < nlen) return 0;
    for (i = 0; i + nlen <= hlen; ++i) {
        if (memcmp(hay + i, needle, nlen) == 0) return 1;
    }
    return 0;
}

int main(void) {
    uint16_t port = 0;
    int listener_fd;
    pid_t child;

    unlink(LOG_PATH);
    chat1_room_engine_init_c(256, 65536);
    chat1_auth_keys_init();

    listener_fd = open_listener_ephemeral(&port);

    child = fork();
    assert(child >= 0);

    if (child == 0) {
        int rc = chat1_serve_once(listener_fd, TEST_SHARD);
        close(listener_fd);
        _exit(rc == CHAT1_SERVE_OK ? 0 : 1);
    }

    {
        char frame[1024];
        int n = snprintf(frame, sizeof(frame),
                         "HELLO\tcli\t1\tnonce\t11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo\n"
                         "MSG\t%s\t%s\t%s\t1715100000000\t%s\t%s\n",
                         ROOM, MSGID, AUTH, BODY, SIG);
        int conn = connect_loopback(port);
        send_all(conn, frame, (size_t)n);
        close(conn);
    }

    {
        int status = 0;
        pid_t got = waitpid(child, &status, 0);
        assert(got == child);
        assert(WIFEXITED(status));
        assert(WEXITSTATUS(status) == 0);
    }

    close(listener_fd);

    {
        char buf[4096];
        int n = read_file(LOG_PATH, buf, sizeof(buf));
        assert(n > 0);
        assert(contains(buf, (size_t)n, "MSG\t"));
        assert(contains(buf, (size_t)n, ROOM));
        assert(contains(buf, (size_t)n, MSGID));
        assert(contains(buf, (size_t)n, BODY));
        assert(contains(buf, (size_t)n, SIG));
        assert(buf[n - 1] == '\n');
    }

    unlink(LOG_PATH);
    printf("ok serve smoke\n");
    return 0;
}
