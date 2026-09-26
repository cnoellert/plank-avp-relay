#define _POSIX_C_SOURCE 200809L
#include "client_pair.h"
#include "noise.h"
#include "pair_wire.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    char directory[] = "/tmp/pltr-pair-e2e-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    PltrIdentityStore store;
    assert(pltr_identity_store_open(&store, directory) == 0);
    PltrPairing relay;
    assert(pltr_pairing_init(&relay, &store,
                             (const uint8_t *)"NUC", 3) == 0);
    assert(pltr_pairing_open(&relay, 100, 0) == 0);
    uint8_t private_key[32] = {7}, public_key[32];
    assert(pltr_noise_public_key(private_key, public_key) == 0);
    const uint8_t code[] = "12345";
    PltrClientPair *client = pltr_client_pair_create(
        private_key, code, (const uint8_t *)"AVP", 3, 2);
    assert(client != NULL);
    PltrPairWire wire;
    assert(pltr_pair_wire_init(&wire, &relay, 2) == 0);
    uint8_t start[256], response[256], confirm[256], result[256],
            pinned_relay_key[32] = {0};
    size_t start_size, response_size, confirm_size, result_size;
    assert(pltr_client_pair_start(client, start, sizeof(start),
                                  &start_size) == 0);
    size_t offset = 0;
    while (offset < start_size) {
        size_t consumed, written;
        assert(pltr_pair_wire_receive(&wire, start + offset,
                                      start_size - offset, &consumed,
                                      101, response, sizeof(response),
                                      &written) == 1);
        assert(consumed != 0 && written == 0);
        offset += consumed;
    }
    assert(wire.stage == PLTR_PAIR_WIRE_KEYS);
    assert(pltr_identity_store_approve(&store, public_key) == 0);
    for (uint8_t key = 1; key <= 5; ++key) {
        const int status = pltr_pair_wire_key(&wire, key, 110 + key,
                                               response, sizeof(response),
                                               &response_size);
        assert(status == (key == 5 ? 1 : 0));
    }
    size_t consumed;
    assert(pltr_client_pair_receive(client, response, response_size,
                                    &consumed, confirm, sizeof(confirm),
                                    &confirm_size, pinned_relay_key) == 1);
    assert(consumed == response_size && confirm_size != 0);
    assert(memcmp(pinned_relay_key, store.public_key, 32) != 0);
    assert(pltr_pair_wire_receive(&wire, confirm, confirm_size,
                                  &consumed, 120, result, sizeof(result),
                                  &result_size) == 1);
    assert(consumed == confirm_size && result_size != 0);
    assert(pltr_client_pair_receive(client, result, result_size,
                                    &consumed, confirm, sizeof(confirm),
                                    &confirm_size, pinned_relay_key) == 2);
    assert(consumed == result_size && confirm_size == 0 &&
           memcmp(pinned_relay_key, store.public_key, 32) == 0 &&
           pltr_identity_store_approve(&store, public_key) == 1);
    pltr_client_pair_destroy(client);
    pltr_pair_wire_close(&wire, 121);
    pltr_pairing_clear(&relay);
    pltr_identity_store_close(&store);
    const char *files[] = {"identity.key", "paired-clients.json", "store.lock"};
    for (size_t i = 0; i < 3; ++i) {
        char path[160];
        assert(snprintf(path, sizeof(path), "%s/%s", directory, files[i]) <
               (int)sizeof(path));
        assert(unlink(path) == 0);
    }
    assert(rmdir(directory) == 0);
    return 0;
}
