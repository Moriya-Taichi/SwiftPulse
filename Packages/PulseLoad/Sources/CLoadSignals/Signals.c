#include <stddef.h>
#include "CLoadSignals.h"
#include <signal.h>
static volatile sig_atomic_t received_signal = 0;
static struct sigaction previous_int, previous_term;
static void record_signal(int value) { received_signal = value; }
void load_install_signals(void) {
    received_signal = 0;
    struct sigaction action = {0};
    action.sa_handler = record_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, &previous_int);
    sigaction(SIGTERM, &action, &previous_term);
}
int load_signal_received(void) { return received_signal; }
void load_restore_signals(void) {
    sigaction(SIGINT, &previous_int, NULL);
    sigaction(SIGTERM, &previous_term, NULL);
}
