#include "client_pair.h"
#include "confirm.h"
#include "cpace.h"
#include "noise.h"
#include "protocol.h"

#include <sodium.h>
#include <stdlib.h>
#include <string.h>

typedef enum PltrClientPairStage {
    CLIENT_PAIR_CREATED = 1,
    CLIENT_PAIR_WAIT_RESPONSE = 2,
    CLIENT_PAIR_WAIT_RESULT = 3,
    CLIENT_PAIR_DONE = 4,
    CLIENT_PAIR_FAILED = 5,
} PltrClientPairStage;

struct PltrClientPair {
    PltrCpace cpace;
    PltrRecordReader reader;
    PltrClientPairStage stage;
    uint8_t code[5], sid[16], client_share[32], relay_share[32];
    uint8_t client_ad[97], relay_ad[97], relay_key[32], intermediate_key[64];
    size_t client_ad_size, relay_ad_size;
    uint8_t link_type;
    uint8_t button_approval, approval_status[8];
    uint32_t incoming_sequence, outgoing_sequence;
};

static int fail(PltrClientPair *pair) {
    pltr_cpace_clear(&pair->cpace);
    sodium_memzero(pair->intermediate_key, sizeof(pair->intermediate_key));
    sodium_memzero(pair->code, sizeof(pair->code));
    pair->stage = CLIENT_PAIR_FAILED;
    return -1;
}

static int emit(PltrClientPair *pair, uint16_t type,
                 const uint8_t *payload, size_t payload_size,
                 uint8_t *out, size_t capacity, size_t *written) {
    size_t frame_size;
    if (out == NULL || written == NULL || capacity < 2 ||
        pair->outgoing_sequence == UINT32_MAX ||
        pltr_encode_frame(type, pair->outgoing_sequence, payload, payload_size,
                          PLTR_CLIENT_TO_RELAY, PLTR_PRE_AUTH,
                          out + 2, capacity - 2, &frame_size) != 0 ||
        frame_size > UINT16_MAX) return -1;
    out[0] = (uint8_t)frame_size;
    out[1] = (uint8_t)(frame_size >> 8);
    *written = frame_size + 2;
    ++pair->outgoing_sequence;
    return 0;
}

PltrClientPair *pltr_client_pair_create(const uint8_t private_key[32],
                                        const uint8_t code[5],
                                        const uint8_t *name, size_t name_size,
                                        uint8_t link_type) {
    if (private_key == NULL || code == NULL || name == NULL ||
        name_size == 0 || name_size > 64 ||
        (link_type != 1 && link_type != 2) || sodium_init() < 0)
        return NULL;
    for (unsigned i = 0; i < 5; ++i)
        if (code[i] < '1' || code[i] > '8') return NULL;
    PltrClientPair *pair = calloc(1, sizeof(*pair));
    if (pair == NULL) return NULL;
    memcpy(pair->code, code, 5);
    if (pltr_noise_public_key(private_key, pair->client_ad) != 0) {
        pltr_client_pair_destroy(pair);
        return NULL;
    }
    pair->client_ad[32] = (uint8_t)name_size;
    memcpy(pair->client_ad + 33, name, name_size);
    pair->client_ad_size = 33 + name_size;
    pair->link_type = link_type;
    pair->stage = CLIENT_PAIR_CREATED;
    pair->outgoing_sequence = pair->incoming_sequence = 1;
    pltr_record_reader_init(&pair->reader, PLTR_PRE_AUTH);
    return pair;
}

PltrClientPair *pltr_client_pair_create_button(const uint8_t private_key[32],
    const uint8_t *name, size_t name_size) {
    PltrClientPair *pair = pltr_client_pair_create(private_key,
        (const uint8_t *)PLTR_BUTTON_APPROVAL_CODE, name, name_size, 1);
    if (pair) pair->button_approval = 1;
    return pair;
}

int pltr_client_pair_approval_status(const PltrClientPair *pair, uint8_t out[8]) {
    if (!pair || !out || !pair->button_approval || pair->approval_status[0] != 1) return -1;
    memcpy(out, pair->approval_status, 8);
    return 0;
}

void pltr_client_pair_destroy(PltrClientPair *pair) {
    if (pair == NULL) return;
    pltr_cpace_clear(&pair->cpace);
    sodium_memzero(pair, sizeof(*pair));
    free(pair);
}

int pltr_client_pair_start(PltrClientPair *pair, uint8_t *out,
                           size_t capacity, size_t *written) {
    if (pair == NULL || out == NULL || written == NULL ||
        pair->stage != CLIENT_PAIR_CREATED || capacity < 2) return -1;
    randombytes_buf(pair->sid, sizeof(pair->sid));
    if (pltr_cpace_start(&pair->cpace, PLTR_CPACE_INITIATOR, pair->code,
                          pair->link_type, pair->sid, pair->client_ad,
                          pair->client_ad_size, pair->client_share) != 0)
        return fail(pair);
    uint8_t payload[16 + 32 + sizeof(pair->client_ad)];
    memcpy(payload, pair->sid, 16);
    memcpy(payload + 16, pair->client_share, 32);
    memcpy(payload + 48, pair->client_ad, pair->client_ad_size);
    const uint8_t mode = pair->button_approval ? 3 : 2;
    size_t open_size, start_size;
    if (emit(pair, PLTR_OPEN, &mode, 1,
              out, capacity, &open_size) != 0 ||
        emit(pair, PLTR_PAIR_START, payload, 48 + pair->client_ad_size,
              out + open_size, capacity - open_size, &start_size) != 0)
        return fail(pair);
    *written = open_size + start_size;
    sodium_memzero(pair->code, sizeof(pair->code));
    pair->stage = CLIENT_PAIR_WAIT_RESPONSE;
    return 0;
}

int pltr_client_pair_receive(PltrClientPair *pair, const uint8_t *bytes,
                             size_t size, size_t *consumed,
                             uint8_t *reply, size_t reply_capacity,
                             size_t *reply_size,
                             uint8_t relay_public_key[32]) {
    if (pair == NULL || consumed == NULL || reply_size == NULL ||
        relay_public_key == NULL ||
        (pair->stage != CLIENT_PAIR_WAIT_RESPONSE &&
         pair->stage != CLIENT_PAIR_WAIT_RESULT)) return -1;
    *reply_size = 0;
    const uint8_t *body;
    size_t body_size;
    const int record = pltr_record_reader_push(&pair->reader, bytes, size,
                                                consumed, &body, &body_size);
    if (record < 0) return fail(pair);
    if (record == 0) return 0;
    PltrFrame frame;
    if (pltr_decode_frame(body, body_size, PLTR_RELAY_TO_CLIENT, PLTR_PRE_AUTH,
                          pair->incoming_sequence, &frame) != 0 ||
        pair->incoming_sequence == UINT32_MAX) return fail(pair);
    ++pair->incoming_sequence;
    if (frame.type == PLTR_PAIR_RESULT && frame.payload[0] != 0)
        return fail(pair);
    if (pair->stage == CLIENT_PAIR_WAIT_RESPONSE) {
        if (frame.type == PLTR_PAIR_APPROVAL && pair->button_approval) {
            memcpy(pair->approval_status, frame.payload, 8);
            return 3;
        }
        if (frame.type != PLTR_PAIR_RESPONSE || reply == NULL ||
            reply_capacity < 2 + PLTR_HEADER_SIZE + 32)
            return fail(pair);
        memcpy(pair->relay_share, frame.payload, 32);
        pair->relay_ad_size = frame.payload_size - 32;
        memcpy(pair->relay_ad, frame.payload + 32, pair->relay_ad_size);
        memcpy(pair->relay_key, pair->relay_ad, 32);
        uint8_t tag[32];
        if (pltr_cpace_finish(&pair->cpace, pair->relay_share,
                              pair->relay_ad, pair->relay_ad_size,
                              pair->intermediate_key) != 0 ||
            pltr_pair_confirmation_tag(
                pair->intermediate_key, PLTR_CPACE_INITIATOR,
                pair->sid, pair->client_share,
                pair->client_ad, pair->client_ad_size,
                pair->relay_share, pair->relay_ad, pair->relay_ad_size,
                tag) != 0 ||
            emit(pair, PLTR_PAIR_CONFIRM, tag, sizeof(tag),
                  reply, reply_capacity, reply_size) != 0) {
            sodium_memzero(tag, sizeof(tag));
            return fail(pair);
        }
        sodium_memzero(tag, sizeof(tag));
        pair->stage = CLIENT_PAIR_WAIT_RESULT;
        return 1;
    }
    if (frame.type != PLTR_PAIR_RESULT || frame.payload_size != 33 ||
        pltr_pair_confirmation_verify(
            pair->intermediate_key, PLTR_CPACE_RESPONDER,
            pair->sid, pair->client_share,
            pair->client_ad, pair->client_ad_size,
            pair->relay_share, pair->relay_ad, pair->relay_ad_size,
            frame.payload + 1) != 0)
        return fail(pair);
    memcpy(relay_public_key, pair->relay_key, 32);
    sodium_memzero(pair->intermediate_key, sizeof(pair->intermediate_key));
    pair->stage = CLIENT_PAIR_DONE;
    return 2;
}
