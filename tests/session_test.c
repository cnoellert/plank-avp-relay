#include "session.h"
#include "../vendor/plank-client/plank.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

static void le16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static size_t make(uint8_t *out, uint32_t sequence, uint16_t type,
                   const uint8_t *payload, size_t size) {
    le32(out, PLTR_MAGIC); le16(out + 4, PLTR_VERSION);
    le16(out + 6, type); le32(out + 8, sequence); le32(out + 12, (uint32_t)size);
    if (size) memcpy(out + PLTR_HEADER_SIZE, payload, size);
    return PLTR_HEADER_SIZE + size;
}
int main(void) {
    uint8_t bytes[128], hello[14] = {0}, ready[5] = {0};
    PltrFrame frame = {0};
    PltrRelaySession session;
    le16(hello, 1); le16(hello + 2, 1); hello[4] = 2;
    le32(hello + 8, 1); hello[12] = 1; hello[13] = 'C';
    le32(ready, 0x24); ready[4] = 1;
    pltr_relay_session_init(&session, 1);
    size_t n = make(bytes, 1, PLTR_SESSION_READY, ready, sizeof(ready));
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) != 0);
    assert(session.stage == PLTR_RELAY_BROKEN);
    pltr_relay_session_init(&session, 1);
    n = make(bytes, 1, PLTR_HELLO, hello, sizeof(hello));
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    assert(session.stage == PLTR_RELAY_WAIT_READY && session.expected_sequence == 2);
    n = make(bytes, 2, PLTR_SESSION_READY, ready, sizeof(ready));
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    assert(session.stage == PLTR_RELAY_READY && session.active == 1);
    uint8_t hid[sizeof(PLANK_RAW_HID_WIRE_HEADER)] = {0};
    le32(hid, PLANK_RAW_HID_WIRE_MAGIC);
    le16(hid + 4, PLANK_RAW_HID_WIRE_VERSION);
    le16(hid + 6, PLANK_RAW_HID_GET_REPORT);
    n = make(bytes, 3, PLTR_HOST_FRAME, hid, sizeof(hid));
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    assert(frame.type == PLTR_HOST_FRAME && frame.payload_size == sizeof(hid));
    n = make(bytes, 4, PLTR_RECONNECT_BEGIN, NULL, 0);
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    assert(session.stage == PLTR_RELAY_RECONNECTING && session.active == 0);
    n = make(bytes, 5, PLTR_HOST_FRAME, hid, sizeof(hid));
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) != 0);
    assert(session.stage == PLTR_RELAY_BROKEN);

    pltr_relay_session_init(&session, 4);
    session.stage = PLTR_RELAY_READY;
    n = make(bytes, 4, PLTR_RECONNECT_BEGIN, NULL, 0);
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    n = make(bytes, 5, PLTR_RECONNECT_FINISH, NULL, 0);
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    assert(session.stage == PLTR_RELAY_READY);
    const uint8_t active[] = {1};
    n = make(bytes, 6, PLTR_SESSION_ACTIVE, active, sizeof(active));
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    assert(session.active == 1);
    const uint8_t end[] = {1};
    n = make(bytes, 7, PLTR_SESSION_END, end, sizeof(end));
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) == 0);
    assert(session.stage == PLTR_RELAY_ENDED && session.active == 0);
    n = make(bytes, 8, PLTR_PING, (const uint8_t[16]){0}, 16);
    assert(pltr_relay_session_accept(&session, bytes, n, &frame) != 0);
    return 0;
}
