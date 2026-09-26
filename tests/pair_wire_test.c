#define _POSIX_C_SOURCE 200809L
#include "pair_wire.h"
#include "confirm.h"
#include "noise.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static size_t record(uint16_t type, uint32_t sequence,
                      const uint8_t *payload, size_t payload_size,
                      uint8_t *out, size_t capacity) {
    size_t frame_size;
    assert(capacity >= 2);
    assert(pltr_encode_frame(type, sequence, payload, payload_size,
                             PLTR_CLIENT_TO_RELAY, PLTR_PRE_AUTH,
                             out + 2, capacity - 2, &frame_size) == 0);
    out[0] = (uint8_t)frame_size;
    out[1] = (uint8_t)(frame_size >> 8);
    return frame_size + 2;
}

static int feed(PltrPairWire *wire, const uint8_t *bytes, size_t size,
                 uint64_t now_ms, uint8_t *out, size_t capacity,
                 size_t *written) {
    size_t consumed;
    const int result = pltr_pair_wire_receive(wire, bytes, size, &consumed,
                                               now_ms, out, capacity, written);
    assert(consumed == size);
    return result;
}

int main(void) {
    char directory[] = "/tmp/pltr-pair-wire-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    PltrIdentityStore store;
    assert(pltr_identity_store_open(&store, directory) == 0);
    PltrPairing pairing;
    assert(pltr_pairing_init(&pairing, &store,
                             (const uint8_t *)"Relay", 5) == 0);
    assert(pltr_pairing_open(&pairing, 100, 0) == 0);

    uint8_t private_key[32] = {7}, client_key[32];
    assert(pltr_noise_public_key(private_key, client_key) == 0);
    uint8_t client_ad[36] = {0};
    memcpy(client_ad, client_key, 32);
    client_ad[32] = 3;
    memcpy(client_ad + 33, "AVP", 3);
    const uint8_t sid[16] = {1, 2, 3};
    const uint8_t code[] = "12345";
    PltrCpace client;
    uint8_t share[32], material[64];
    assert(pltr_cpace_start(&client, PLTR_CPACE_INITIATOR, code, 2,
                             sid, client_ad, sizeof(client_ad), share) == 0);
    uint8_t start[16 + 32 + sizeof(client_ad)];
    memcpy(start, sid, 16);
    memcpy(start + 16, share, 32);
    memcpy(start + 48, client_ad, sizeof(client_ad));

    PltrPairWire wire;
    assert(pltr_pair_wire_init(&wire, &pairing, 2) == 0);
    uint8_t input[256], output[256];
    size_t size, written;
    const uint8_t mode = 2;
    size = record(PLTR_OPEN, 1, &mode, 1, input, sizeof(input));
    assert(feed(&wire, input, 1, 101, output, sizeof(output), &written) == 0);
    assert(feed(&wire, input + 1, size - 1, 102,
                output, sizeof(output), &written) == 1);
    assert(wire.stage == PLTR_PAIR_WIRE_START && written == 0);
    size = record(PLTR_PAIR_START, 2, start, sizeof(start),
                   input, sizeof(input));
    assert(feed(&wire, input, size, 103, output, sizeof(output), &written) == 1);
    assert(wire.stage == PLTR_PAIR_WIRE_KEYS &&
           pltr_identity_store_approve(&store, client_key) == 0);
    for (uint8_t key = 1; key < 5; ++key)
        assert(pltr_pair_wire_key(&wire, key, 110 + key,
                                  output, sizeof(output), &written) == 0);
    assert(pltr_pair_wire_key(&wire, 5, 115,
                              output, sizeof(output), &written) == 1);
    PltrFrame response;
    assert(pltr_decode_record(output, written, PLTR_RELAY_TO_CLIENT,
                              PLTR_PRE_AUTH, 1, &response) == 0);
    assert(response.type == PLTR_PAIR_RESPONSE);
    assert(pltr_cpace_finish(&client, response.payload,
                             response.payload + 32,
                             response.payload_size - 32, material) == 0);
    uint8_t tag[32];
    assert(pltr_pair_confirmation_tag(material, PLTR_CPACE_INITIATOR,
                                      sid, share, client_ad, sizeof(client_ad),
                                      response.payload, response.payload + 32,
                                      response.payload_size - 32, tag) == 0);
    size = record(PLTR_PAIR_CONFIRM, 3, tag, sizeof(tag),
                   input, sizeof(input));
    assert(feed(&wire, input, size, 200,
                output, sizeof(output), &written) == 1);
    PltrFrame result;
    assert(pltr_decode_record(output, written, PLTR_RELAY_TO_CLIENT,
                              PLTR_PRE_AUTH, 2, &result) == 0);
    assert(result.type == PLTR_PAIR_RESULT && result.payload_size == 33 &&
           result.payload[0] == 0);
    assert(pltr_identity_store_approve(&store, client_key) == 1);
    pltr_pair_wire_close(&wire, 201);
    assert(pairing.failures == 0);
    pltr_cpace_clear(&client);

    // A disconnected attempt consumes its window and counts toward lockout.
    assert(pltr_pairing_open(&pairing, 300, 0) == 0);
    assert(pltr_pair_wire_init(&wire, &pairing, 2) == 0);
    size = record(PLTR_OPEN, 1, &mode, 1, input, sizeof(input));
    assert(feed(&wire, input, size, 301,
                output, sizeof(output), &written) == 1);
    uint8_t another_key[32] = {1};
    memcpy(start + 48, another_key, 32);
    size = record(PLTR_PAIR_START, 2, start, sizeof(start),
                   input, sizeof(input));
    assert(feed(&wire, input, size, 302,
                output, sizeof(output), &written) == 1);
    pltr_pair_wire_close(&wire, 303);
    assert(pairing.failures == 1 && pairing.stage == PLTR_PAIR_CLOSED);

    pltr_pairing_clear(&pairing);
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
