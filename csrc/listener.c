#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int chat1_listener_setsockopt(int fd, int level, int optname, const void *optval, socklen_t optlen) {
    if (setsockopt(fd, level, optname, optval, optlen) != 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    return 0;
}

int chat1_listener_open(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    struct sockaddr_in addr;

    if (fd < 0) {
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    if (chat1_listener_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) != 0) {
        return -1;
    }
#ifdef SO_REUSEPORT
    if (chat1_listener_setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) != 0) {
        return -1;
    }
#endif
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    if (listen(fd, 1024) != 0) {
        close(fd);
        return -1;
    }

    return fd;
}
