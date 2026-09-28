#include "pairing.h"
#include "confirm.h"
#include "protocol.h"

#include <string.h>
#include <sodium.h>

#define WINDOW_MS 120000u
#define ATTEMPT_MS 60000u
#define LOCKOUT_MS 600000u

static uint64_t deadline(uint64_t now, uint64_t delay) {
    return now > UINT64_MAX - delay ? UINT64_MAX : now + delay;
}

static void wipe_attempt(PltrPairing *pairing) {
    pltr_cpace_clear(&pairing->cpace);
    sodium_memzero(pairing->code, sizeof(pairing->code));
    sodium_memzero(pairing->sid, sizeof(pairing->sid));
    sodium_memzero(pairing->client_share, sizeof(pairing->client_share));
    sodium_memzero(pairing->relay_share, sizeof(pairing->relay_share));
    sodium_memzero(pairing->client_key, sizeof(pairing->client_key));
    sodium_memzero(pairing->client_ad, sizeof(pairing->client_ad));
    sodium_memzero(pairing->intermediate_key, sizeof(pairing->intermediate_key));
    pairing->code_count = 0;
    pairing->client_ad_size = 0;
    pairing->link_type = 0;
    pairing->deadline_ms = 0;
}

static void fail_attempt(PltrPairing *pairing, uint64_t now_ms) {
    wipe_attempt(pairing);
    if (++pairing->failures >= 3) {
        pairing->stage = PLTR_PAIR_LOCKED;
        pairing->lockout_until_ms = deadline(now_ms, LOCKOUT_MS);
    } else {
        pairing->stage = PLTR_PAIR_CLOSED;
    }
}

int pltr_pairing_init(PltrPairing *pairing, PltrIdentityStore *store,
                      const uint8_t *relay_name, size_t relay_name_size) {
    if (pairing == NULL || store == NULL || store->directory_fd < 0 ||
        relay_name == NULL || relay_name_size == 0 || relay_name_size > 64 ||
        sodium_init() < 0) return -1;
    // Reuse the common validator for the wire name and key metadata.
    uint8_t payload[65] = {0};
    payload[0] = (uint8_t)relay_name_size;
    memcpy(payload + 1, relay_name, relay_name_size);
    uint8_t frame[PLTR_MAX_FRAME_SIZE];
    size_t written;
    uint8_t response[64 + 65] = {0};
    memcpy(response + 32, store->public_key, 32);
    memcpy(response + 64, payload, relay_name_size + 1);
    if (pltr_encode_frame(PLTR_PAIR_RESPONSE, 1, response,
                          64 + relay_name_size + 1,
                          PLTR_RELAY_TO_CLIENT, PLTR_PRE_AUTH,
                          frame, sizeof(frame), &written) != 0) return -1;
    memset(pairing, 0, sizeof(*pairing));
    pairing->store = store;
    pairing->stage = PLTR_PAIR_CLOSED;
    memcpy(pairing->relay_ad, store->public_key, 32);
    memcpy(pairing->relay_ad + 32, payload, relay_name_size + 1);
    pairing->relay_ad_size = 32 + relay_name_size + 1;
    return 0;
}

void pltr_pairing_clear(PltrPairing *pairing) {
    if (pairing) sodium_memzero(pairing, sizeof(*pairing));
}

int pltr_pairing_open(PltrPairing *pairing, uint64_t now_ms,
                      int session_active) {
    if (pairing == NULL || pairing->store == NULL || session_active) return -1;
    if (pairing->stage == PLTR_PAIR_LOCKED) {
        if (now_ms < pairing->lockout_until_ms) return -1;
        pairing->failures = 0;
        pairing->lockout_until_ms = 0;
    } else if (pairing->stage != PLTR_PAIR_CLOSED) {
        return -1;
    }
    wipe_attempt(pairing);
    pairing->stage = PLTR_PAIR_WINDOW;
    pairing->deadline_ms = deadline(now_ms, WINDOW_MS);
    return 0;
}

int pltr_pairing_tick(PltrPairing *pairing, uint64_t now_ms) {
    if (pairing == NULL) return -1;
    if (pairing->stage == PLTR_PAIR_LOCKED &&
        now_ms >= pairing->lockout_until_ms) {
        pairing->failures = 0;
        pairing->stage = PLTR_PAIR_CLOSED;
        pairing->lockout_until_ms = 0;
    }
    if (pairing->stage == PLTR_PAIR_WINDOW &&
        now_ms >= pairing->deadline_ms) {
        wipe_attempt(pairing);
        pairing->stage = PLTR_PAIR_CLOSED;
        return 0;
    }
    if ((pairing->stage == PLTR_PAIR_WAIT_CODE ||
         pairing->stage == PLTR_PAIR_WAIT_CONFIRM) &&
        now_ms >= pairing->deadline_ms) {
        fail_attempt(pairing, now_ms);
        return 1;
    }
    return 0;
}

void pltr_pairing_abort(PltrPairing *pairing, uint64_t now_ms) {
    if (pairing == NULL) return;
    if (pairing->stage == PLTR_PAIR_WAIT_CODE ||
        pairing->stage == PLTR_PAIR_WAIT_CONFIRM)
        fail_attempt(pairing, now_ms);
}

int pltr_pairing_start(PltrPairing *pairing, const uint8_t *payload,
                       size_t payload_size, uint8_t link_type,
                       uint64_t now_ms) {
    if (pairing == NULL || pairing->stage != PLTR_PAIR_WINDOW ||
        pltr_pairing_tick(pairing, now_ms) != 0 ||
        pairing->stage != PLTR_PAIR_WINDOW ||
        payload == NULL || payload_size < 81 || payload_size > 145 ||
        (link_type != 1 && link_type != 2)) return -1;
    uint8_t frame[PLTR_MAX_FRAME_SIZE];
    size_t written;
    if (pltr_encode_frame(PLTR_PAIR_START, 1, payload, payload_size,
                          PLTR_CLIENT_TO_RELAY, PLTR_PRE_AUTH,
                          frame, sizeof(frame), &written) != 0) {
        fail_attempt(pairing, now_ms);
        return -1;
    }
    memcpy(pairing->sid, payload, 16);
    memcpy(pairing->client_share, payload + 16, 32);
    memcpy(pairing->client_key, payload + 48, 32);
    pairing->client_ad_size = payload_size - 48;
    memcpy(pairing->client_ad, payload + 48, pairing->client_ad_size);
    pairing->link_type = link_type;
    pairing->stage = PLTR_PAIR_WAIT_CODE;
    pairing->deadline_ms = deadline(now_ms, ATTEMPT_MS);
    return 0;
}

int pltr_pairing_key(PltrPairing *pairing, uint8_t key,
                     uint64_t now_ms, uint8_t *response,
                     size_t capacity, size_t *response_size) {
    if (pairing == NULL || response == NULL || response_size == NULL ||
        key < 1 || key > 8) return -1;
    *response_size = 0;
    if (pltr_pairing_tick(pairing, now_ms) != 0 ||
        pairing->stage != PLTR_PAIR_WAIT_CODE) return -1;
    pairing->code[pairing->code_count++] = (uint8_t)('0' + key);
    if (pairing->code_count < 5) return 0;
    if (capacity < 64 + pairing->relay_ad_size - 32 ||
        pltr_cpace_start(&pairing->cpace, PLTR_CPACE_RESPONDER,
                          pairing->code, pairing->link_type,
                          pairing->sid, pairing->relay_ad,
                          pairing->relay_ad_size,
                          pairing->relay_share) != 0 ||
        pltr_cpace_finish(&pairing->cpace, pairing->client_share,
                           pairing->client_ad, pairing->client_ad_size,
                           pairing->intermediate_key) != 0) {
        fail_attempt(pairing, now_ms);
        return -1;
    }
    memcpy(response, pairing->relay_share, 32);
    memcpy(response + 32, pairing->relay_ad, pairing->relay_ad_size);
    *response_size = 32 + pairing->relay_ad_size;
    sodium_memzero(pairing->code, sizeof(pairing->code));
    pairing->stage = PLTR_PAIR_WAIT_CONFIRM;
    return 1;
}

int pltr_pairing_confirm(PltrPairing *pairing, const uint8_t tag[32],
                         uint64_t now_ms, uint8_t result[33],
                         size_t *result_size) {
    if (pairing == NULL || tag == NULL || result == NULL ||
        result_size == NULL ||
        pltr_pairing_tick(pairing, now_ms) != 0 ||
        pairing->stage != PLTR_PAIR_WAIT_CONFIRM) return -1;
    if (pltr_pair_confirmation_verify(pairing->intermediate_key,
                                      PLTR_CPACE_INITIATOR,
                                      pairing->sid,
                                      pairing->client_share,
                                      pairing->client_ad, pairing->client_ad_size,
                                      pairing->relay_share,
                                      pairing->relay_ad, pairing->relay_ad_size,
                                      tag) != 0) {
        result[0] = 1;
        *result_size = 1;
        fail_attempt(pairing, now_ms);
        return 1;
    }
    uint8_t relay_tag[32];
    if (pltr_pair_confirmation_tag(pairing->intermediate_key,
                                   PLTR_CPACE_RESPONDER,
                                   pairing->sid,
                                   pairing->client_share,
                                   pairing->client_ad, pairing->client_ad_size,
                                   pairing->relay_share,
                                   pairing->relay_ad, pairing->relay_ad_size,
                                   relay_tag) != 0 ||
        // Re-approval still requires the entire local approval and fresh
        // confirmation exchange. Keep the existing allowlist entry intact.
        (!pltr_identity_store_approve(pairing->store, pairing->client_key) &&
         pltr_identity_store_add(pairing->store, pairing->client_key) != 0)) {
        sodium_memzero(relay_tag, sizeof(relay_tag));
        fail_attempt(pairing, now_ms);
        return -1;
    }
    result[0] = 0;
    memcpy(result + 1, relay_tag, 32);
    sodium_memzero(relay_tag, sizeof(relay_tag));
    *result_size = 33;
    wipe_attempt(pairing);
    pairing->failures = 0;
    pairing->stage = PLTR_PAIR_CLOSED;
    return 1;
}
