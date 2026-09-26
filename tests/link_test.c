#include "link.h"
#include "identity.h"
#include "../vendor/plank-client/plank.h"

#include <arpa/inet.h>
#include <assert.h>
#include <sodium.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

static void le32(uint8_t *p, uint32_t v) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(v >> (8 * i));
}

static void tcp_pair(int *client_fd, int *relay_fd) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 1) == 0);
    socklen_t length = sizeof(address);
    assert(getsockname(listener, (struct sockaddr *)&address, &length) == 0);
    *client_fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(*client_fd >= 0);
    assert(connect(*client_fd, (struct sockaddr *)&address, length) == 0);
    *relay_fd = accept(listener, NULL, NULL);
    assert(*relay_fd >= 0);
    close(listener);
}

// Send on a real loopback TCP connection, receive one byte at a time to
// exercise record fragmentation, and collect any synchronous reply records.
static int transfer(int sender_fd, int receiver_fd, PltrLink *receiver,
                    const uint8_t *bytes, size_t size,
                    uint8_t *response, size_t response_capacity,
                    size_t *response_size, uint16_t *frame_type) {
    *response_size = 0;
    *frame_type = 0;
    size_t sent = 0;
    while (sent < size) {
        ssize_t n = send(sender_fd, bytes + sent, size - sent, 0);
        assert(n > 0);
        sent += (size_t)n;
    }
    for (size_t i = 0; i < size; ++i) {
        uint8_t byte;
        assert(recv(receiver_fd, &byte, 1, MSG_WAITALL) == 1);
        size_t consumed = 0, reply_size = 0;
        PltrFrame frame;
        int result = pltr_link_receive(receiver, &byte, 1, &consumed,
                                        response + *response_size,
                                        response_capacity - *response_size,
                                        &reply_size, &frame);
        assert(consumed == 1);
        if (result < 0) return -1;
        assert(result == 0 || result == 1);
        assert(reply_size <= response_capacity - *response_size);
        *response_size += reply_size;
        if (frame.type) *frame_type = frame.type;
    }
    return 0;
}

static void init_pair(PltrLink *client, PltrLink *relay,
                      const uint8_t client_private[32],
                      const uint8_t relay_private[32],
                      PltrIdentityStore *store,
                      uint8_t client_link_type) {
    uint8_t relay_public[32];
    assert(pltr_noise_public_key(relay_private, relay_public) == 0);
    assert(pltr_link_init(client, PLTR_NOISE_INITIATOR, client_private,
                          relay_public, NULL, NULL, client_link_type) == 0);
    assert(pltr_link_init(relay, PLTR_NOISE_RESPONDER, relay_private,
                          NULL, pltr_identity_store_approve, store, 2) == 0);
}

static void handshake(PltrLink *client, PltrLink *relay,
                      int client_fd, int relay_fd) {
    uint8_t start[256], relay_reply[256], client_reply[256], unused[256];
    size_t start_size, relay_size, client_size, unused_size;
    uint16_t type;
    assert(pltr_link_start(client, start, sizeof(start), &start_size) == 0);
    assert(transfer(client_fd, relay_fd, relay, start, start_size,
                    relay_reply, sizeof(relay_reply), &relay_size, &type) == 0);
    assert(type == 0 && relay_size != 0);
    assert(transfer(relay_fd, client_fd, client, relay_reply, relay_size,
                    client_reply, sizeof(client_reply), &client_size, &type) == 0);
    assert(type == 0 && client_size != 0);
    assert(transfer(client_fd, relay_fd, relay, client_reply, client_size,
                    unused, sizeof(unused), &unused_size, &type) == 0);
    assert(type == 0 && unused_size == 0);
    assert(client->stage == PLTR_LINK_READY && relay->stage == PLTR_LINK_READY);
    assert(relay->relay_session.stage == PLTR_RELAY_WAIT_READY);
}

int main(void) {
    assert(sodium_init() >= 0);
    uint8_t client_private[32], relay_private[32], client_public[32];
    crypto_box_keypair(client_public, client_private);
    char directory[] = "/tmp/pltr-link-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    PltrIdentityStore store;
    assert(pltr_identity_store_open(&store, directory) == 0);
    memcpy(relay_private, store.private_key, 32);
    assert(pltr_identity_store_add(&store, client_public) == 0);

    PltrLink client, relay;
    int client_fd, relay_fd;
    tcp_pair(&client_fd, &relay_fd);
    init_pair(&client, &relay, client_private, relay_private, &store, 2);
    handshake(&client, &relay, client_fd, relay_fd);

    uint8_t record[256], reply[256];
    size_t record_size, reply_size;
    uint16_t type;
    uint8_t status[8] = {1, 0x6a, 0x05, 0x57, 0x03, 1, 1, 0};
    assert(pltr_link_send(&relay, PLTR_CLIENT_FRAME, status, sizeof(status),
                          record, sizeof(record), &record_size) != 0);
    assert(pltr_link_send(&relay, PLTR_STATUS, status, sizeof(status),
                          record, sizeof(record), &record_size) == 0);
    assert(transfer(relay_fd, client_fd, &client, record, record_size,
                    reply, sizeof(reply), &reply_size, &type) == 0);
    assert(type == PLTR_STATUS && reply_size == 0);

    uint8_t ready[5] = {0};
    le32(ready, 0x24);
    ready[4] = 1;
    assert(pltr_link_send(&client, PLTR_SESSION_READY, ready, sizeof(ready),
                          record, sizeof(record), &record_size) == 0);
    assert(transfer(client_fd, relay_fd, &relay, record, record_size,
                    reply, sizeof(reply), &reply_size, &type) == 0);
    assert(type == PLTR_SESSION_READY);
    assert(relay.relay_session.stage == PLTR_RELAY_READY);

    uint8_t tablet[8 + sizeof(PLANK_RAW_HID_WIRE_HEADER)] = {0};
    le32(tablet + 8, PLANK_RAW_HID_WIRE_MAGIC);
    le16(tablet + 12, PLANK_RAW_HID_WIRE_VERSION);
    le16(tablet + 14, PLANK_RAW_HID_SUSPEND);
    assert(pltr_link_send(&relay, PLTR_CLIENT_FRAME, tablet, sizeof(tablet),
                          record, sizeof(record), &record_size) == 0);
    assert(transfer(relay_fd, client_fd, &client, record, record_size,
                    reply, sizeof(reply), &reply_size, &type) == 0);
    assert(type == PLTR_CLIENT_FRAME);

    assert(pltr_link_send(&relay, PLTR_STATUS, status, sizeof(status),
                          record, sizeof(record), &record_size) == 0);
    record[record_size - 1] ^= 1;
    assert(transfer(relay_fd, client_fd, &client, record, record_size,
                    reply, sizeof(reply), &reply_size, &type) == -1);
    assert(client.stage == PLTR_LINK_FAILED);
    pltr_link_clear(&client);
    pltr_link_clear(&relay);
    close(client_fd);
    close(relay_fd);

    // A clean session end is terminal at both ends.
    tcp_pair(&client_fd, &relay_fd);
    init_pair(&client, &relay, client_private, relay_private, &store, 2);
    handshake(&client, &relay, client_fd, relay_fd);
    const uint8_t end_reason[] = {2};
    assert(pltr_link_send(&client, PLTR_SESSION_END, end_reason,
                          sizeof(end_reason), record, sizeof(record),
                          &record_size) == 0);
    assert(client.stage == PLTR_LINK_CLOSED);
    assert(transfer(client_fd, relay_fd, &relay, record, record_size,
                    reply, sizeof(reply), &reply_size, &type) == 0);
    assert(type == PLTR_SESSION_END && relay.stage == PLTR_LINK_CLOSED);
    assert(pltr_link_send(&relay, PLTR_STATUS, status, sizeof(status),
                          record, sizeof(record), &record_size) != 0);
    pltr_link_clear(&client);
    pltr_link_clear(&relay);
    close(client_fd);
    close(relay_fd);

    // An unpaired Client cannot obtain the Relay's Noise response.
    assert(pltr_identity_store_remove(&store, client_public) == 0);
    tcp_pair(&client_fd, &relay_fd);
    init_pair(&client, &relay, client_private, relay_private, &store, 2);
    uint8_t start[256];
    size_t start_size;
    assert(pltr_link_start(&client, start, sizeof(start), &start_size) == 0);
    assert(transfer(client_fd, relay_fd, &relay, start, start_size,
                    reply, sizeof(reply), &reply_size, &type) == -1);
    assert(relay.stage == PLTR_LINK_FAILED && reply_size == 0);
    pltr_link_clear(&client);
    pltr_link_clear(&relay);
    close(client_fd);
    close(relay_fd);

    // The Noise prologue binds the channel type, even with trusted keys.
    assert(pltr_identity_store_add(&store, client_public) == 0);
    tcp_pair(&client_fd, &relay_fd);
    init_pair(&client, &relay, client_private, relay_private, &store, 1);
    assert(pltr_link_start(&client, start, sizeof(start), &start_size) == 0);
    assert(transfer(client_fd, relay_fd, &relay, start, start_size,
                    reply, sizeof(reply), &reply_size, &type) == -1);
    assert(relay.stage == PLTR_LINK_FAILED && reply_size == 0);
    pltr_link_clear(&client);
    pltr_link_clear(&relay);
    close(client_fd);
    close(relay_fd);
    pltr_identity_store_close(&store);
    char filename[128];
    assert(snprintf(filename, sizeof(filename), "%s/identity.key", directory) < (int)sizeof(filename));
    assert(unlink(filename) == 0);
    assert(snprintf(filename, sizeof(filename), "%s/paired-clients.json", directory) < (int)sizeof(filename));
    assert(unlink(filename) == 0);
    assert(snprintf(filename, sizeof(filename), "%s/store.lock", directory) < (int)sizeof(filename));
    assert(unlink(filename) == 0);
    assert(rmdir(directory) == 0);
    return 0;
}
