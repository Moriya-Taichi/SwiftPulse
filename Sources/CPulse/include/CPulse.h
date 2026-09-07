#ifndef CPULSE_H
#define CPULSE_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
int pulse_listen(const char *address, uint16_t port, int backlog);
int pulse_accept(int fd);
int pulse_prepare(int fd);
int pulse_pair(int fds[2]);
ssize_t pulse_receive(int fd, void *buffer, size_t size);
ssize_t pulse_send(int fd, const void *buffer, size_t size);
int pulse_errno(void);
int pulse_would_block(int error);
int pulse_interrupted(int error);
void pulse_close(int fd);
uint16_t pulse_port(int fd);
uint64_t pulse_thread_id(void);
void pulse_install_signals(void);
int pulse_signal_received(void);
void pulse_restore_signals(void);
#endif
