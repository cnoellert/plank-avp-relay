#include "noise.h"
#include "noise_vector.inc"

#include <assert.h>
#include <stdint.h>
#include <string.h>

static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static size_t hex(const char *source, uint8_t *out, size_t capacity) {
    size_t length = strlen(source);
    assert(length % 2 == 0 && length / 2 <= capacity);
    for (size_t i = 0; i < length / 2; ++i) {
        int high = nibble(source[2 * i]), low = nibble(source[2 * i + 1]);
        assert(high >= 0 && low >= 0);
        out[i] = (uint8_t)((high << 4) | low);
    }
    return length / 2;
}
static void equal_hex(const uint8_t *actual, size_t size, const char *expected) {
    uint8_t bytes[8192];
    size_t n = hex(expected, bytes, sizeof(bytes));
    assert(size == n && memcmp(actual, bytes, size) == 0);
}
int main(void) {
    uint8_t initiator_private[32], responder_private[32], responder_public[32];
    uint8_t initiator_ephemeral[32], responder_ephemeral[32], prologue[64];
    size_t prologue_size = hex(init_prologue, prologue, sizeof(prologue));
    hex(init_static, initiator_private, 32);
    hex(resp_static, responder_private, 32);
    hex(init_ephemeral, initiator_ephemeral, 32);
    hex(resp_ephemeral, responder_ephemeral, 32);
    hex(init_remote_static, responder_public, 32);
    uint8_t derived_public[32];
    assert(pltr_noise_public_key(responder_private, derived_public) == 0);
    assert(memcmp(derived_public, responder_public, 32) == 0);

    PltrNoise initiator, responder;
    assert(pltr_noise_init_test(&initiator, PLTR_NOISE_INITIATOR,
                                initiator_private, responder_public,
                                prologue, prologue_size) == 0);
    assert(pltr_noise_init_test(&responder, PLTR_NOISE_RESPONDER,
                                responder_private, NULL,
                                prologue, prologue_size) == 0);
    pltr_noise_set_ephemeral_test(&initiator, initiator_ephemeral);
    pltr_noise_set_ephemeral_test(&responder, responder_ephemeral);
    uint8_t plain[8192], wire[8192], received[8192], client_public[32];
    size_t plain_size = hex(payload_0, plain, sizeof(plain));
    size_t written = 0, read = 0;
    assert(pltr_noise_write_first(&initiator, plain, plain_size,
                                  wire, sizeof(wire), &written) == 0);
    equal_hex(wire, written, ciphertext_0);
    assert(pltr_noise_read_first(&responder, wire, written, client_public,
                                 received, sizeof(received), &read) == 0);
    assert(read == plain_size && memcmp(received, plain, read) == 0);
    assert(memcmp(client_public, initiator.static_public, 32) == 0);
    plain_size = hex(payload_1, plain, sizeof(plain));
    assert(pltr_noise_write_second(&responder, client_public, plain, plain_size,
                                   wire, sizeof(wire), &written) == 0);
    equal_hex(wire, written, ciphertext_1);
    assert(pltr_noise_read_second(&initiator, wire, written,
                                  received, sizeof(received), &read) == 0);
    assert(read == plain_size && memcmp(received, plain, read) == 0);
    assert(memcmp(initiator.handshake_hash, responder.handshake_hash, 64) == 0);
    equal_hex(initiator.handshake_hash, 64, handshake_hash);

    plain_size = hex(payload_2, plain, sizeof(plain));
    assert(pltr_noise_encrypt(&initiator, plain, plain_size,
                              wire, sizeof(wire), &written) == 0);
    equal_hex(wire, written, ciphertext_2);
    assert(pltr_noise_decrypt(&responder, wire, written,
                              received, sizeof(received), &read) == 0);
    assert(read == plain_size && memcmp(received, plain, read) == 0);
    plain_size = hex(payload_3, plain, sizeof(plain));
    assert(pltr_noise_encrypt(&responder, plain, plain_size,
                              wire, sizeof(wire), &written) == 0);
    equal_hex(wire, written, ciphertext_3);
    assert(pltr_noise_decrypt(&initiator, wire, written,
                              received, sizeof(received), &read) == 0);
    assert(read == plain_size && memcmp(received, plain, read) == 0);
    assert(pltr_noise_decrypt(&initiator, wire, written,
                              received, sizeof(received), &read) != 0);
    assert(pltr_noise_encrypt(&initiator, plain, plain_size,
                              wire, sizeof(wire), &written) != 0);
    pltr_noise_clear(&initiator);
    pltr_noise_clear(&responder);

    PltrNoise unknown;
    assert(pltr_noise_init_test(&unknown, PLTR_NOISE_RESPONDER,
                                responder_private, NULL,
                                prologue, prologue_size) == 0);
    written = hex(ciphertext_0, wire, sizeof(wire));
    assert(pltr_noise_read_first(&unknown, wire, written, client_public,
                                 received, sizeof(received), &read) == 0);
    uint8_t wrong_client[32] = {0};
    assert(pltr_noise_write_second(&unknown, wrong_client, plain, 0,
                                   wire, sizeof(wire), &written) != 0);
    assert(pltr_noise_write_second(&unknown, client_public, plain, 0,
                                   wire, sizeof(wire), &written) != 0);
    pltr_noise_clear(&unknown);

    PltrNoise tcp_initiator, ble_responder;
    assert(pltr_noise_init(&tcp_initiator, PLTR_NOISE_INITIATOR,
                           initiator_private, responder_public, 2) == 0);
    assert(pltr_noise_init(&ble_responder, PLTR_NOISE_RESPONDER,
                           responder_private, NULL, 1) == 0);
    assert(pltr_noise_write_first(&tcp_initiator, NULL, 0,
                                  wire, sizeof(wire), &written) == 0);
    assert(pltr_noise_read_first(&ble_responder, wire, written, client_public,
                                 received, sizeof(received), &read) != 0);
    pltr_noise_clear(&tcp_initiator);
    pltr_noise_clear(&ble_responder);

    PltrNoise live_a, live_b;
    assert(pltr_noise_init(&live_a, PLTR_NOISE_INITIATOR,
                           initiator_private, responder_public, 2) == 0);
    assert(pltr_noise_init(&live_b, PLTR_NOISE_RESPONDER,
                           responder_private, NULL, 2) == 0);
    assert(pltr_noise_write_second(&live_b, initiator.static_public,
                                   NULL, 0, wire, sizeof(wire), &written) != 0);
    assert(pltr_noise_write_first(&live_a, NULL, 0,
                                  wire, sizeof(wire), &written) == 0);
    assert(pltr_noise_read_first(&live_b, wire, written, client_public,
                                 received, sizeof(received), &read) == 0);
    assert(read == 0);
    assert(pltr_noise_write_second(&live_b, client_public, NULL, 0,
                                   wire, sizeof(wire), &written) == 0);
    assert(pltr_noise_read_second(&live_a, wire, written,
                                  received, sizeof(received), &read) == 0);
    assert(read == 0);
    const uint8_t sample[] = {'P', 'L', 'T', 'R'};
    assert(pltr_noise_encrypt(&live_a, sample, sizeof(sample),
                              wire, sizeof(wire), &written) == 0);
    assert(pltr_noise_decrypt(&live_b, wire, written,
                              received, sizeof(received), &read) == 0);
    assert(read == sizeof(sample) && memcmp(received, sample, read) == 0);
    pltr_noise_clear(&live_a);
    pltr_noise_clear(&live_b);
    return 0;
}
