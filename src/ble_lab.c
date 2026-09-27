// SPDX-License-Identifier: GPL-3.0-or-later
// Small opaque adapter for the BlueZ diagnostic service. Cryptographic and
// persistent pairing behavior come from the production protocol implementation.
#include "ble_lab.h"
#include "identity.h"
#include "link.h"
#include "pair_budget.h"
#include "pair_wire.h"
#include <sodium.h>
#include <stdlib.h>
#include <string.h>

struct PltrBleLab {
    PltrIdentityStore store;
    PltrPairing pairing;
    PltrPairWire wire;
    PltrLink link;
    PltrRecordReader probe;
    unsigned mode;
    uint64_t started_ms, received_ms, ping_ms;
};

PltrBleLab *pltr_ble_lab_create(const char *directory) {
    if (!directory || sodium_init() < 0) return NULL;
    PltrBleLab *lab = calloc(1, sizeof(*lab));
    if (!lab) return NULL;
    lab->store.directory_fd = lab->store.lock_fd = -1;
    const uint8_t name[] = "PLANK Relay Lab";
    if (pltr_identity_store_open(&lab->store, directory) != 0 ||
        pltr_pairing_init(&lab->pairing, &lab->store, name, sizeof(name)-1) != 0) {
        pltr_ble_lab_destroy(lab);
        return NULL;
    }
    pltr_record_reader_init(&lab->probe, PLTR_PRE_AUTH);
    return lab;
}

void pltr_ble_lab_destroy(PltrBleLab *lab) {
    if (!lab) return;
    pltr_link_clear(&lab->link);
    pltr_pairing_clear(&lab->pairing);
    pltr_identity_store_close(&lab->store);
    sodium_memzero(lab, sizeof(*lab));
    free(lab);
}

int pltr_ble_lab_open_pairing(PltrBleLab *lab, uint64_t wall_seconds, uint64_t now_ms) {
    if (!lab || lab->mode || lab->probe.filled ||
        pltr_pair_budget_reserve(&lab->store, wall_seconds) != 0) return -1;
    return pltr_pairing_open(&lab->pairing, now_ms, 0);
}

void pltr_ble_lab_disconnect(PltrBleLab *lab, uint64_t now_ms) {
    if (!lab) return;
    if (lab->mode == 2) pltr_pair_wire_close(&lab->wire, now_ms);
    pltr_link_clear(&lab->link);
    memset(&lab->wire, 0, sizeof(lab->wire));
    pltr_record_reader_init(&lab->probe, PLTR_PRE_AUTH);
    lab->mode = 0;
    lab->started_ms = lab->received_ms = lab->ping_ms = 0;
}

int pltr_ble_lab_receive(PltrBleLab *lab, const uint8_t *data, size_t size,
    size_t *consumed, uint64_t now_ms, uint8_t *out, size_t capacity, size_t *written) {
    if (!lab || !data || !size || !consumed || !out || !written) return -1;
    *consumed = *written = 0;
    if (!lab->started_ms) lab->started_ms = now_ms;
    lab->received_ms = now_ms;
    if (!lab->mode) {
        const uint8_t *body;
        size_t body_size;
        int result = pltr_record_reader_push(&lab->probe, data, size,
                                             consumed, &body, &body_size);
        if (result <= 0) return result;
        PltrFrame first;
        if (pltr_decode_frame(body, body_size, PLTR_CLIENT_TO_RELAY,
                              PLTR_PRE_AUTH, 1, &first) != 0 ||
            first.type != PLTR_OPEN) return -1;
        lab->mode = first.payload[0];
        if (lab->mode == 2) {
            if (pltr_pair_wire_init(&lab->wire, &lab->pairing, 1) != 0) return -1;
        } else {
            if (pltr_link_init(&lab->link, PLTR_NOISE_RESPONDER,
                lab->store.private_key, NULL, pltr_identity_store_approve,
                &lab->store, 1) != 0 ||
                pltr_link_enable_input_observer(&lab->link) != 0) return -1;
        }
        // Replay the already validated OPEN into the selected stream parser.
        size_t replayed = 0;
        return pltr_ble_lab_receive(lab, lab->probe.bytes, body_size + 2,
            &replayed, now_ms, out, capacity, written);
    }
    if (lab->mode == 2) {
        int result = pltr_pair_wire_receive(&lab->wire, data, size, consumed,
                                            now_ms, out, capacity, written);
        if (result >= 0 && lab->wire.stage == PLTR_PAIR_WIRE_DONE &&
            *written == 2 + PLTR_HEADER_SIZE + 33 && out[2 + PLTR_HEADER_SIZE] == 0 &&
            pltr_pair_budget_succeeded(&lab->store) != 0) return -1;
        return result;
    }
    PltrFrame frame;
    int result = pltr_link_receive(&lab->link, data, size, consumed,
                                    out, capacity, written, &frame);
    if (result != 1 || !frame.type) return result;
    if (frame.type == PLTR_PONG || frame.type == PLTR_INPUT_OBSERVE ||
        frame.type == PLTR_GOODBYE) return 1;
    if (frame.type == PLTR_PING) {
        uint8_t pong[32] = {0};
        memcpy(pong, frame.payload, 16);
        for (unsigned i = 0; i < 8; ++i) {
            pong[16+i] = pong[24+i] = (uint8_t)((now_ms * 1000) >> (8*i));
        }
        return pltr_link_send(&lab->link, PLTR_PONG, pong, sizeof(pong),
                               out, capacity, written) == 0 ? 1 : -1;
    }
    // This observer never negotiates Host features or starts a raw-HID worker.
    return -1;
}

int pltr_ble_lab_key(PltrBleLab *lab, uint8_t key, uint64_t now_ms,
    uint8_t *out, size_t capacity, size_t *written) {
    if (!lab || !written) return -1;
    *written = 0;
    if (lab->mode != 2 || lab->wire.stage != PLTR_PAIR_WIRE_KEYS) return 0;
    return pltr_pair_wire_key(&lab->wire, key, now_ms, out, capacity, written);
}

int pltr_ble_lab_tick(PltrBleLab *lab, uint64_t now_ms,
    uint8_t *out, size_t capacity, size_t *written) {
    if (!lab || !out || !written) return -1;
    *written = 0;
    if (lab->mode == 2) {
        if (lab->wire.stage == PLTR_PAIR_WIRE_DONE)
            return now_ms - lab->received_ms > 10000 ? -1 : 0;
        return pltr_pair_wire_tick(&lab->wire, now_ms, out, capacity, written);
    }
    if (!lab->mode) {
        (void)pltr_pairing_tick(&lab->pairing, now_ms);
        return lab->started_ms && now_ms - lab->started_ms > 10000 ? -1 : 0;
    }
    if (lab->link.stage == PLTR_LINK_CLOSED)
        return now_ms - lab->received_ms > 10000 ? -1 : 0;
    if (lab->link.stage != PLTR_LINK_READY)
        return now_ms - lab->started_ms > 10000 ? -1 : 0;
    if (now_ms - lab->received_ms > 10000) return -1;
    if (now_ms - lab->ping_ms < 1000) return 0;
    uint8_t ping[16] = {0};
    for (unsigned i = 0; i < 8; ++i)
        ping[i] = ping[8+i] = (uint8_t)((now_ms * 1000) >> (8*i));
    lab->ping_ms = now_ms;
    return pltr_link_send(&lab->link, PLTR_PING, ping, sizeof(ping),
                           out, capacity, written) == 0 ? 1 : -1;
}

int pltr_ble_lab_observing(const PltrBleLab *lab) {
    return lab && lab->mode == 1 && lab->link.stage == PLTR_LINK_READY &&
           lab->link.relay_session.stage == PLTR_RELAY_OBSERVING;
}

int pltr_ble_lab_sample(PltrBleLab *lab, const uint8_t *payload, size_t size,
    uint8_t *out, size_t capacity, size_t *written) {
    if (!pltr_ble_lab_observing(lab)) return -1;
    return pltr_link_send(&lab->link, PLTR_INPUT_SAMPLE, payload, size,
                           out, capacity, written);
}
