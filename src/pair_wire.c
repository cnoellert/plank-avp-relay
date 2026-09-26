#include "pair_wire.h"

#include <string.h>

static int fail(PltrPairWire *wire, uint64_t now_ms) {
    pltr_pairing_abort(wire->pairing, now_ms);
    wire->stage = PLTR_PAIR_WIRE_FAILED;
    return -1;
}

static int emit(PltrPairWire *wire, uint16_t type, const uint8_t *payload,
                 size_t payload_size, uint8_t *out, size_t capacity,
                 size_t *written) {
    size_t frame_size;
    if (out == NULL || written == NULL || capacity < 2 ||
        wire->outgoing_sequence == UINT32_MAX ||
        pltr_encode_frame(type, wire->outgoing_sequence, payload, payload_size,
                          PLTR_RELAY_TO_CLIENT, PLTR_PRE_AUTH, out + 2,
                          capacity - 2, &frame_size) != 0 ||
        frame_size > UINT16_MAX) return -1;
    out[0] = (uint8_t)frame_size;
    out[1] = (uint8_t)(frame_size >> 8);
    *written = frame_size + 2;
    ++wire->outgoing_sequence;
    return 1;
}

int pltr_pair_wire_init(PltrPairWire *wire, PltrPairing *pairing,
                        uint8_t link_type) {
    if (wire == NULL || pairing == NULL ||
        (link_type != 1 && link_type != 2)) return -1;
    memset(wire, 0, sizeof(*wire));
    wire->pairing = pairing;
    wire->link_type = link_type;
    wire->incoming_sequence = wire->outgoing_sequence = 1;
    wire->stage = PLTR_PAIR_WIRE_OPEN;
    pltr_record_reader_init(&wire->reader, PLTR_PRE_AUTH);
    return 0;
}

int pltr_pair_wire_receive(PltrPairWire *wire, const uint8_t *bytes, size_t size,
                            size_t *consumed, uint64_t now_ms,
                            uint8_t *out, size_t capacity, size_t *written) {
    if (wire == NULL || consumed == NULL || written == NULL ||
        wire->stage == PLTR_PAIR_WIRE_DONE ||
        wire->stage == PLTR_PAIR_WIRE_FAILED) return -1;
    *written = 0;
    const uint8_t *body = NULL;
    size_t body_size = 0;
    const int record = pltr_record_reader_push(&wire->reader, bytes, size,
                                                consumed, &body, &body_size);
    if (record < 0) return fail(wire, now_ms);
    if (record == 0) return 0;
    PltrFrame frame;
    if (pltr_decode_frame(body, body_size, PLTR_CLIENT_TO_RELAY, PLTR_PRE_AUTH,
                          wire->incoming_sequence, &frame) != 0 ||
        wire->incoming_sequence == UINT32_MAX) return fail(wire, now_ms);
    ++wire->incoming_sequence;
    if (wire->stage == PLTR_PAIR_WIRE_OPEN) {
        if (frame.type != PLTR_OPEN || frame.payload[0] != 2 ||
            wire->pairing->stage != PLTR_PAIR_WINDOW)
            return fail(wire, now_ms);
        wire->stage = PLTR_PAIR_WIRE_START;
        return 1;
    }
    if (wire->stage == PLTR_PAIR_WIRE_START) {
        if (frame.type != PLTR_PAIR_START ||
            pltr_pairing_start(wire->pairing, frame.payload,
                                frame.payload_size, wire->link_type,
                                now_ms) != 0) return fail(wire, now_ms);
        wire->stage = PLTR_PAIR_WIRE_KEYS;
        return 1;
    }
    if (wire->stage == PLTR_PAIR_WIRE_CONFIRM) {
        uint8_t result[33];
        size_t result_size;
        if (frame.type != PLTR_PAIR_CONFIRM || out == NULL ||
            capacity < 2 + PLTR_HEADER_SIZE + sizeof(result) ||
            pltr_pairing_confirm(wire->pairing, frame.payload, now_ms,
                                  result, &result_size) != 1)
            return fail(wire, now_ms);
        wire->stage = PLTR_PAIR_WIRE_DONE;
        return emit(wire, PLTR_PAIR_RESULT, result, result_size,
                     out, capacity, written) < 0 ? fail(wire, now_ms) : 1;
    }
    return fail(wire, now_ms);
}

int pltr_pair_wire_key(PltrPairWire *wire, uint8_t key, uint64_t now_ms,
                        uint8_t *out, size_t capacity, size_t *written) {
    if (wire == NULL || written == NULL ||
        wire->stage != PLTR_PAIR_WIRE_KEYS) return -1;
    *written = 0;
    if (out == NULL || capacity < 2 + PLTR_HEADER_SIZE + 129)
        return fail(wire, now_ms);
    uint8_t response[129];
    size_t response_size;
    const int result = pltr_pairing_key(wire->pairing, key, now_ms,
                                        response, sizeof(response),
                                        &response_size);
    if (result < 0) return fail(wire, now_ms);
    if (result == 0) return 0;
    wire->stage = PLTR_PAIR_WIRE_CONFIRM;
    return emit(wire, PLTR_PAIR_RESPONSE, response, response_size,
                 out, capacity, written) < 0 ? fail(wire, now_ms) : 1;
}

int pltr_pair_wire_tick(PltrPairWire *wire, uint64_t now_ms,
                         uint8_t *out, size_t capacity, size_t *written) {
    if (wire == NULL || written == NULL ||
        wire->stage == PLTR_PAIR_WIRE_DONE ||
        wire->stage == PLTR_PAIR_WIRE_FAILED) return -1;
    *written = 0;
    const int timeout = pltr_pairing_tick(wire->pairing, now_ms);
    if (timeout < 0) return fail(wire, now_ms);
    if (timeout == 1) {
        const uint8_t result = 2;
        wire->stage = PLTR_PAIR_WIRE_DONE;
        return emit(wire, PLTR_PAIR_RESULT, &result, 1,
                     out, capacity, written) < 0 ? -1 : 1;
    }
    if (wire->pairing->stage == PLTR_PAIR_CLOSED &&
        (wire->stage == PLTR_PAIR_WIRE_OPEN ||
         wire->stage == PLTR_PAIR_WIRE_START))
        return fail(wire, now_ms);
    return 0;
}

void pltr_pair_wire_close(PltrPairWire *wire, uint64_t now_ms) {
    if (wire == NULL) return;
    if (wire->stage != PLTR_PAIR_WIRE_DONE)
        pltr_pairing_abort(wire->pairing, now_ms);
    wire->stage = PLTR_PAIR_WIRE_DONE;
}
