#include "identity.h"
#include "pad.h"
#include "pair_budget.h"
#include "pairing.h"
#include "protocol.h"
#include "tcp_pair_session.hpp"
#include "tcp_session.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {
volatile sig_atomic_t stopping = 0;
int signal_write_fd = -1;

void stop_signal(int) {
    stopping = 1;
    if (signal_write_fd >= 0) {
        const std::uint8_t byte = 1;
        (void)write(signal_write_fd, &byte, 1);
    }
}

bool inspect_open(int fd, std::uint8_t &mode) {
    timeval deadline{5, 0};
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                   &deadline, sizeof(deadline)) != 0) return false;
    std::uint8_t record[2 + PLTR_HEADER_SIZE + 1]{};
    const ssize_t size = recv(fd, record, sizeof(record),
                               MSG_PEEK | MSG_WAITALL);
    deadline = {0, 0};
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                      &deadline, sizeof(deadline));
    PltrFrame frame{};
    if (size != static_cast<ssize_t>(sizeof(record)) ||
        pltr_decode_record(record, sizeof(record), PLTR_CLIENT_TO_RELAY,
                            PLTR_PRE_AUTH, 1, &frame) != 0 ||
        frame.type != PLTR_OPEN) return false;
    mode = frame.payload[0];
    return true;
}

int listener(const char *address, std::uint16_t port) {
    sockaddr_in target{};
    target.sin_family = AF_INET;
    target.sin_port = htons(port);
    if (inet_pton(AF_INET, address, &target.sin_addr) != 1) return -1;
    const int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    const int enabled = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
    if (bind(fd, reinterpret_cast<sockaddr *>(&target), sizeof(target)) != 0 ||
        listen(fd, 1) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

void usage() {
    std::fprintf(stderr,
                 "Usage: plank-tablet-relay serve|pair --state-dir DIR "
                 "[--bind IPv4] [--port 1..65535]\n"
                 "Defaults: bind 127.0.0.1, port 28990. Pairing reads the "
                 "USB PTH-660 Pad.\n");
}
} // namespace

int main(int argc, char **argv) {
    if (argc < 4) {
        usage();
        return 2;
    }
    const bool pairing_mode = std::strcmp(argv[1], "pair") == 0;
    if (!pairing_mode && std::strcmp(argv[1], "serve") != 0) {
        usage();
        return 2;
    }
    const char *state_dir = nullptr;
    const char *bind_address = "127.0.0.1";
    std::uint16_t port = 28990;
    for (int i = 2; i < argc; i += 2) {
        if (i + 1 >= argc) {
            usage();
            return 2;
        }
        if (std::strcmp(argv[i], "--state-dir") == 0) {
            state_dir = argv[i + 1];
        } else if (std::strcmp(argv[i], "--bind") == 0) {
            bind_address = argv[i + 1];
        } else if (std::strcmp(argv[i], "--port") == 0) {
            char *end = nullptr;
            errno = 0;
            const unsigned long value = std::strtoul(argv[i + 1], &end, 10);
            if (errno != 0 || end == argv[i + 1] || *end != '\0' ||
                value == 0 || value > UINT16_MAX) {
                usage();
                return 2;
            }
            port = static_cast<std::uint16_t>(value);
        } else {
            usage();
            return 2;
        }
    }
    if (state_dir == nullptr) {
        usage();
        return 2;
    }
    PltrIdentityStore store{};
    if (pltr_identity_store_open(&store, state_dir) != 0) {
        std::fputs("Relay identity store unavailable or unsafe\n", stderr);
        return 1;
    }
    PltrPad pad{};
    PltrPairing pairing{};
    if (pairing_mode) {
        if (pltr_pad_open(&pad, 0x056a, 0x0357) != 0 ||
            pltr_pairing_init(&pairing, &store,
                              reinterpret_cast<const std::uint8_t *>("NUC"),
                              3) != 0) {
            std::fputs("Wacom Pad unavailable for pairing\n", stderr);
            pltr_pad_close(&pad);
            pltr_identity_store_close(&store);
            return 1;
        }
    }
    const int server = listener(bind_address, port);
    int signal_pipe[2];
    if (server < 0 || pipe2(signal_pipe, O_CLOEXEC | O_NONBLOCK) != 0) {
        std::fputs("Relay listener could not start\n", stderr);
        if (server >= 0) close(server);
        if (pairing_mode) {
            pltr_pairing_clear(&pairing);
            pltr_pad_close(&pad);
        }
        pltr_identity_store_close(&store);
        return 1;
    }
    signal_write_fd = signal_pipe[1];
    struct sigaction action{};
    action.sa_handler = stop_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, nullptr);
    sigaction(SIGTERM, &action, nullptr);
    if (pairing_mode) {
        const std::time_t wall_now = std::time(nullptr);
        const auto monotonic_now = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        if (wall_now < 0 ||
            pltr_pair_budget_reserve(&store,
                static_cast<std::uint64_t>(wall_now)) != 0 ||
            pltr_pairing_open(&pairing, monotonic_now, 0) != 0) {
            std::fputs("Pairing unavailable or locked; no window opened\n", stderr);
            stopping = 1;
        }
    }
    if (!stopping) {
        std::printf("Relay %s listening on %s:%u\n",
                     pairing_mode ? "pairing" : "session", bind_address, port);
        std::fflush(stdout);
    }
    int result = pairing_mode ? 1 : 0;
    while (!stopping) {
        if (pairing_mode) {
            const auto now = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count());
            if (pltr_pairing_tick(&pairing, now) < 0 ||
                pairing.stage != PLTR_PAIR_WINDOW) break;
        }
        pollfd fds[2] = {{server, POLLIN, 0}, {signal_pipe[0], POLLIN, 0}};
        const int ready = poll(fds, 2, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || fds[1].revents != 0) break;
        if (!(fds[0].revents & POLLIN)) continue;
        const int client = accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
        if (client < 0) continue;
        const int enabled = 1;
        (void)setsockopt(client, IPPROTO_TCP, TCP_NODELAY,
                         &enabled, sizeof(enabled));
        const int dscp_ef = 46 << 2;
        (void)setsockopt(client, IPPROTO_IP, IP_TOS,
                         &dscp_ef, sizeof(dscp_ef));
        std::uint8_t mode = 0;
        if (inspect_open(client, mode) &&
            ((pairing_mode && mode == 2) || (!pairing_mode && mode == 1))) {
            const int session_result = pairing_mode ?
                pltr_run_tcp_pair_session(client, pairing, pad, signal_pipe[0]) :
                pltr_run_tcp_session(client, store, signal_pipe[0]);
            if (pairing_mode) {
                result = session_result == 0 ? 0 : 1;
                if (result == 0 && pltr_pair_budget_succeeded(&store) != 0) {
                    std::fputs("Pairing succeeded but budget reset failed\n", stderr);
                    result = 1;
                }
                close(client);
                break;
            }
        }
        close(client);
    }
    close(server);
    close(signal_pipe[0]);
    close(signal_pipe[1]);
    signal_write_fd = -1;
    if (pairing_mode) {
        pltr_pairing_clear(&pairing);
        pltr_pad_close(&pad);
    }
    pltr_identity_store_close(&store);
    return result;
}
