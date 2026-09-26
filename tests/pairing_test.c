#define _POSIX_C_SOURCE 200809L
#include "pairing.h"
#include "confirm.h"
#include "noise.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void remove_store(const char *directory) {
    char name[128];
    const char *files[] = {"identity.key", "paired-clients.json", "store.lock"};
    for (size_t i = 0; i < 3; ++i) {
        assert(snprintf(name, sizeof(name), "%s/%s", directory, files[i]) < (int)sizeof(name));
        assert(unlink(name) == 0);
    }
    assert(rmdir(directory) == 0);
}

int main(void) {
    char directory[] = "/tmp/pltr-pair-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    PltrIdentityStore store;
    assert(pltr_identity_store_open(&store, directory) == 0);
    PltrPairing relay;
    assert(pltr_pairing_init(&relay, &store, (const uint8_t *)"Relay", 5) == 0);

    uint8_t private_key[32], client_key[32], client_ad[36] = {0};
    for (size_t i = 0; i < sizeof(private_key); ++i)
        private_key[i] = (uint8_t)(i + 1);
    assert(pltr_noise_public_key(private_key, client_key) == 0);
    memcpy(client_ad, client_key, 32);
    client_ad[32] = 3;
    memcpy(client_ad + 33, "AVP", 3);
    uint8_t sid[16] = {1, 2, 3};
    const uint8_t code[] = "12345";
    uint8_t client_share[32], client_key_material[64];
    PltrCpace client;
    assert(pltr_cpace_start(&client, PLTR_CPACE_INITIATOR, code,
                             2, sid, client_ad, sizeof(client_ad),
                             client_share) == 0);
    uint8_t start[16 + 32 + sizeof(client_ad)];
    memcpy(start, sid, 16);
    memcpy(start + 16, client_share, 32);
    memcpy(start + 48, client_ad, sizeof(client_ad));
    assert(pltr_pairing_open(&relay, 100, 1) != 0); // active session blocks pairing
    assert(pltr_pairing_open(&relay, 100, 0) == 0);
    assert(pltr_pairing_start(&relay, start, sizeof(start), 2, 101) == 0);
    assert(pltr_pairing_open(&relay, 102, 0) != 0); // one attempt per window
    uint8_t response[129];
    size_t response_size;
    for (uint8_t key = 1; key <= 4; ++key)
        assert(pltr_pairing_key(&relay, key, 200 + key,
                                response, sizeof(response), &response_size) == 0 &&
               response_size == 0);
    assert(pltr_pairing_key(&relay, 5, 205,
                            response, sizeof(response), &response_size) == 1);
    assert(response_size == 32 + relay.relay_ad_size);
    assert(pltr_cpace_finish(&client, response, response + 32,
                             response_size - 32, client_key_material) == 0);
    uint8_t client_tag[32], result[33];
    size_t result_size;
    assert(pltr_pair_confirmation_tag(client_key_material,
                                      PLTR_CPACE_INITIATOR, sid,
                                      client_share, client_ad, sizeof(client_ad),
                                      response, response + 32,
                                      response_size - 32, client_tag) == 0);
    assert(pltr_pairing_confirm(&relay, client_tag, 300,
                                 result, &result_size) == 1);
    assert(result_size == 33 && result[0] == 0);
    assert(pltr_pair_confirmation_verify(client_key_material,
                                         PLTR_CPACE_RESPONDER, sid,
                                         client_share, client_ad, sizeof(client_ad),
                                         response, response + 32,
                                         response_size - 32, result + 1) == 0);
    assert(pltr_identity_store_approve(&store, client_key) == 1);
    pltr_cpace_clear(&client);

    // A new Client with a bad confirmation never enters the allowlist.
    uint8_t other_private[32] = {9}, other_key[32];
    assert(pltr_noise_public_key(other_private, other_key) == 0);
    memcpy(start + 48, other_key, 32);
    uint8_t wrong_tag[32] = {0};
    PltrCpace wrong_client;
    uint8_t wrong_share[32], wrong_key_material[64];
    assert(pltr_cpace_start(&wrong_client, PLTR_CPACE_INITIATOR,
                             (const uint8_t *)"22222", 2, sid,
                             start + 48, sizeof(client_ad), wrong_share) == 0);
    memcpy(start + 16, wrong_share, 32);
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        uint64_t now = 1000 + attempt * 1000;
        assert(pltr_pairing_open(&relay, now, 0) == 0);
        assert(pltr_pairing_start(&relay, start, sizeof(start), 2, now + 1) == 0);
        for (uint8_t key = 1; key <= 5; ++key)
            assert(pltr_pairing_key(&relay, key, now + key + 1,
                                    response, sizeof(response), &response_size) ==
                   (key == 5 ? 1 : 0));
        if (attempt == 0) {
            assert(pltr_cpace_finish(&wrong_client, response,
                                     response + 32, response_size - 32,
                                     wrong_key_material) == 0);
            assert(pltr_pair_confirmation_tag(wrong_key_material,
                                              PLTR_CPACE_INITIATOR, sid,
                                              wrong_share, start + 48,
                                              sizeof(client_ad), response,
                                              response + 32,
                                              response_size - 32,
                                              wrong_tag) == 0);
        }
        assert(pltr_pairing_confirm(&relay, wrong_tag, now + 10,
                                     result, &result_size) == 1);
        assert(result_size == 1 && result[0] == 1);
        memset(wrong_tag, 0, sizeof(wrong_tag));
    }
    assert(relay.stage == PLTR_PAIR_LOCKED);
    assert(pltr_identity_store_approve(&store, other_key) == 0);
    assert(pltr_pairing_open(&relay, 600000, 0) != 0);
    assert(pltr_pairing_open(&relay, relay.lockout_until_ms, 0) == 0);
    assert(pltr_pairing_tick(&relay, relay.deadline_ms) == 0);
    assert(relay.stage == PLTR_PAIR_CLOSED);

    // Starting consumes the window and expires after 60 seconds.
    assert(pltr_pairing_open(&relay, 700000, 0) == 0);
    assert(pltr_pairing_start(&relay, start, sizeof(start), 2, 700001) == 0);
    assert(pltr_pairing_tick(&relay, 760001) == 1);
    assert(relay.stage == PLTR_PAIR_CLOSED);

    pltr_pairing_clear(&relay);
    pltr_identity_store_close(&store);
    remove_store(directory);
    return 0;
}
