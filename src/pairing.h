#ifndef PLANK_RELAY_PAIRING_H
#define PLANK_RELAY_PAIRING_H

#include "cpace.h"
#include "identity.h"

typedef enum PltrPairStage {
    PLTR_PAIR_CLOSED = 1,
    PLTR_PAIR_WINDOW = 2,
    PLTR_PAIR_WAIT_CODE = 3,
    PLTR_PAIR_WAIT_CONFIRM = 4,
    PLTR_PAIR_LOCKED = 5,
} PltrPairStage;

typedef struct PltrPairing {
    PltrIdentityStore *store;
    PltrCpace cpace;
    PltrPairStage stage;
    uint64_t deadline_ms, lockout_until_ms;
    unsigned failures, code_count;
    uint8_t link_type;
    uint8_t code[5], sid[16], client_share[32], relay_share[32];
    uint8_t client_key[32], client_ad[97], relay_ad[97];
    size_t client_ad_size, relay_ad_size;
    uint8_t intermediate_key[64];
} PltrPairing;

// Time is monotonic milliseconds supplied by the daemon. Physical/CLI code
// entry must call open only while no session is active. One attempt consumes
// the window. The caller sends PAIR_RESULT(2) on a timeout return of 1.
int pltr_pairing_init(PltrPairing *pairing, PltrIdentityStore *store,
                      const uint8_t *relay_name, size_t relay_name_size);
void pltr_pairing_clear(PltrPairing *pairing);
int pltr_pairing_open(PltrPairing *pairing, uint64_t now_ms,
                      int session_active);
int pltr_pairing_tick(PltrPairing *pairing, uint64_t now_ms);
// PAIR_START payload has already passed the common PLTR frame validator.
int pltr_pairing_start(PltrPairing *pairing, const uint8_t *payload,
                       size_t payload_size, uint8_t link_type,
                       uint64_t now_ms);
// Called once per ExpressKey down. On the fifth digit, return 1 and fill the
// exact PAIR_RESPONSE payload; 0 means more digits are needed, -1 closes.
int pltr_pairing_key(PltrPairing *pairing, uint8_t key,
                     uint64_t now_ms, uint8_t *response,
                     size_t capacity, size_t *response_size);
// On a wrong tag, return 1 with PAIR_RESULT(1). On success, return 1 with
// PAIR_RESULT(0, relay tag) and persist the Client key. -1 closes the attempt.
int pltr_pairing_confirm(PltrPairing *pairing, const uint8_t tag[32],
                         uint64_t now_ms, uint8_t result[33],
                         size_t *result_size);

#endif
