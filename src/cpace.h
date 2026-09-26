#ifndef PLANK_RELAY_CPACE_H
#define PLANK_RELAY_CPACE_H

#include <stddef.h>
#include <stdint.h>

#define PLTR_CPACE_SHARE_SIZE 32u
#define PLTR_CPACE_KEY_SIZE 64u
#define PLTR_CPACE_SID_SIZE 16u
#define PLTR_CPACE_MAX_AD_SIZE 128u

typedef enum PltrCpaceRole {
    PLTR_CPACE_INITIATOR = 1,
    PLTR_CPACE_RESPONDER = 2,
} PltrCpaceRole;

typedef struct PltrCpace {
    uint8_t scalar[32], share[32], sid[16], ad[PLTR_CPACE_MAX_AD_SIZE];
    size_t ad_size;
    PltrCpaceRole role;
    unsigned ready;
} PltrCpace;

// Draft-irtf-cfrg-cpace-21, CPACE-RISTR255-SHA512. The code is five
// ExpressKey digits in '1'..'8'. link_type is 1 for BLE or 2 for TCP.
int pltr_cpace_start(PltrCpace *state, PltrCpaceRole role,
                      const uint8_t code[5], uint8_t link_type,
                      const uint8_t sid[16], const uint8_t *ad, size_t ad_size,
                      uint8_t share[32]);
int pltr_cpace_finish(PltrCpace *state, const uint8_t peer_share[32],
                       const uint8_t *peer_ad, size_t peer_ad_size,
                       uint8_t intermediate_key[64]);
void pltr_cpace_clear(PltrCpace *state);

#ifdef PLTR_CPACE_TESTING
int pltr_cpace_start_test(PltrCpace *state, PltrCpaceRole role,
                           const uint8_t *prs, size_t prs_size,
                           const uint8_t *ci, size_t ci_size,
                           const uint8_t sid[16], const uint8_t *ad,
                           size_t ad_size, const uint8_t scalar[32],
                           uint8_t share[32], uint8_t generator[32]);
#endif

#endif
