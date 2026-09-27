#ifndef PLANK_RELAY_CLIENT_PAIR_H
#define PLANK_RELAY_CLIENT_PAIR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PltrClientPair PltrClientPair;

// The Client owns and stores its static private key in the platform Keychain.
// The five digits are shown to the user as tablet ExpressKey numbers 1..8.
PltrClientPair *pltr_client_pair_create(const uint8_t private_key[32],
                                        const uint8_t code[5],
                                        const uint8_t *name, size_t name_size,
                                        uint8_t link_type);
// Physical-approval BLE lab only: explicit OPEN mode 3, no secret challenge.
PltrClientPair *pltr_client_pair_create_button(const uint8_t private_key[32],
    const uint8_t *name, size_t name_size);
int pltr_client_pair_approval_status(const PltrClientPair *pair, uint8_t out[8]);
void pltr_client_pair_destroy(PltrClientPair *pair);
int pltr_client_pair_start(PltrClientPair *pair, uint8_t *out,
                           size_t capacity, size_t *written);

// Return 0 for an incomplete record, 1 for a handled record, 2 only after
// verifying the Relay's confirmation tag, 3 for approval status, -1 for failure.
// In button mode the tag confirms the exchange, not an authenticated identity.
// A response to
// write, if any, is copied to reply. relay_public_key is filled only on 2;
// store it in the Keychain then, never on PAIR_RESPONSE alone.
int pltr_client_pair_receive(PltrClientPair *pair, const uint8_t *bytes,
                             size_t size, size_t *consumed,
                             uint8_t *reply, size_t reply_capacity,
                             size_t *reply_size,
                             uint8_t relay_public_key[32]);

#ifdef __cplusplus
}
#endif
#endif
