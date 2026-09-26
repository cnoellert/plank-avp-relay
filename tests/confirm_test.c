#include "confirm.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static void hex(const char *source, uint8_t *out, size_t size) {
    assert(strlen(source) == size * 2);
    for (size_t i = 0; i < size; ++i) {
        int a = nibble(source[2*i]), b = nibble(source[2*i+1]);
        assert(a >= 0 && b >= 0);
        out[i] = (uint8_t)((a << 4) | b);
    }
}
int main(void) {
    uint8_t isk[64], sid[16], ya[32], yb[32], client[32], relay[32];
    hex("b69effbf61b51d56401c0f65601abe428de8206feaaf0e32198896dcae7b35cd"
        "2b38950a39dfd5d4a79164614c2984f7daa460b588c1e80c3fa2068af7900447",
        isk, 64);
    hex("7e4b4791d6a8ef019b936c79fb7f2c57", sid, 16);
    hex("d6bac480f2c386c394efc7c47adb9925dcd2630b64f240c50f8d0eec482b9157", ya, 32);
    hex("3ea7e0b19560d7c0b0f5734f63b955286dfa8232b5ebe63324e2d9e7433f7258", yb, 32);
    const uint8_t ada[] = {'A','D','a'}, adb[] = {'A','D','b'};
    assert(pltr_pair_confirmation_tag(isk, PLTR_CPACE_INITIATOR, sid,
                                      ya, ada, 3, yb, adb, 3, client) == 0);
    assert(pltr_pair_confirmation_tag(isk, PLTR_CPACE_RESPONDER, sid,
                                      ya, ada, 3, yb, adb, 3, relay) == 0);
    uint8_t expected_client[32], expected_relay[32];
    hex("4eb4d62e8da23d2f137d4161468aeea800cf3201828db09bfd282253adb88290",
        expected_client, 32);
    hex("eddc2b64d68ab14f93e4d4302f332419c8a8c49bda8442ccd757b4860fb97551",
        expected_relay, 32);
    assert(memcmp(client, expected_client, 32) == 0);
    assert(memcmp(relay, expected_relay, 32) == 0);
    assert(memcmp(client, relay, 32) != 0);
    assert(pltr_pair_confirmation_verify(isk, PLTR_CPACE_INITIATOR, sid,
                                         ya, ada, 3, yb, adb, 3, client) == 0);
    assert(pltr_pair_confirmation_verify(isk, PLTR_CPACE_RESPONDER, sid,
                                         ya, ada, 3, yb, adb, 3, relay) == 0);
    sid[0] ^= 1;
    assert(pltr_pair_confirmation_verify(isk, PLTR_CPACE_INITIATOR, sid,
                                         ya, ada, 3, yb, adb, 3, client) != 0);
    return 0;
}
