#include "confirm.h"

#include <sodium.h>
#include <string.h>

static const uint8_t salt_label[] = "PLANK-TABLET-RELAY/1 pairing confirmation";
static const uint8_t client_label[] = "PLANK-TABLET-RELAY/1 client confirmation";
static const uint8_t relay_label[] = "PLANK-TABLET-RELAY/1 relay confirmation";

static int append_lv(uint8_t *out, size_t capacity, size_t *used,
                     const uint8_t *value, size_t size) {
    const size_t prefix = size < 128 ? 1 : 2;
    if ((value == NULL && size != 0) || size > 16383 ||
        *used > capacity || prefix > capacity - *used ||
        size > capacity - *used - prefix) return -1;
    if (prefix == 1) {
        out[(*used)++] = (uint8_t)size;
    } else {
        out[(*used)++] = (uint8_t)((size & 0x7f) | 0x80);
        out[(*used)++] = (uint8_t)(size >> 7);
    }
    if (size) memcpy(out + *used, value, size);
    *used += size;
    return 0;
}

int pltr_pair_confirmation_tag(const uint8_t intermediate_key[64],
                                PltrCpaceRole signer,
                                const uint8_t sid[16],
                                const uint8_t client_share[32],
                                const uint8_t *client_ad, size_t client_ad_size,
                                const uint8_t relay_share[32],
                                const uint8_t *relay_ad, size_t relay_ad_size,
                                uint8_t tag[32]) {
    if (intermediate_key == NULL || sid == NULL || client_share == NULL ||
        relay_share == NULL || tag == NULL ||
        (client_ad == NULL && client_ad_size != 0) ||
        (relay_ad == NULL && relay_ad_size != 0) ||
        client_ad_size > PLTR_CPACE_MAX_AD_SIZE ||
        relay_ad_size > PLTR_CPACE_MAX_AD_SIZE ||
        (signer != PLTR_CPACE_INITIATOR && signer != PLTR_CPACE_RESPONDER) ||
        sodium_init() < 0) return -1;
    uint8_t transcript[343], salt[32], prk[32], key[32];
    size_t used = 0;
    if (append_lv(transcript, sizeof(transcript), &used, sid, 16) != 0 ||
        append_lv(transcript, sizeof(transcript), &used, client_share, 32) != 0 ||
        append_lv(transcript, sizeof(transcript), &used, client_ad, client_ad_size) != 0 ||
        append_lv(transcript, sizeof(transcript), &used, relay_share, 32) != 0 ||
        append_lv(transcript, sizeof(transcript), &used, relay_ad, relay_ad_size) != 0) {
        sodium_memzero(transcript, sizeof(transcript));
        return -1;
    }
    crypto_hash_sha256(salt, salt_label, sizeof(salt_label) - 1);
    crypto_auth_hmacsha256(prk, intermediate_key, 64, salt);
    const uint8_t *label = signer == PLTR_CPACE_INITIATOR ? client_label : relay_label;
    size_t label_size = signer == PLTR_CPACE_INITIATOR ?
                        sizeof(client_label) - 1 : sizeof(relay_label) - 1;
    uint8_t info[64];
    memcpy(info, label, label_size);
    info[label_size] = 1; // HKDF-Expand block index.
    crypto_auth_hmacsha256(key, info, label_size + 1, prk);
    crypto_auth_hmacsha256(tag, transcript, used, key);
    sodium_memzero(transcript, sizeof(transcript));
    sodium_memzero(salt, sizeof(salt));
    sodium_memzero(prk, sizeof(prk));
    sodium_memzero(key, sizeof(key));
    sodium_memzero(info, sizeof(info));
    return 0;
}

int pltr_pair_confirmation_verify(const uint8_t intermediate_key[64],
                                   PltrCpaceRole signer,
                                   const uint8_t sid[16],
                                   const uint8_t client_share[32],
                                   const uint8_t *client_ad, size_t client_ad_size,
                                   const uint8_t relay_share[32],
                                   const uint8_t *relay_ad, size_t relay_ad_size,
                                   const uint8_t tag[32]) {
    if (tag == NULL) return -1;
    uint8_t expected[32];
    if (pltr_pair_confirmation_tag(intermediate_key, signer, sid, client_share,
                                   client_ad, client_ad_size, relay_share,
                                   relay_ad, relay_ad_size, expected) != 0) return -1;
    int result = sodium_memcmp(expected, tag, 32);
    sodium_memzero(expected, sizeof(expected));
    return result == 0 ? 0 : -1;
}
