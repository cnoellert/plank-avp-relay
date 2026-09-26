#include "session.h"

void pltr_relay_session_init(PltrRelaySession *session,
                             uint32_t first_client_sequence) {
    if (session == NULL) return;
    session->expected_sequence = first_client_sequence;
    session->active = 0;
    session->stage = first_client_sequence ? PLTR_RELAY_WAIT_HELLO : PLTR_RELAY_BROKEN;
}

int pltr_relay_session_accept(PltrRelaySession *session, const uint8_t *bytes,
                              size_t size, PltrFrame *out) {
    if (session == NULL || out == NULL ||
        session->stage == PLTR_RELAY_BROKEN ||
        session->stage == PLTR_RELAY_ENDED) return -1;
    if (pltr_decode_frame(bytes, size, PLTR_CLIENT_TO_RELAY, PLTR_SECURE,
                          session->expected_sequence, out) != 0) {
        session->stage = PLTR_RELAY_BROKEN;
        return -1;
    }
    switch (session->stage) {
    case PLTR_RELAY_WAIT_HELLO:
        if (out->type != PLTR_HELLO) goto invalid;
        session->stage = PLTR_RELAY_WAIT_READY;
        break;
    case PLTR_RELAY_WAIT_READY:
        if (out->type == PLTR_SESSION_READY) {
            session->active = out->payload[4];
            session->stage = PLTR_RELAY_READY;
        } else if (out->type != PLTR_PING && out->type != PLTR_PONG &&
                   out->type != PLTR_GOODBYE &&
                   out->type != PLTR_SESSION_END) goto invalid;
        break;
    case PLTR_RELAY_READY:
        if (out->type == PLTR_SESSION_ACTIVE) {
            session->active = out->payload[0];
        } else if (out->type == PLTR_RECONNECT_BEGIN) {
            session->active = 0;
            session->stage = PLTR_RELAY_RECONNECTING;
        } else if (out->type != PLTR_HOST_FRAME && out->type != PLTR_SESSION_END &&
                   out->type != PLTR_PING && out->type != PLTR_PONG &&
                   out->type != PLTR_GOODBYE) goto invalid;
        break;
    case PLTR_RELAY_RECONNECTING:
        if (out->type == PLTR_RECONNECT_FINISH) {
            session->stage = PLTR_RELAY_READY;
        } else if (out->type != PLTR_SESSION_END && out->type != PLTR_PING &&
                   out->type != PLTR_PONG && out->type != PLTR_GOODBYE) goto invalid;
        break;
    default:
        goto invalid;
    }
    if (out->type == PLTR_SESSION_END || out->type == PLTR_GOODBYE) {
        session->active = 0;
        session->stage = PLTR_RELAY_ENDED;
    }
    if (session->expected_sequence == UINT32_MAX - 1) {
        session->stage = PLTR_RELAY_ENDED;
    } else {
        ++session->expected_sequence;
    }
    return 0;
invalid:
    session->stage = PLTR_RELAY_BROKEN;
    session->active = 0;
    return -1;
}
