// SPDX-License-Identifier: GPL-3.0-or-later
#define _POSIX_C_SOURCE 200809L
#include "ble_lab.h"
#include "client_pair.h"
#include "client_link.h"
#include "identity.h"
#include "protocol.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t now = 100;
static uint8_t a[4096], b[4096], relay[32];
static size_t an, bn;

static void feed(PltrBleLab *lab, const uint8_t *bytes, size_t size) {
    bn = 0;
    for (size_t offset = 0; offset < size;) {
        size_t consumed, written;
        size_t chunk = size-offset < 7 ? size-offset : 7;
        assert(pltr_ble_lab_receive(lab, bytes+offset, chunk, &consumed, now,
            b+bn, sizeof(b)-bn, &written) >= 0);
        assert(consumed && consumed <= chunk);
        bn += written;
        offset += consumed;
    }
}

static int client_receive(PltrClientPair *client) {
    int result = 0;
    an = 0;
    for (size_t offset = 0; offset < bn;) {
        size_t consumed, written;
        size_t chunk = bn-offset < 20 ? bn-offset : 20;
        int value = pltr_client_pair_receive(client, b+offset, chunk, &consumed,
            a+an, sizeof(a)-an, &written, relay);
        if (value < 0) return value;
        if (value) result = value;
        assert(consumed && consumed <= chunk);
        an += written;
        offset += consumed;
    }
    return result;
}

static void status(PltrClientPair *client, int attached, int presses) {
    assert(client_receive(client) == 3);
    uint8_t data[8];
    assert(pltr_client_pair_approval_status(client, data) == 0);
    assert(data[1] == attached && data[2] == presses && data[3] == 3);
}

static PltrClientPair *start(PltrBleLab *lab) {
    const uint8_t key[32] = {73};
    PltrClientPair *client = pltr_client_pair_create_button(key, (const uint8_t *)"button test", 11);
    assert(client);
    assert(pltr_client_pair_start(client, a, sizeof(a), &an) == 0);
    now += 100;
    feed(lab, a, an);
    assert(pltr_ble_lab_approval_pending(lab) != 0);
    return client;
}

static void button(PltrBleLab *lab, unsigned code, int value, unsigned elapsed) {
    now += elapsed;
    assert(pltr_ble_lab_button(lab, code, value, 1000, now, b, sizeof(b), &bn) >= 0);
}

static void press(PltrBleLab *lab, unsigned code) {
    button(lab, code, 1, 100); assert(bn == 0);
    button(lab, code, 0, 100);
}

int main(void) {
    char directory[] = "/tmp/pltr-button-pair-XXXXXX";
    assert(mkdtemp(directory));
    PltrBleLab *lab = pltr_ble_lab_create(directory);
    assert(lab);
    // No request: local presses cannot enroll an arbitrary future connection.
    pltr_ble_lab_tablet(lab, 1);
    for (int i = 0; i < 3; ++i) { press(lab, 264); assert(bn == 0); }
    pltr_ble_lab_tablet(lab, 0);
    PltrClientPair *client = start(lab);
    status(client, 0, 0);
    press(lab, 264); assert(bn == 0); // no connected tablet
    pltr_ble_lab_tablet(lab, 1);
    now += 100;
    assert(pltr_ble_lab_tick(lab, now, b, sizeof(b), &bn) == 1);
    status(client, 1, 0);
    press(lab, 264); status(client, 1, 1);
    press(lab, 264); status(client, 1, 2);
    // No confirmation or trust after only two releases. Cancellation clears them.
    pltr_client_pair_destroy(client);
    pltr_ble_lab_disconnect(lab, now);
    client = start(lab); status(client, 1, 0);
    button(lab, 264, 0, 20); assert(bn == 0); // stale release
    button(lab, 264, 1, 100);
    button(lab, 264, 1, 100); // duplicate down is not a second physical press
    button(lab, 264, 0, 100); assert(bn == 0);
    now += 10; assert(pltr_ble_lab_tick(lab, now, b, sizeof(b), &bn) == 1);
    status(client, 1, 0);
    button(lab, 264, 1, 100);
    for (int i = 0; i < 4; ++i) { button(lab, 264, 2, 100); assert(bn == 0); }
    button(lab, 264, 0, 100); status(client, 1, 1); // autorepeat is one press
    button(lab, 264, 1, 100);
    button(lab, 264, 0, 1500); assert(bn == 0); // held key resets progress
    now += 10; assert(pltr_ble_lab_tick(lab, now, b, sizeof(b), &bn) == 1);
    status(client, 1, 0);
    press(lab, 264); status(client, 1, 1);
    press(lab, 256); status(client, 1, 1); // another button starts a new gesture
    pltr_ble_lab_tablet(lab, 0);
    pltr_ble_lab_tablet(lab, 1);
    now += 100; assert(pltr_ble_lab_tick(lab, now, b, sizeof(b), &bn) == 1);
    status(client, 1, 0); // sleep/wake clears progress
    press(lab, 256); status(client, 1, 1);
    now += 2200; assert(pltr_ble_lab_tick(lab, now, b, sizeof(b), &bn) == 1);
    status(client, 1, 0); // slow/spaced presses do not accumulate forever
    pltr_client_pair_destroy(client);
    pltr_ble_lab_disconnect(lab, now);
    client = start(lab); status(client, 1, 0);
    uint8_t forged[32] = {0}; size_t encoded, consumed;
    assert(pltr_encode_frame(PLTR_PAIR_CONFIRM, 3, forged, sizeof(forged),
        PLTR_CLIENT_TO_RELAY, PLTR_PRE_AUTH, a+2, sizeof(a)-2, &encoded) == 0);
    a[0] = encoded; a[1] = encoded >> 8;
    assert(pltr_ble_lab_receive(lab, a, encoded+2, &consumed, now,
        b, sizeof(b), &bn) < 0); // no network confirmation can replace the gesture
    pltr_client_pair_destroy(client); pltr_ble_lab_disconnect(lab, now);
    // More than three remote cancellations must not lock out physical approval.
    for (int i = 0; i < 4; ++i) {
        client = start(lab); status(client, 1, 0);
        pltr_client_pair_destroy(client); pltr_ble_lab_disconnect(lab, now);
    }
    client = start(lab); status(client, 1, 0);
    now += 60001;
    assert(pltr_ble_lab_tick(lab, now, b, sizeof(b), &bn) == 1);
    assert(client_receive(client) < 0); // expired request cannot be approved
    pltr_client_pair_destroy(client); pltr_ble_lab_disconnect(lab, now);
    client = start(lab); status(client, 1, 0);
    press(lab, 264); status(client, 1, 1);
    press(lab, 264); status(client, 1, 2);
    press(lab, 264); assert(bn > 0);
    assert(client_receive(client) == 1 && an > 0); // key confirmation still required
    feed(lab, a, an);
    assert(client_receive(client) == 2);
    pltr_client_pair_destroy(client); pltr_ble_lab_destroy(lab);
    // The app keeps its client identity even if local relay trust is lost or
    // discovery yields a new peripheral identifier. Re-approval must work
    // without deleting either side's keys, including with a full allowlist.
    uint8_t original_relay[32], original_clients[PLTR_MAX_PAIRED_CLIENTS][32];
    memcpy(original_relay, relay, sizeof(relay));
    PltrIdentityStore store;
    assert(pltr_identity_store_open(&store, directory) == 0);
    assert(store.client_count == 1);
    for (unsigned i = 1; i < PLTR_MAX_PAIRED_CLIENTS; ++i) {
        uint8_t other[32] = {0}; other[0] = i;
        assert(pltr_identity_store_add(&store, other) == 0);
    }
    memcpy(original_clients, store.client_keys, sizeof(original_clients));
    pltr_identity_store_close(&store);
    lab = pltr_ble_lab_create(directory); assert(lab);
    client = start(lab); status(client, 0, 0);
    assert(pltr_ble_lab_approval_pending(lab) == 2);
    pltr_client_pair_destroy(client); pltr_ble_lab_disconnect(lab, now);
    pltr_ble_lab_tablet(lab, 1);
    client = start(lab); status(client, 1, 0);
    press(lab, 264); status(client, 1, 1);
    press(lab, 264); status(client, 1, 2);
    // A known key still needs a fresh gesture and cryptographic confirmation.
    assert(pltr_encode_frame(PLTR_PAIR_CONFIRM, 3, forged, sizeof(forged),
        PLTR_CLIENT_TO_RELAY, PLTR_PRE_AUTH, a+2, sizeof(a)-2, &encoded) == 0);
    a[0] = encoded; a[1] = encoded >> 8;
    assert(pltr_ble_lab_receive(lab, a, encoded+2, &consumed, now,
        b, sizeof(b), &bn) < 0);
    pltr_client_pair_destroy(client); pltr_ble_lab_disconnect(lab, now);
    client = start(lab); status(client, 1, 0);
    press(lab, 264); status(client, 1, 1);
    press(lab, 264); status(client, 1, 2);
    press(lab, 264); assert(client_receive(client) == 1 && an > 0);
    a[an-1] ^= 1; // A bad final tag cannot report successful re-approval.
    feed(lab, a, an); assert(client_receive(client) < 0);
    pltr_client_pair_destroy(client); pltr_ble_lab_disconnect(lab, now);
    client = start(lab); status(client, 1, 0);
    press(lab, 264); status(client, 1, 1);
    press(lab, 264); status(client, 1, 2);
    press(lab, 264); assert(client_receive(client) == 1 && an > 0);
    feed(lab, a, an); assert(client_receive(client) == 2);
    assert(memcmp(original_relay, relay, sizeof(relay)) == 0);
    pltr_client_pair_destroy(client); pltr_ble_lab_destroy(lab);
    assert(pltr_identity_store_open(&store, directory) == 0);
    assert(store.client_count == PLTR_MAX_PAIRED_CLIENTS);
    assert(memcmp(original_clients, store.client_keys, sizeof(original_clients)) == 0);
    pltr_identity_store_close(&store);
    // Successful approval persisted the client; restart alone does not clear it.
    lab = pltr_ble_lab_create(directory); assert(lab);
    const uint8_t private_key[32] = {73};
    PltrClientLink *link = pltr_client_link_create(private_key, relay, 1);
    assert(link && pltr_client_link_start(link, a, sizeof(a), &an) == 0);
    feed(lab, a, an);
    an = 0;
    for (size_t offset = 0; offset < bn;) {
        uint8_t payload[8192]; uint16_t type; size_t used, written, payload_size;
        assert(pltr_client_link_receive(link, b+offset, bn-offset, &used,
            a+an, sizeof(a)-an, &written, &type, payload, sizeof(payload), &payload_size) >= 0);
        assert(used); offset += used; an += written;
    }
    assert(pltr_client_link_peer_version(link));
    feed(lab, a, an);
    pltr_client_link_destroy(link);
    pltr_ble_lab_destroy(lab);
    const char *files[] = {"identity.key", "paired-clients.json", "store.lock", "pair-budget"};
    for (unsigned i = 0; i < 4; ++i) {
        char path[256]; snprintf(path, sizeof(path), "%s/%s", directory, files[i]);
        assert(unlink(path) == 0);
    }
    assert(rmdir(directory) == 0);
    puts("PASS: button approval, re-approval, full allowlist, cancellation, wake and confirmation");
}
