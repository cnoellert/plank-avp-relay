#ifndef PLANK_RELAY_PROTOCOL_H
#define PLANK_RELAY_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define PLTR_MAGIC 0x504c5452u
#define PLTR_VERSION 1u
#define PLTR_HEADER_SIZE 16u
#define PLTR_MAX_PAYLOAD_SIZE 8192u
#define PLTR_MAX_FRAME_SIZE (PLTR_HEADER_SIZE + PLTR_MAX_PAYLOAD_SIZE)

typedef enum PltrDirection {
    PLTR_CLIENT_TO_RELAY = 1,
    PLTR_RELAY_TO_CLIENT = 2,
} PltrDirection;

typedef enum PltrPhase {
    PLTR_PRE_AUTH = 1,
    PLTR_SECURE = 2,
} PltrPhase;

typedef struct PltrFrame {
    uint16_t type;
    uint32_t sequence;
    const uint8_t *payload;
    uint32_t payload_size;
} PltrFrame;

// Decode a complete PLTR frame. The caller owns the buffer and must keep it
// alive while using the payload view. expected_sequence starts at 1.
int pltr_decode_frame(const uint8_t *bytes, size_t size,
                      PltrDirection direction, PltrPhase phase,
                      uint32_t expected_sequence, PltrFrame *out);

// Decode a complete length-prefixed plaintext record before the Noise
// handshake. For encrypted records, decrypt first and pass the resulting
// plaintext PLTR frame to pltr_decode_frame instead.
int pltr_decode_record(const uint8_t *bytes, size_t size,
                       PltrDirection direction, PltrPhase phase,
                       uint32_t expected_sequence, PltrFrame *out);

#endif
