#pragma once

#include <chrono>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <poll.h>
#include <sys/socket.h>

inline bool pltr_send_all(int fd, const std::uint8_t *bytes, std::size_t size) {
    using Clock = std::chrono::steady_clock;
    const auto deadline = Clock::now() + std::chrono::seconds(1);
    while (size != 0) {
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - Clock::now()).count();
        if (remaining <= 0) return false;
        pollfd pfd{fd, POLLOUT, 0};
        const int ready = poll(&pfd, 1, static_cast<int>(remaining));
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0 || (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)))
            return false;
        const ssize_t sent = send(fd, bytes, size, MSG_DONTWAIT | MSG_NOSIGNAL);
        if (sent < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (sent <= 0) return false;
        bytes += sent;
        size -= static_cast<std::size_t>(sent);
    }
    return true;
}
