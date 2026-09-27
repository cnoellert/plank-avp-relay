#ifndef PLANK_RELAY_CLIENT_LINK_H
#define PLANK_RELAY_CLIENT_LINK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PltrClientLink PltrClientLink;

// The Client private key and pinned Relay public key must come from the
// platform's protected store after a confirmed pairing. No trust-on-connect.
PltrClientLink *pltr_client_link_create(const uint8_t client_private_key[32],
                                        const uint8_t relay_public_key[32],
                                        uint8_t link_type);
void pltr_client_link_destroy(PltrClientLink *client);

int pltr_client_link_start(PltrClientLink *client, uint8_t *out,
                           size_t capacity, size_t *written);

// Consume at most one length-prefixed record from a byte stream. Return 0
// for an incomplete record, 1 for a handled record, or -1 to close the link.
// Handshake replies are copied to reply; type is zero for handshake records.
// Payloads are copied before the internal receive buffer can be reused.
int pltr_client_link_receive(PltrClientLink *client, const uint8_t *bytes,
                             size_t size, size_t *consumed,
                             uint8_t *reply, size_t reply_capacity,
                             size_t *reply_size, uint16_t *type,
                             uint8_t *payload, size_t payload_capacity,
                             size_t *payload_size);

int pltr_client_link_send(PltrClientLink *client, uint16_t type,
                          const uint8_t *payload, size_t payload_size,
                          uint8_t *out, size_t capacity, size_t *written);

// Software version from the authenticated peer HELLO, or NULL until ready.
// The returned pointer remains valid until the Client link is destroyed.
const char *pltr_client_link_peer_version(const PltrClientLink *client);

#ifdef __cplusplus
}
#endif
#endif
