#include "cpace.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

/* draft-irtf-cfrg-cpace-21, Appendix B.3, initiator/responder vector. */
static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static size_t hex(const char *source, uint8_t *out, size_t capacity) {
    size_t size = strlen(source);
    assert(size % 2 == 0 && size / 2 <= capacity);
    for (size_t i = 0; i < size / 2; ++i) {
        int a = nibble(source[2 * i]), b = nibble(source[2 * i + 1]);
        assert(a >= 0 && b >= 0);
        out[i] = (uint8_t)((a << 4) | b);
    }
    return size / 2;
}
static void expected(const uint8_t *actual, size_t size, const char *value) {
    uint8_t decoded[64];
    assert(hex(value, decoded, sizeof(decoded)) == size);
    assert(memcmp(actual, decoded, size) == 0);
}
int main(void) {
    const uint8_t prs[] = "Password";
    const uint8_t ada[] = "ADa", adb[] = "ADb";
    uint8_t ci[32], sid[16], ya_scalar[32], yb_scalar[32];
    size_t ci_size = hex("0b415f696e69746961746f720b425f726573706f6e646572", ci, sizeof(ci));
    hex("7e4b4791d6a8ef019b936c79fb7f2c57", sid, sizeof(sid));
    hex("da3d23700a9e5699258aef94dc060dfda5ebb61f02a5ea77fad53f4ff0976d08",
        ya_scalar, sizeof(ya_scalar));
    hex("d2316b454718c35362d83d69df6320f38578ed5984651435e2949762d900b80d",
        yb_scalar, sizeof(yb_scalar));
    PltrCpace a, b;
    uint8_t ya[32], yb[32], ga[32], gb[32], isk_a[64], isk_b[64];
    assert(pltr_cpace_start_test(&a, PLTR_CPACE_INITIATOR, prs, 8,
                                 ci, ci_size, sid, ada, 3, ya_scalar, ya, ga) == 0);
    assert(pltr_cpace_start_test(&b, PLTR_CPACE_RESPONDER, prs, 8,
                                 ci, ci_size, sid, adb, 3, yb_scalar, yb, gb) == 0);
    expected(ga, 32, "222b6b195fe84b1652badb6f6a3ae3d24341e7306967f0b8115b40d5698c7e56");
    assert(memcmp(ga, gb, 32) == 0);
    expected(ya, 32, "d6bac480f2c386c394efc7c47adb9925dcd2630b64f240c50f8d0eec482b9157");
    expected(yb, 32, "3ea7e0b19560d7c0b0f5734f63b955286dfa8232b5ebe63324e2d9e7433f7258");
    assert(pltr_cpace_finish(&a, yb, adb, 3, isk_a) == 0);
    assert(pltr_cpace_finish(&b, ya, ada, 3, isk_b) == 0);
    assert(memcmp(isk_a, isk_b, 64) == 0);
    expected(isk_a, 64,
             "b69effbf61b51d56401c0f65601abe428de8206feaaf0e32198896dcae7b35cd"
             "2b38950a39dfd5d4a79164614c2984f7daa460b588c1e80c3fa2068af7900447");

    const uint8_t code[5] = {'1','8','2','8','4'};
    uint8_t wrong[5] = {'1','8','2','8','5'};
    assert(pltr_cpace_start(&a, PLTR_CPACE_INITIATOR, code, 2,
                            sid, ada, 3, ya) == 0);
    assert(pltr_cpace_start(&b, PLTR_CPACE_RESPONDER, code, 2,
                            sid, adb, 3, yb) == 0);
    assert(pltr_cpace_finish(&a, yb, adb, 3, isk_a) == 0);
    assert(pltr_cpace_finish(&b, ya, ada, 3, isk_b) == 0);
    assert(memcmp(isk_a, isk_b, 64) == 0);
    assert(pltr_cpace_start(&a, PLTR_CPACE_INITIATOR, code, 2,
                            sid, ada, 3, ya) == 0);
    assert(pltr_cpace_start(&b, PLTR_CPACE_RESPONDER, wrong, 2,
                            sid, adb, 3, yb) == 0);
    assert(pltr_cpace_finish(&a, yb, adb, 3, isk_a) == 0);
    assert(pltr_cpace_finish(&b, ya, ada, 3, isk_b) == 0);
    assert(memcmp(isk_a, isk_b, 64) != 0);
    uint8_t invalid[32] = {0};
    assert(pltr_cpace_start(&a, PLTR_CPACE_INITIATOR, code, 2,
                            sid, ada, 3, ya) == 0);
    assert(pltr_cpace_finish(&a, invalid, adb, 3, isk_a) != 0);
    assert(pltr_cpace_start(&a, PLTR_CPACE_INITIATOR, code, 3,
                            sid, ada, 3, ya) != 0);
    return 0;
}
