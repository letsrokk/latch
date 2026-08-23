#include "LATCHNative.h"
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int latch_stat_path(const char *path, struct stat *result) {
    return stat(path, result);
}

int latch_lstat_path(const char *path, struct stat *result) {
    return lstat(path, result);
}

int latch_tcp_check(const char *host, unsigned short port, int timeout_milliseconds) {
    char service[6];
    snprintf(service, sizeof(service), "%hu", port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = AI_ADDRCONFIG;
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, service, &hints, &addresses) != 0) return 0;

    int reachable = 0;
    for (struct addrinfo *address = addresses; address != NULL && !reachable; address = address->ai_next) {
        int descriptor = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (descriptor < 0) continue;
        int flags = fcntl(descriptor, F_GETFL, 0);
        if (flags >= 0) fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
        int result = connect(descriptor, address->ai_addr, address->ai_addrlen);
        if (result == 0) {
            reachable = 1;
        } else if (errno == EINPROGRESS) {
            struct pollfd poll_descriptor = { .fd = descriptor, .events = POLLOUT, .revents = 0 };
            if (poll(&poll_descriptor, 1, timeout_milliseconds) > 0) {
                int socket_error = 0;
                socklen_t length = sizeof(socket_error);
                reachable = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socket_error, &length) == 0 && socket_error == 0;
            }
        }
        close(descriptor);
    }
    freeaddrinfo(addresses);
    return reachable;
}
