// SPDX-License-Identifier: GPL-3.0-or-later
#define _POSIX_C_SOURCE 200809L
#include "ble_lab.h"
#include "client_link.h"
#include "client_pair.h"
#include "protocol.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int feed(PltrBleLab *lab, const uint8_t *data, size_t size, uint8_t *out, size_t *written) {
    *written = 0;
    for (size_t offset = 0; offset < size;) {
        size_t consumed = 0, reply_size = 0;
        size_t chunk = size-offset < 7 ? size-offset : 7;
        int result = pltr_ble_lab_receive(lab, data+offset, chunk, &consumed, 200,
            out+*written, 4096-*written, &reply_size);
        if (result < 0) return -1;
        assert(consumed > 0 && consumed <= chunk);
        *written += reply_size;
        offset += consumed;
    }
    return 0;
}

static void client_feed(PltrClientLink *client, const uint8_t *data, size_t size,
                        uint8_t *reply, size_t *written, uint16_t *type) {
    *written = 0; *type = 0;
    for (size_t offset = 0; offset < size;) {
        size_t consumed = 0, reply_size = 0, payload_size = 0;
        uint16_t frame_type = 0;
        uint8_t payload[8192];
        size_t chunk = size-offset < 20 ? size-offset : 20;
        assert(pltr_client_link_receive(client, data+offset, chunk, &consumed,
            reply+*written, 4096-*written, &reply_size, &frame_type,
            payload, sizeof(payload), &payload_size) >= 0);
        assert(consumed > 0 && consumed <= chunk);
        if (frame_type) *type = frame_type;
        if (frame_type == PLTR_INPUT_SAMPLE) {
            assert(payload_size == PLTR_INPUT_SAMPLE_SIZE && payload[0] == 1);
        }
        *written += reply_size; offset += consumed;
    }
}

static PltrClientLink *connect_client(PltrBleLab *lab, const uint8_t *private_key,
                                     const uint8_t *relay_key, int observer) {
    PltrClientLink *client = pltr_client_link_create(private_key, relay_key, 1);
    assert(client);
    if (observer) assert(pltr_client_link_enable_input_observer(client) == 0);
    if (observer == 2) assert(pltr_client_link_enable_tablet_management(client) == 0);
    uint8_t a[4096], b[4096]; size_t an, bn; uint16_t type;
    assert(pltr_client_link_start(client, a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) == 0);
    client_feed(client, b, bn, a, &an, &type);
    assert(feed(lab, a, an, b, &bn) == 0 && bn == 0);
    assert(pltr_client_link_peer_version(client));
    return client;
}

int main(void) {
    char directory[] = "/tmp/pltr-ble-lab-XXXXXX";
    assert(mkdtemp(directory));
    PltrBleLab *lab = pltr_ble_lab_create(directory);
    assert(lab);
    assert(!pltr_ble_lab_has_clients(lab));
    uint8_t private_key[32] = {19}, relay_key[32] = {0};
    const uint8_t code[] = "12345";
    uint8_t a[4096], b[4096], sample[PLTR_INPUT_SAMPLE_SIZE] = {1};
    size_t an, bn, consumed; uint16_t type;
    assert(pltr_ble_lab_sample(lab, sample, sizeof(sample), a, sizeof(a), &an) < 0);
    assert(pltr_ble_lab_open_pairing(lab, 1000, 100) == 0);
    PltrClientPair *pair = pltr_client_pair_create(private_key, code, (const uint8_t *)"test", 4, 1);
    assert(pair);
    assert(pltr_client_pair_start(pair, a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) == 0 && bn == 0);
    for (uint8_t digit = 1; digit <= 5; ++digit)
        assert(pltr_ble_lab_key(lab, digit, 150+digit, b, sizeof(b), &bn) >= 0);
    assert(bn > 0);
    assert(pltr_client_pair_receive(pair, b, bn, &consumed, a, sizeof(a), &an, relay_key) == 1);
    assert(feed(lab, a, an, b, &bn) == 0);
    assert(pltr_client_pair_receive(pair, b, bn, &consumed, a, sizeof(a), &an, relay_key) == 2);
    pltr_client_pair_destroy(pair);
    pltr_ble_lab_disconnect(lab, 201);

    // Trust survives process restart; no injected allowlist or authentication bypass.
    pltr_ble_lab_destroy(lab);
    lab = pltr_ble_lab_create(directory);
    assert(lab);
    PltrClientLink *client = connect_client(lab, private_key, relay_key, 1);
    assert(!pltr_ble_lab_observing(lab));
    assert(pltr_ble_lab_sample(lab, sample, sizeof(sample), a, sizeof(a), &an) < 0);
    const uint8_t enable = 1, disable = 0;
    assert(pltr_client_link_send(client, PLTR_INPUT_OBSERVE, &enable, 1, a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) == 0 && pltr_ble_lab_observing(lab));
    assert(pltr_ble_lab_sample(lab, sample, sizeof(sample), b, sizeof(b), &bn) == 0);
    client_feed(client, b, bn, a, &an, &type);
    assert(type == PLTR_INPUT_SAMPLE && an == 0);
    assert(pltr_client_link_send(client, PLTR_INPUT_OBSERVE, &disable, 1, a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) == 0 && !pltr_ble_lab_observing(lab));
    assert(pltr_ble_lab_sample(lab, sample, sizeof(sample), a, sizeof(a), &an) < 0);
    // A successful connection check closes cleanly, without an ATT write error.
    const uint8_t goodbye[] = {1, 0};
    assert(pltr_client_link_send(client, PLTR_GOODBYE, goodbye, sizeof(goodbye), a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) == 0 && bn == 0);
    assert(pltr_ble_lab_tick(lab, 201, b, sizeof(b), &bn) == 0 && bn == 0);
    assert(pltr_ble_lab_tick(lab, 10201, b, sizeof(b), &bn) < 0);
    pltr_client_link_destroy(client);
    pltr_ble_lab_disconnect(lab, 202);

    // Both ends must opt in; the old default does not grant observation.
    client = connect_client(lab, private_key, relay_key, 0);
    assert(pltr_client_link_send(client, PLTR_INPUT_OBSERVE, &enable, 1, a, sizeof(a), &an) < 0);
    pltr_client_link_destroy(client);
    pltr_ble_lab_disconnect(lab, 203);

    // Management is an authenticated extension; it never starts observation.
    const uint8_t request[] = "{\"version\":1,\"id\":1,\"op\":\"status\"}";
    const uint8_t response[] = "{\"ok\":true}";
    assert(pltr_ble_lab_has_clients(lab));
    assert(pltr_ble_lab_management_reply(lab, response, sizeof(response)-1, b, sizeof(b), &bn) < 0);
    client = connect_client(lab, private_key, relay_key, 0);
    assert(pltr_client_link_send(client, PLTR_TABLET_REQUEST, request, sizeof(request)-1,
                                a, sizeof(a), &an) < 0);
    pltr_client_link_destroy(client);
    pltr_ble_lab_disconnect(lab, 203);
    client = connect_client(lab, private_key, relay_key, 2);
    assert(pltr_client_link_send(client, PLTR_TABLET_REQUEST, request, sizeof(request)-1,
                                a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) == 0 && bn == 0);
    assert(pltr_ble_lab_take_management(lab, b, sizeof(b)) == sizeof(request)-1);
    assert(memcmp(request, b, sizeof(request)-1) == 0);
    assert(pltr_ble_lab_take_management(lab, b, sizeof(b)) == 0);
    assert(!pltr_ble_lab_observing(lab));
    assert(pltr_ble_lab_reset_clients(lab) < 0); // Recovery is local and requires an idle store.
    assert(pltr_ble_lab_management_reply(lab, response, sizeof(response)-1, b, sizeof(b), &bn) == 0);
    client_feed(client, b, bn, a, &an, &type);
    assert(type == PLTR_TABLET_RESPONSE && an == 0);
    pltr_client_link_destroy(client);
    pltr_ble_lab_disconnect(lab, 203);

    // A stranger cannot authenticate or obtain readings with a known relay key.
    uint8_t stranger[32] = {29};
    client = pltr_client_link_create(stranger, relay_key, 1);
    assert(client && pltr_client_link_start(client, a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) < 0 && bn == 0);
    assert(!pltr_ble_lab_observing(lab));
    assert(pltr_ble_lab_take_management(lab, b, sizeof(b)) == 0);
    pltr_client_link_destroy(client);
    pltr_ble_lab_disconnect(lab, 204);

    // Do not accept a forged workstation session in this diagnostic service.
    client = connect_client(lab, private_key, relay_key, 1);
    const uint8_t ready[5] = {0x24, 0, 0, 0, 1};
    assert(pltr_client_link_send(client, PLTR_SESSION_READY, ready, sizeof(ready), a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) < 0);
    assert(!pltr_ble_lab_observing(lab));
    pltr_client_link_destroy(client);
    pltr_ble_lab_disconnect(lab, 204);
    assert(pltr_ble_lab_reset_clients(lab) == 0);
    assert(!pltr_ble_lab_has_clients(lab));
    pltr_ble_lab_destroy(lab);
    lab = pltr_ble_lab_create(directory);
    assert(lab && !pltr_ble_lab_has_clients(lab));
    client = pltr_client_link_create(private_key, relay_key, 1);
    assert(client && pltr_client_link_start(client, a, sizeof(a), &an) == 0);
    assert(feed(lab, a, an, b, &bn) < 0); // Revocation survives restart.
    pltr_client_link_destroy(client);
    pltr_ble_lab_destroy(lab);

    const char *files[] = {"identity.key", "paired-clients.json", "store.lock", "pair-budget"};
    for (unsigned i = 0; i < 4; ++i) {
        char path[256];
        assert(snprintf(path, sizeof(path), "%s/%s", directory, files[i]) < (int)sizeof(path));
        assert(unlink(path) == 0);
    }
    assert(rmdir(directory) == 0);
    puts("PASS: fragmented BLE pairing, persisted trust, observer gates and stranger rejection");
    return 0;
}
