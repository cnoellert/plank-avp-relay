#include "session_dispatcher.hpp"

#include <cassert>
#include <cstdint>

int main() {
    PltrSessionDispatcher dispatcher([] {});
    std::uint8_t ready[] = {0x24, 0, 0, 0, 0};
    PltrFrame frame = {PLTR_SESSION_READY, 1, ready, sizeof(ready)};
    assert(dispatcher.accept(frame));
    assert(!dispatcher.accept(frame));
    frame = {PLTR_RECONNECT_BEGIN, 2, nullptr, 0};
    assert(dispatcher.accept(frame));
    frame = {PLTR_RECONNECT_FINISH, 3, nullptr, 0};
    assert(dispatcher.accept(frame));
    std::uint8_t active[] = {0};
    frame = {PLTR_SESSION_ACTIVE, 4, active, sizeof(active)};
    assert(dispatcher.accept(frame));
    frame = {PLTR_SESSION_END, 5, active, sizeof(active)};
    assert(dispatcher.accept(frame));
    assert(!dispatcher.accept(frame));

    // A control frame before SESSION_READY must not create or drive a worker.
    PltrSessionDispatcher early([] {});
    frame = {PLTR_HOST_FRAME, 1, active, sizeof(active)};
    assert(!early.accept(frame));
    frame = {PLTR_RECONNECT_BEGIN, 2, nullptr, 0};
    assert(!early.accept(frame));
    frame = {PLTR_SESSION_READY, 3, ready, sizeof(ready)};
    assert(early.accept(frame));
    early.close();
    assert(!early.accept(frame));
    return 0;
}
