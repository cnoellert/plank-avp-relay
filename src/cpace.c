#include "cpace.h"

#include <sodium.h>
#include <string.h>

static const uint8_t dsi[] = "CPaceRistretto255";
static const uint8_t dsi_isk[] = "CPaceRistretto255_ISK";
static const uint8_t ci_prefix[] = "plank-tablet-relay/1";

static int append_lv(uint8_t *buffer, size_t capacity, size_t *used,
                     const uint8_t *value, size_t size) {
    if ((value == NULL && size != 0) || size > 16383) return -1;
    size_t prefix = size < 128 ? 1 : 2;
    if (*used > capacity || prefix > capacity - *used ||
        size > capacity - *used - prefix) return -1;
    if (prefix == 1) {
        buffer[(*used)++] = (uint8_t)size;
    } else {
        buffer[(*used)++] = (uint8_t)((size & 0x7f) | 0x80);
        buffer[(*used)++] = (uint8_t)(size >> 7);
    }
    if (size) memcpy(buffer + *used, value, size);
    *used += size;
    return 0;
}

static int derive_generator(const uint8_t *prs, size_t prs_size,
                            const uint8_t *ci, size_t ci_size,
                            const uint8_t sid[16], uint8_t generator[32]) {
    uint8_t buffer[512] = {0}, digest[64];
    size_t used = 0;
    const size_t dsi_size = sizeof(dsi) - 1;
    const size_t dsi_field = 1 + dsi_size;
    const size_t prs_field = (prs_size < 128 ? 1 : 2) + prs_size;
    const size_t padding = dsi_field + prs_field + 1 < 128 ?
                           128 - dsi_field - prs_field - 1 : 0;
    uint8_t zeros[128] = {0};
    int result = append_lv(buffer, sizeof(buffer), &used, dsi, dsi_size) ||
                 append_lv(buffer, sizeof(buffer), &used, prs, prs_size) ||
                 append_lv(buffer, sizeof(buffer), &used, zeros, padding) ||
                 append_lv(buffer, sizeof(buffer), &used, ci, ci_size) ||
                 append_lv(buffer, sizeof(buffer), &used, sid, 16);
    if (result == 0) {
        crypto_hash_sha512(digest, buffer, used);
        result = crypto_core_ristretto255_from_hash(generator, digest);
    }
    sodium_memzero(buffer, sizeof(buffer));
    sodium_memzero(digest, sizeof(digest));
    return result ? -1 : 0;
}

static int start_core(PltrCpace *state, PltrCpaceRole role,
                      const uint8_t *prs, size_t prs_size,
                      const uint8_t *ci, size_t ci_size,
                      const uint8_t sid[16], const uint8_t *ad, size_t ad_size,
                      const uint8_t test_scalar[32],
                      uint8_t share[32], uint8_t *test_generator) {
    if (state) pltr_cpace_clear(state);
    if (share) sodium_memzero(share, 32);
    if (state == NULL || prs == NULL || ci == NULL || sid == NULL ||
        share == NULL || (ad == NULL && ad_size != 0) ||
        (role != PLTR_CPACE_INITIATOR && role != PLTR_CPACE_RESPONDER) ||
        prs_size == 0 || prs_size > 256 || ci_size == 0 || ci_size > 128 ||
        ad_size > PLTR_CPACE_MAX_AD_SIZE || sodium_init() < 0) return -1;
    uint8_t generator[32];
    if (derive_generator(prs, prs_size, ci, ci_size, sid, generator) != 0) {
        pltr_cpace_clear(state); return -1;
    }
    if (test_generator) memcpy(test_generator, generator, 32);
    if (test_scalar) memcpy(state->scalar, test_scalar, 32);
    else crypto_core_ristretto255_scalar_random(state->scalar);
    if (crypto_scalarmult_ristretto255(state->share,
                                       state->scalar, generator) != 0) {
        sodium_memzero(generator, sizeof(generator));
        pltr_cpace_clear(state); return -1;
    }
    sodium_memzero(generator, sizeof(generator));
    memcpy(state->sid, sid, 16);
    if (ad_size) memcpy(state->ad, ad, ad_size);
    state->ad_size = ad_size;
    state->role = role;
    state->ready = 1;
    memcpy(share, state->share, 32);
    return 0;
}

int pltr_cpace_start(PltrCpace *state, PltrCpaceRole role,
                      const uint8_t code[5], uint8_t link_type,
                      const uint8_t sid[16], const uint8_t *ad, size_t ad_size,
                      uint8_t share[32]) {
    if (code == NULL || (link_type != 1 && link_type != 2)) {
        if (state) pltr_cpace_clear(state);
        return -1;
    }
    for (size_t i = 0; i < 5; ++i) {
        if (code[i] < '1' || code[i] > '8') {
            if (state) pltr_cpace_clear(state);
            return -1;
        }
    }
    uint8_t ci[sizeof(ci_prefix)];
    memcpy(ci, ci_prefix, sizeof(ci_prefix) - 1);
    ci[sizeof(ci_prefix) - 1] = link_type;
    return start_core(state, role, code, 5, ci, sizeof(ci), sid,
                      ad, ad_size, NULL, share, NULL);
}

#ifdef PLTR_CPACE_TESTING
int pltr_cpace_start_test(PltrCpace *state, PltrCpaceRole role,
                           const uint8_t *prs, size_t prs_size,
                           const uint8_t *ci, size_t ci_size,
                           const uint8_t sid[16], const uint8_t *ad,
                           size_t ad_size, const uint8_t scalar[32],
                           uint8_t share[32], uint8_t generator[32]) {
    return start_core(state, role, prs, prs_size, ci, ci_size, sid,
                      ad, ad_size, scalar, share, generator);
}
#endif

int pltr_cpace_finish(PltrCpace *state, const uint8_t peer_share[32],
                       const uint8_t *peer_ad, size_t peer_ad_size,
                       uint8_t intermediate_key[64]) {
    if (intermediate_key) sodium_memzero(intermediate_key, 64);
    if (state == NULL || !state->ready) return -1;
    if (peer_share == NULL ||
        intermediate_key == NULL ||
        (peer_ad == NULL && peer_ad_size != 0) ||
        peer_ad_size > PLTR_CPACE_MAX_AD_SIZE) {
        pltr_cpace_clear(state);
        return -1;
    }
    uint8_t shared[32], transcript[512];
    size_t used = 0;
    if (!crypto_core_ristretto255_is_valid_point(peer_share) ||
        crypto_scalarmult_ristretto255(shared, state->scalar, peer_share) != 0 ||
        !crypto_core_ristretto255_is_valid_point(shared) ||
        append_lv(transcript, sizeof(transcript), &used,
                  dsi_isk, sizeof(dsi_isk) - 1) != 0 ||
        append_lv(transcript, sizeof(transcript), &used,
                  state->sid, 16) != 0 ||
        append_lv(transcript, sizeof(transcript), &used,
                  shared, 32) != 0) {
        sodium_memzero(shared, sizeof(shared));
        pltr_cpace_clear(state); return -1;
    }
    const uint8_t *ya = state->role == PLTR_CPACE_INITIATOR ? state->share : peer_share;
    const uint8_t *yb = state->role == PLTR_CPACE_RESPONDER ? state->share : peer_share;
    const uint8_t *ada = state->role == PLTR_CPACE_INITIATOR ? state->ad : peer_ad;
    const uint8_t *adb = state->role == PLTR_CPACE_RESPONDER ? state->ad : peer_ad;
    const size_t ada_size = state->role == PLTR_CPACE_INITIATOR ?
                            state->ad_size : peer_ad_size;
    const size_t adb_size = state->role == PLTR_CPACE_RESPONDER ?
                            state->ad_size : peer_ad_size;
    int result = append_lv(transcript, sizeof(transcript), &used, ya, 32) ||
                 append_lv(transcript, sizeof(transcript), &used, ada, ada_size) ||
                 append_lv(transcript, sizeof(transcript), &used, yb, 32) ||
                 append_lv(transcript, sizeof(transcript), &used, adb, adb_size);
    if (result == 0) crypto_hash_sha512(intermediate_key, transcript, used);
    sodium_memzero(shared, sizeof(shared));
    sodium_memzero(transcript, sizeof(transcript));
    pltr_cpace_clear(state);
    return result ? -1 : 0;
}

void pltr_cpace_clear(PltrCpace *state) {
    if (state) sodium_memzero(state, sizeof(*state));
}
