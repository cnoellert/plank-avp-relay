#include "protocol.h"

static uint16_t read_le16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t read_le32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static int allowed_type(uint16_t type, PltrDirection direction, PltrPhase phase) {
    if (phase == PLTR_PRE_AUTH) {
        if (type == 17) return 1; // NOISE
        if (direction == PLTR_CLIENT_TO_RELAY) {
            return type == 16 || type == 32 || type == 34; // OPEN, PAIR_START, PAIR_CONFIRM
        }
        if (direction == PLTR_RELAY_TO_CLIENT) {
            return type == 33 || type == 35; // PAIR_RESPONSE, PAIR_RESULT
        }
        return 0;
    }
    if (phase != PLTR_SECURE) return 0;
    if (type == 1 || type == 10 || type == 11 || type == 12) {
        return 1; // HELLO, PING, PONG, GOODBYE
    }
    if (direction == PLTR_CLIENT_TO_RELAY) {
        return type >= 2 && type <= 7; // SESSION_*; RECONNECT_*; HOST_FRAME
    }
    if (direction == PLTR_RELAY_TO_CLIENT) {
        return type == 8 || type == 9; // CLIENT_FRAME, STATUS
    }
    return 0;
}

int pltr_decode_frame(const uint8_t *bytes, size_t size,
                      PltrDirection direction, PltrPhase phase,
                      uint32_t expected_sequence, PltrFrame *out) {
    if (bytes == NULL || out == NULL || size < PLTR_HEADER_SIZE ||
            size > PLTR_MAX_FRAME_SIZE || expected_sequence == 0 ||
            expected_sequence == UINT32_MAX ||
            read_le32(bytes) != PLTR_MAGIC ||
            read_le16(bytes + 4) != PLTR_VERSION ||
            read_le32(bytes + 8) != expected_sequence) {
        return -1;
    }
    const uint16_t type = read_le16(bytes + 6);
    const uint32_t payload_size = read_le32(bytes + 12);
    if (!allowed_type(type, direction, phase) ||
            payload_size != size - PLTR_HEADER_SIZE) {
        return -1;
    }
    out->type = type;
    out->sequence = expected_sequence;
    out->payload = bytes + PLTR_HEADER_SIZE;
    out->payload_size = payload_size;
    return 0;
}

int pltr_decode_record(const uint8_t *bytes, size_t size,
                       PltrDirection direction, PltrPhase phase,
                       uint32_t expected_sequence, PltrFrame *out) {
    if (phase != PLTR_PRE_AUTH || bytes == NULL || size < 2 ||
            size > PLTR_MAX_FRAME_SIZE + 2 ||
            read_le16(bytes) != size - 2) {
        return -1;
    }
    return pltr_decode_frame(bytes + 2, size - 2, direction,
                             phase, expected_sequence, out);
}
