#ifndef PLANK_RELAY_CONFIRM_H
#define PLANK_RELAY_CONFIRM_H

#include "cpace.h"

// Direction-specific confirmation tags over the ordered pairing transcript.
// The Client sends its tag in PAIR_CONFIRM; the Relay sends its tag only after
// validating the Client tag in PAIR_RESULT. No static key is persisted before
// both sides verify their expected peer tag.
int pltr_pair_confirmation_tag(const uint8_t intermediate_key[64],
                                PltrCpaceRole signer,
                                const uint8_t sid[16],
                                const uint8_t client_share[32],
                                const uint8_t *client_ad, size_t client_ad_size,
                                const uint8_t relay_share[32],
                                const uint8_t *relay_ad, size_t relay_ad_size,
                                uint8_t tag[32]);
int pltr_pair_confirmation_verify(const uint8_t intermediate_key[64],
                                   PltrCpaceRole signer,
                                   const uint8_t sid[16],
                                   const uint8_t client_share[32],
                                   const uint8_t *client_ad, size_t client_ad_size,
                                   const uint8_t relay_share[32],
                                   const uint8_t *relay_ad, size_t relay_ad_size,
                                   const uint8_t tag[32]);
#endif
