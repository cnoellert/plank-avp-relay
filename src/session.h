#ifndef PLANK_RELAY_SESSION_H
#define PLANK_RELAY_SESSION_H

#include "protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum PltrRelayStage {
    PLTR_RELAY_WAIT_HELLO = 1,
    PLTR_RELAY_WAIT_READY = 2,
    PLTR_RELAY_READY = 3,
    PLTR_RELAY_RECONNECTING = 4,
    PLTR_RELAY_ENDED = 5,
    PLTR_RELAY_BROKEN = 6,
} PltrRelayStage;

typedef struct PltrRelaySession {
    uint32_t expected_sequence;
    PltrRelayStage stage;
    uint8_t active;
} PltrRelaySession;

void pltr_relay_session_init(PltrRelaySession *session,
                             uint32_t first_client_sequence);
// Accepts one decrypted Client-to-Relay PLTR frame. On any protocol violation
// the session enters BROKEN and the link must close. out points into bytes.
int pltr_relay_session_accept(PltrRelaySession *session, const uint8_t *bytes,
                              size_t size, PltrFrame *out);

#ifdef __cplusplus
}
#endif

#endif
