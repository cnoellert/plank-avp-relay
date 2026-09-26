#include "worker_bridge.hpp"
#include "../vendor/plank-client/plank.h"

#include <cassert>
#include <cstdint>

static void le16(std::uint8_t *p, std::uint16_t value) {
    p[0] = static_cast<std::uint8_t>(value);
    p[1] = static_cast<std::uint8_t>(value >> 8);
}

static void le32(std::uint8_t *p, std::uint32_t value) {
    for (unsigned i = 0; i < 4; ++i)
        p[i] = static_cast<std::uint8_t>(value >> (8 * i));
}

int main() {
    unsigned wakeups = 0;
    PltrWorkerBridge bridge([&] { ++wakeups; });
    std::uint8_t frame[sizeof(PLANK_RAW_HID_WIRE_HEADER) + 1] = {};
    le32(frame, PLANK_RAW_HID_WIRE_MAGIC);
    le16(frame + 4, PLANK_RAW_HID_WIRE_VERSION);
    le16(frame + 6, PLANK_RAW_HID_SUSPEND);
    assert(bridge.enqueue(frame, sizeof(frame) - 1));
    PltrQueuedTabletFrame item;
    assert(bridge.pop(item));
    assert(item.capture_time_us == 0 &&
           item.plwh.size() == sizeof(frame) - 1 && wakeups == 1);
    assert(!bridge.pop(item));

    le16(frame + 6, PLANK_RAW_HID_INPUT);
    le32(frame + 16, 1);
    frame[sizeof(frame) - 1] = 7;
    assert(bridge.enqueue(frame, sizeof(frame)));
    assert(bridge.pop(item));
    assert(item.capture_time_us != 0 && item.plwh.back() == 7);

    le16(frame + 6, PLANK_RAW_HID_SUSPEND);
    le32(frame + 16, 0);
    for (unsigned i = 0; i < 256; ++i)
        assert(bridge.enqueue(frame, sizeof(frame) - 1));
    assert(!bridge.enqueue(frame, sizeof(frame) - 1));
    assert(bridge.failed());
    return 0;
}
