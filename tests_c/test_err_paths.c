#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <assert.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include "chat1_ffi.h"

static int open_listener(uint16_t *port_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    socklen_t alen = sizeof(addr);
    int one = 1;
    assert(fd >= 0);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(fd, 16) == 0);
    assert(getsockname(fd, (struct sockaddr *)&addr, &alen) == 0);
    *port_out = ntohs(addr.sin_port);
    return fd;
}

static int connect_loop(uint16_t port) {
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

static void send_str(int fd, const char *s) {
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        assert(w > 0);
        s += w;
        n -= (size_t)w;
    }
}

static ssize_t recv_line_timeout(int fd, char *out, size_t cap, int ms) {
    struct timeval tv;
    fd_set fds;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    if (select(fd + 1, &fds, NULL, NULL, &tv) <= 0) return 0;
    ssize_t n = read(fd, out, cap - 1);
    if (n > 0) out[n] = '\0';
    return n;
}

int main(void) {
    uint16_t port = 0;
    int lfd = open_listener(&port);
    pid_t child = fork();
    assert(child >= 0);

    if (child == 0) {
        chat1_room_engine_init_c(1024, 65536);
        chat1_sub_table_init();
        chat1_conn_table_reset();
        chat1_auth_keys_init();
        int rc = chat1_serve_once(lfd, 0);
        close(lfd);
        _exit(rc == CHAT1_SERVE_OK ? 0 : 1);
    }

    int cfd = connect_loop(port);
    char buf[1024];

    send_str(cfd, "HELLO\tcli\t1\tn\t11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo\n");
    assert(recv_line_timeout(cfd, buf, sizeof(buf), 2000) > 0);
    assert(strstr(buf, "HELLO\tchat1d\t1\t0") != NULL);

    send_str(cfd, "KICK\tfoo\n");
    assert(recv_line_timeout(cfd, buf, sizeof(buf), 2000) > 0);
    assert(strstr(buf, "ERR\tunsupported-command\t") != NULL);

    send_str(cfd,
        "MSG\tgeneral\t"
        "6d132e83884b1b52086c5fec5cad584c00d88c61b4506157da037e4f07539322\t"
        "21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9\t"
        "1715100000000\t"
        "aGVsbG8\t"
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n");
    assert(recv_line_timeout(cfd, buf, sizeof(buf), 2000) > 0);
    assert(strstr(buf, "ERR\tbad-signature\t") != NULL);

    close(cfd);
    close(lfd);

    int status = 0;
    waitpid(child, &status, 0);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    printf("ok err paths\n");
    return 0;
}
