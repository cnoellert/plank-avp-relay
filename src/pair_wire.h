#ifndef PLANK_RELAY_PAIR_WIRE_H
#define PLANK_RELAY_PAIR_WIRE_H

#include "pairing.h"
#include "protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum PltrPairWireStage {
    PLTR_PAIR_WIRE_OPEN = 1,
    PLTR_PAIR_WIRE_START = 2,
    PLTR_PAIR_WIRE_KEYS = 3,
    PLTR_PAIR_WIRE_CONFIRM = 4,
    PLTR_PAIR_WIRE_DONE = 5,
    PLTR_PAIR_WIRE_FAILED = 6,
} PltrPairWireStage;

typedef struct PltrPairWire {
    PltrPairing *pairing;
    PltrRecordReader reader;
    PltrPairWireStage stage;
    uint32_t incoming_sequence, outgoing_sequence;
    uint8_t link_type, open_mode;
} PltrPairWire;

// One connection has one OPEN/PAIR_START attempt. The pairing engine persists
// across connections so lockout cannot be bypassed by reconnecting.
int pltr_pair_wire_init(PltrPairWire *wire, PltrPairing *pairing,
                        uint8_t link_type);
// Explicit opt-in, used only by the physical-approval BLE lab.
int pltr_pair_wire_button_approval(PltrPairWire *wire);
int pltr_pair_wire_approval_status(PltrPairWire *wire, const uint8_t status[8],
    uint8_t *out, size_t capacity, size_t *written);
int pltr_pair_wire_receive(PltrPairWire *wire, const uint8_t *bytes, size_t size,
                            size_t *consumed, uint64_t now_ms,
                            uint8_t *out, size_t capacity, size_t *written);
int pltr_pair_wire_key(PltrPairWire *wire, uint8_t key, uint64_t now_ms,
                        uint8_t *out, size_t capacity, size_t *written);
int pltr_pair_wire_tick(PltrPairWire *wire, uint64_t now_ms,
                         uint8_t *out, size_t capacity, size_t *written);
void pltr_pair_wire_close(PltrPairWire *wire, uint64_t now_ms);

#ifdef __cplusplus
}
#endif
#endif
