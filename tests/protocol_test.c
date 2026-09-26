#include "protocol.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

static void write_le16(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
}

static void write_le32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
    bytes[2] = (uint8_t)(value >> 16);
    bytes[3] = (uint8_t)(value >> 24);
}

int main(void) {
    uint8_t record[2 + PLTR_HEADER_SIZE + 4] = {0};
    write_le16(record, PLTR_HEADER_SIZE + 4);
    uint8_t *frame = record + 2;
    write_le32(frame, PLTR_MAGIC);
    write_le16(frame + 4, PLTR_VERSION);
    write_le16(frame + 6, 16); // OPEN, Client to Relay, before authentication.
    write_le32(frame + 8, 1);
    write_le32(frame + 12, 4);
    PltrFrame decoded = {0};
    assert(pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 1, &decoded) == 0);
    assert(decoded.type == 16 && decoded.sequence == 1 &&
           decoded.payload == frame + PLTR_HEADER_SIZE && decoded.payload_size == 4);
    assert(pltr_decode_record(record, sizeof(record), PLTR_RELAY_TO_CLIENT,
                              PLTR_PRE_AUTH, 1, &decoded) != 0);
    assert(pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                              PLTR_SECURE, 1, &decoded) != 0);
    assert(pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 2, &decoded) != 0);
    assert(pltr_decode_record(record, sizeof(record) - 1, PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 1, &decoded) != 0);

    write_le16(record, PLTR_HEADER_SIZE + 5);
    assert(pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 1, &decoded) != 0);
    write_le16(record, PLTR_HEADER_SIZE + 4);
    write_le32(frame + 12, 5);
    assert(pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 1, &decoded) != 0);
    write_le32(frame + 12, 4);
    write_le16(frame + 4, 2);
    assert(pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 1, &decoded) != 0);
    write_le16(frame + 4, PLTR_VERSION);
    frame[0] = 0;
    assert(pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 1, &decoded) != 0);
    frame[0] = 'R';

    write_le16(frame + 6, 8); // CLIENT_FRAME, Relay to Client after auth.
    assert(pltr_decode_frame(frame, sizeof(record) - 2, PLTR_RELAY_TO_CLIENT,
                             PLTR_SECURE, 1, &decoded) == 0);
    assert(pltr_decode_frame(frame, sizeof(record) - 2, PLTR_CLIENT_TO_RELAY,
                             PLTR_SECURE, 1, &decoded) != 0);
    assert(pltr_decode_record(record, sizeof(record), PLTR_RELAY_TO_CLIENT,
                              PLTR_PRE_AUTH, 1, &decoded) != 0);
    assert(pltr_decode_record(record, sizeof(record), PLTR_RELAY_TO_CLIENT,
                              PLTR_SECURE, 1, &decoded) != 0);
    write_le16(frame + 6, 0xffff);
    assert(pltr_decode_frame(frame, sizeof(record) - 2, PLTR_RELAY_TO_CLIENT,
                             PLTR_SECURE, 1, &decoded) != 0);
    return 0;
}
