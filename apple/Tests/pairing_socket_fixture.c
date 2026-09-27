// SPDX-License-Identifier: GPL-3.0-or-later
// Loopback-only fixture for the actual Swift NWConnection adapter. No hardware,
// Host, administrator privileges or system identity store is involved.
#define _DARWIN_C_SOURCE
#include "pair_wire.h"
#include "link.h"
#include <arpa/inet.h>
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ms(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
static int approved(void *context, const uint8_t key[32]) {
    return pltr_identity_store_approve(context, key);
}
static void transmit(int fd, const uint8_t *bytes, size_t size) {
    // Exercise arbitrarily split records, not only one-read-per-frame tests.
    for (size_t i = 0; i < size; ++i) {
        if (write(fd, bytes + i, 1) != 1) return;
    }
}
int main(int argc, char **argv) {
    assert(argc == 3);
    alarm(12);
    signal(SIGPIPE, SIG_IGN);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 1) == 0);
    socklen_t length = sizeof(address);
    assert(getsockname(listener, (struct sockaddr *)&address, &length) == 0);
    printf("%u\n", ntohs(address.sin_port));
    fflush(stdout);
    int fd = accept(listener, NULL, NULL);
    assert(fd >= 0);
    if (strcmp(argv[1], "stall") == 0) {
        uint8_t byte;
        while (read(fd, &byte, 1) > 0) {}
        close(fd); close(listener); return 0;
    }
    PltrIdentityStore store;
    assert(pltr_identity_store_open(&store, argv[2]) == 0);
    const int check = strcmp(argv[1], "check") == 0;
    PltrPairing pairing;
    PltrPairWire wire;
    PltrLink link;
    if (check) {
        assert(pltr_link_init(&link, PLTR_NOISE_RESPONDER, store.private_key,
                             NULL, approved, &store, 2) == 0);
    } else {
        assert(pltr_pairing_init(&pairing, &store, (const uint8_t *)"Fixture", 7) == 0);
        assert(pltr_pairing_open(&pairing, now_ms(), 0) == 0);
        assert(pltr_pair_wire_init(&wire, &pairing, 2) == 0);
    }
    uint8_t input[4096], output[8448];
    int done = 0;
    while (!done) {
        ssize_t size = read(fd, input, sizeof(input));
        if (size <= 0) break;
        size_t offset = 0;
        while (offset < (size_t)size && !done) {
            size_t consumed = 0, written = 0;
            int result;
            if (check) {
                PltrFrame frame = {0};
                result = pltr_link_receive(&link, input + offset, (size_t)size - offset,
                    &consumed, output, sizeof(output), &written, &frame);
                // This setup-only connection must NEVER start a Host/HID session.
                if (result >= 0) assert(frame.type == 0 || frame.type == PLTR_GOODBYE);
                if (frame.type == PLTR_GOODBYE) done = 1;
            } else {
                result = pltr_pair_wire_receive(&wire, input + offset, (size_t)size - offset,
                    &consumed, now_ms(), output, sizeof(output), &written);
            }
            if (result < 0 || consumed == 0) { done = 1; break; }
            offset += consumed;
            if (written) transmit(fd, output, written);
            if (!check && wire.stage == PLTR_PAIR_WIRE_KEYS) {
                for (uint8_t key = 1; key <= 5; ++key) {
                    written = 0;
                    result = pltr_pair_wire_key(&wire, key, now_ms(), output, sizeof(output), &written);
                    assert(result >= 0);
                    if (written) transmit(fd, output, written);
                }
            }
            if (!check && wire.stage == PLTR_PAIR_WIRE_DONE) done = 1;
        }
    }
    if (check) pltr_link_clear(&link);
    else { pltr_pair_wire_close(&wire, now_ms()); pltr_pairing_clear(&pairing); }
    pltr_identity_store_close(&store);
    close(fd); close(listener);
    return 0;
}
