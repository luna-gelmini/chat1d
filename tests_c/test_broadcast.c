#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include "chat1_ffi.h"

extern void chat1_room_engine_init_c(uint32_t max_events, uint32_t max_body_bytes);

static int make_listener(uint16_t *port_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    socklen_t alen;
    int one = 1;

    assert(fd >= 0);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);

    alen = sizeof(addr);
    assert(getsockname(fd, (struct sockaddr *)&addr, &alen) == 0);
    *port_out = ntohs(addr.sin_port);

    assert(listen(fd, 8) == 0);
    return fd;
}

static int connect_to(uint16_t port) {
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

static void write_str(int fd, const char *s) {
    size_t len = strlen(s);
    while (len > 0) {
        ssize_t n = write(fd, s, len);
        assert(n > 0);
        s += n;
        len -= (size_t)n;
    }
}

static ssize_t read_timeout(int fd, char *buf, size_t max, int timeout_ms) {
    struct timeval tv;
    fd_set fds;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    int sr = select(fd + 1, &fds, NULL, NULL, &tv);
    if (sr <= 0) return 0;
    return read(fd, buf, max);
}

int main(void) {
    uint16_t port;
    int listener_fd;
    pid_t child;

    signal(SIGPIPE, SIG_IGN);

    listener_fd = make_listener(&port);

    child = fork();
    assert(child >= 0);

    if (child == 0) {
        chat1_room_engine_init_c(1024, 65536);
        chat1_sub_table_init();
        chat1_conn_table_reset();
        chat1_auth_keys_init();
        chat1_serve_threaded(listener_fd, 42, 3);
        close(listener_fd);
        _exit(0);
    }

    close(listener_fd);
    usleep(50000);

    int sub1 = connect_to(port);
    write_str(sub1, "HELLO\tlistener\t1\tnonce1\t11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo\n");
    write_str(sub1, "SUB\tgeneral\n");

    char hello_resp[256];
    ssize_t hr = read_timeout(sub1, hello_resp, sizeof(hello_resp) - 1, 2000);
    assert(hr > 0);
    hello_resp[hr] = '\0';
    printf("  hello_resp: %s", hello_resp);
    assert(strstr(hello_resp, "HELLO\tchat1d\t1\t0\n") != NULL);

    usleep(100000);

    int sub2 = connect_to(port);
    write_str(sub2, "SUB\tgeneral\n");
    usleep(100000);

    int sender = connect_to(port);
    write_str(sender, "HELLO\tsender\t1\tnonce2\t11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo\n");
    write_str(sender,
        "MSG\tgeneral\t"
        "6d132e83884b1b52086c5fec5cad584c00d88c61b4506157da037e4f07539322\t"
        "21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9\t"
        "1715100000000\t"
        "aGVsbG8\t"
        "l6on5V73Zud-lyHhcvUZRUbmhyoro5IWyfEPZ3fquLrLRHe1mzoTlCeVXkuY98mV_rRnXFS_Ex-5DwQS-aL6Cg\n");

    usleep(200000);

    char buf1[4096], buf2[4096];
    ssize_t r1 = read_timeout(sub1, buf1, sizeof(buf1) - 1, 2000);
    ssize_t r2 = read_timeout(sub2, buf2, sizeof(buf2) - 1, 2000);

    write_str(sub1, "BYE\n");
    write_str(sub2, "BYE\n");
    close(sender);
    close(sub1);
    close(sub2);

    int status;
    waitpid(child, &status, 0);

    printf("  sub1 received %zd bytes\n", r1);
    printf("  sub2 received %zd bytes\n", r2);

    if (r1 > 0) {
        buf1[r1] = '\0';
        printf("  sub1: %s", buf1);
        assert(strstr(buf1, "MSG\tgeneral\t") != NULL);
        assert(strstr(buf1, "aGVsbG8") != NULL);
    } else {
        printf("FAIL: sub1 got no fanout\n");
        return 1;
    }

    if (r2 > 0) {
        buf2[r2] = '\0';
        printf("  sub2: %s", buf2);
        assert(strstr(buf2, "MSG\tgeneral\t") != NULL);
    } else {
        printf("FAIL: sub2 got no fanout\n");
        return 1;
    }

    printf("ok broadcast test passed\n");
    return 0;
}
