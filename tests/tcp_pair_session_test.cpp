#include "client_pair.h"
#include "noise.h"
#include "tcp_pair_session.hpp"

#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <linux/input.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

static std::uint64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

static void send_bytes(int fd, const std::uint8_t *bytes, std::size_t size) {
    while (size) {
        const ssize_t sent = send(fd, bytes, size, 0);
        assert(sent > 0);
        size -= static_cast<std::size_t>(sent);
        bytes += sent;
    }
}

static std::size_t receive_record(int fd, std::uint8_t *out,
                                  std::size_t capacity) {
    assert(recv(fd, out, 2, MSG_WAITALL) == 2);
    const std::size_t size = 2 + out[0] + (std::size_t(out[1]) << 8);
    assert(size <= capacity);
    assert(recv(fd, out + 2, size - 2, MSG_WAITALL) ==
           static_cast<ssize_t>(size - 2));
    return size;
}

int main() {
    char directory[] = "/tmp/pltr-tcp-pair-XXXXXX";
    assert(mkdtemp(directory) != nullptr);
    PltrIdentityStore store{};
    assert(pltr_identity_store_open(&store, directory) == 0);
    PltrPairing pairing{};
    assert(pltr_pairing_init(&pairing, &store,
                             reinterpret_cast<const std::uint8_t *>("NUC"),
                             3) == 0);
    assert(pltr_pairing_open(&pairing, now_ms(), 0) == 0);
    std::uint8_t private_key[32] = {7}, public_key[32];
    assert(pltr_noise_public_key(private_key, public_key) == 0);
    const std::uint8_t code[] = "12345";
    PltrClientPair *client = pltr_client_pair_create(
        private_key, code, reinterpret_cast<const std::uint8_t *>("AVP"), 3, 2);
    assert(client != nullptr);
    int sockets[2], pad_pipe[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    assert(pipe(pad_pipe) == 0);
    PltrPad pad{};
    pad.fd = pad_pipe[0];
    int result = -2;
    std::thread server([&] {
        result = pltr_run_tcp_pair_session(sockets[1], pairing, pad, -1);
        close(sockets[1]);
    });
    std::uint8_t output[256], reply[256], relay_key[32] = {0};
    std::size_t output_size, reply_size, consumed;
    assert(pltr_client_pair_start(client, output, sizeof(output),
                                  &output_size) == 0);
    send_bytes(sockets[0], output, output_size);
    for (unsigned key = 0; key < 5; ++key) {
        input_event event{};
        event.type = EV_KEY;
        event.code = static_cast<std::uint16_t>(BTN_0 + key);
        event.value = 1;
        assert(write(pad_pipe[1], &event, sizeof(event)) ==
               static_cast<ssize_t>(sizeof(event)));
    }
    const std::size_t response_size = receive_record(sockets[0], output,
                                                       sizeof(output));
    assert(pltr_client_pair_receive(client, output, response_size,
                                    &consumed, reply, sizeof(reply),
                                    &reply_size, relay_key) == 1);
    assert(consumed == response_size && reply_size != 0);
    send_bytes(sockets[0], reply, reply_size);
    const std::size_t result_size = receive_record(sockets[0], output,
                                                     sizeof(output));
    assert(pltr_client_pair_receive(client, output, result_size,
                                    &consumed, reply, sizeof(reply),
                                    &reply_size, relay_key) == 2);
    assert(consumed == result_size &&
           std::memcmp(relay_key, store.public_key, 32) == 0);
    server.join();
    assert(result == 0 &&
           pltr_identity_store_approve(&store, public_key) == 1);
    close(sockets[0]);
    close(pad_pipe[0]);
    close(pad_pipe[1]);
    pltr_client_pair_destroy(client);
    pltr_pairing_clear(&pairing);
    pltr_identity_store_close(&store);
    for (const char *name : {"identity.key", "paired-clients.json", "store.lock"}) {
        char path[160];
        assert(std::snprintf(path, sizeof(path), "%s/%s", directory, name) <
               static_cast<int>(sizeof(path)));
        assert(unlink(path) == 0);
    }
    assert(rmdir(directory) == 0);
    return 0;
}
