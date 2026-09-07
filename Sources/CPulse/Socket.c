#include "CPulse.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
int pulse_prepare(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return -1;
#ifdef SO_NOSIGPIPE
    int yes = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) < 0) return -1;
#endif
    return 0;
}
int pulse_listen(const char *address, uint16_t port, int backlog) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET; addr.sin_port = htons(port);
    if (inet_pton(AF_INET, address, &addr.sin_addr) != 1) { pulse_close(fd); errno = EINVAL; return -1; }
    if (pulse_prepare(fd) < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, backlog) < 0) {
        int saved = errno; pulse_close(fd); errno = saved; return -1;
    }
    return fd;
}
int pulse_accept(int fd) {
    int child = accept(fd, NULL, NULL);
    if (child >= 0 && pulse_prepare(child) < 0) { int saved = errno; pulse_close(child); errno = saved; return -1; }
    return child;
}
int pulse_pair(int fds[2]) {
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) return -1;
    if (pulse_prepare(fds[0]) < 0 || pulse_prepare(fds[1]) < 0) {
        int saved = errno; pulse_close(fds[0]); pulse_close(fds[1]); errno = saved; return -1;
    }
    return 0;
}
ssize_t pulse_receive(int fd, void *buffer, size_t size) { return recv(fd, buffer, size, 0); }
ssize_t pulse_send(int fd, const void *buffer, size_t size) {
#ifdef MSG_NOSIGNAL
    return send(fd, buffer, size, MSG_NOSIGNAL);
#else
    return send(fd, buffer, size, 0);
#endif
}
int pulse_errno(void) { return errno; }
int pulse_would_block(int e) { return e == EAGAIN || e == EWOULDBLOCK; }
int pulse_interrupted(int e) { return e == EINTR; }
void pulse_close(int fd) { if (fd >= 0) close(fd); }
uint16_t pulse_port(int fd) {
    struct sockaddr_in addr; socklen_t length = sizeof(addr);
    return getsockname(fd, (struct sockaddr *)&addr, &length) == 0 ? ntohs(addr.sin_port) : 0;
}
uint64_t pulse_thread_id(void) {
#ifdef __linux__
    return (uint64_t)syscall(SYS_gettid);
#else
    uint64_t id = 0; pthread_threadid_np(NULL, &id); return id;
#endif
}
