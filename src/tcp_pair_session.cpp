#include "tcp_pair_session.hpp"

#include "pair_wire.h"
#include "tcp_io.hpp"

#include <array>
#include <chrono>
#include <cerrno>
#include <cstdint>
#include <poll.h>
#include <sys/socket.h>

namespace {
using Clock = std::chrono::steady_clock;

std::uint64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               Clock::now().time_since_epoch()).count();
}
} // namespace

int pltr_run_tcp_pair_session(int socket_fd, PltrPairing &pairing,
                              PltrPad &pad, int stop_fd) {
    if (socket_fd < 0 || pad.fd < 0 ||
        (stop_fd >= 0 && (stop_fd == socket_fd || stop_fd == pad.fd)))
        return -1;
    PltrPairWire wire{};
    if (pltr_pair_wire_init(&wire, &pairing, 2) != 0) return -1;
    std::array<std::uint8_t, 4096> input{};
    std::array<std::uint8_t, 2 + PLTR_MAX_FRAME_SIZE> output{};
    int result = -1;
    while (true) {
        std::size_t written = 0;
        const int tick = pltr_pair_wire_tick(&wire, now_ms(),
                                              output.data(), output.size(),
                                              &written);
        if (tick < 0) break;
        if (tick == 1) {
            (void)pltr_send_all(socket_fd, output.data(), written);
            break; // timeout result is terminal
        }
        pollfd fds[3] = {{socket_fd, POLLIN, 0}, {pad.fd, POLLIN, 0},
                         {stop_fd, POLLIN, 0}};
        const nfds_t count = stop_fd >= 0 ? 3 : 2;
        const int ready = poll(fds, count, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || (stop_fd >= 0 && fds[2].revents != 0) ||
            (fds[0].revents & (POLLERR | POLLNVAL)) ||
            ((fds[0].revents & POLLHUP) && !(fds[0].revents & POLLIN)) ||
            (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL))) break;
        if (fds[0].revents & POLLIN) {
            const ssize_t received = recv(socket_fd, input.data(), input.size(),
                                           MSG_DONTWAIT);
            if (received < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            if (received <= 0) break;
            std::size_t offset = 0;
            bool failed = false;
            while (offset < static_cast<std::size_t>(received)) {
                std::size_t consumed = 0;
                const int handled = pltr_pair_wire_receive(
                    &wire, input.data() + offset,
                    static_cast<std::size_t>(received) - offset,
                    &consumed, now_ms(), output.data(), output.size(), &written);
                if (handled < 0 || consumed == 0 ||
                    (written && !pltr_send_all(socket_fd, output.data(), written))) {
                    failed = true;
                    break;
                }
                offset += consumed;
                if (wire.stage == PLTR_PAIR_WIRE_DONE) {
                    if (written && pairing.stage == PLTR_PAIR_CLOSED &&
                        pairing.failures == 0) result = 0;
                    break;
                }
            }
            if (failed || wire.stage == PLTR_PAIR_WIRE_DONE) break;
        }
        if (fds[1].revents & POLLIN) {
            std::uint8_t key = 0;
            const int pad_result = pltr_pad_read(&pad, now_ms(), &key);
            if (pad_result < 0) break;
            if (pad_result == 1 && wire.stage == PLTR_PAIR_WIRE_KEYS) {
                const int key_result = pltr_pair_wire_key(
                    &wire, key, now_ms(), output.data(), output.size(), &written);
                if (key_result < 0 ||
                    (key_result == 1 &&
                     !pltr_send_all(socket_fd, output.data(), written))) break;
            }
        }
    }
    pltr_pair_wire_close(&wire, now_ms());
    return result;
}
