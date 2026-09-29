#ifndef PLANK_RELAY_LINK_H
#define PLANK_RELAY_LINK_H

#include "noise.h"
#include "protocol.h"
#include "session.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum PltrLinkStage {
    PLTR_LINK_WAIT_OPEN = 1,
    PLTR_LINK_WAIT_FIRST = 2,
    PLTR_LINK_WAIT_SECOND = 3,
    PLTR_LINK_WAIT_HELLO = 4,
    PLTR_LINK_READY = 5,
    PLTR_LINK_CLOSED = 6,
    PLTR_LINK_FAILED = 7,
} PltrLinkStage;

// Return 1 only for a Client static public key found in the paired-client
// store. This check runs after decrypting Noise message one and before the
// Relay emits message two or any tablet data.
typedef int (*PltrApproveClient)(void *context, const uint8_t public_key[32]);

typedef struct PltrLink {
    PltrNoise noise;
    PltrRecordReader reader;
    PltrRelaySession relay_session;
    PltrApproveClient approve_client;
    void *approve_context;
    PltrNoiseRole role;
    PltrLinkStage stage;
    uint32_t incoming_sequence;
    uint32_t outgoing_sequence;
    uint32_t local_features, peer_features;
    int tablet_management;
    char peer_version[65];
    uint8_t plaintext[PLTR_MAX_FRAME_SIZE];
} PltrLink;

// The initiator must supply the Relay public key from an already confirmed
// pairing. The responder must supply an approved-client lookup callback.
int pltr_link_init(PltrLink *link, PltrNoiseRole role,
                   const uint8_t private_key[32],
                   const uint8_t relay_public_key[32],
                   PltrApproveClient approve_client, void *approve_context,
                   uint8_t link_type);
void pltr_link_clear(PltrLink *link);
// Opt in before sending/receiving any records. Default remains RAW_HID only.
int pltr_link_enable_input_observer(PltrLink *link);
// Explicit local opt-in, discovered through the BLE setup characteristics.
// Does not change HELLO feature bits, preserving older readings clients.
int pltr_link_enable_tablet_management(PltrLink *link);

// Initiator only. Returns OPEN and Noise message one as two complete records.
int pltr_link_start(PltrLink *link, uint8_t *out, size_t capacity,
                    size_t *written);

// Consume at most one complete record from a byte-stream chunk. A return of
// 0 means more input is needed, 1 means one record was handled, and -1 means
// the connection must close. The caller loops using consumed to process
// coalesced records. reply may contain one or two complete records. A secure
// application frame is returned in frame; its payload view is valid until the
// next receive call. Its type is zero for handshake records.
int pltr_link_receive(PltrLink *link, const uint8_t *bytes, size_t size,
                      size_t *consumed, uint8_t *reply, size_t reply_capacity,
                      size_t *reply_size, PltrFrame *frame);

// Send one encrypted application frame after both HELLO messages. The Relay
// may not send a tablet frame before SESSION_READY has been accepted.
int pltr_link_send(PltrLink *link, uint16_t type,
                   const uint8_t *payload, size_t payload_size,
                   uint8_t *out, size_t capacity, size_t *written);

#ifdef __cplusplus
}
#endif

#endif
