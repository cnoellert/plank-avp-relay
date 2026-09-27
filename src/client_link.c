#include "client_link.h"
#include "link.h"

#include <sodium.h>
#include <stdlib.h>
#include <string.h>

struct PltrClientLink {
    PltrLink link;
};

PltrClientLink *pltr_client_link_create(const uint8_t client_private_key[32],
                                        const uint8_t relay_public_key[32],
                                        uint8_t link_type) {
    if (client_private_key == NULL || relay_public_key == NULL) return NULL;
    PltrClientLink *client = calloc(1, sizeof(*client));
    if (client == NULL) return NULL;
    if (pltr_link_init(&client->link, PLTR_NOISE_INITIATOR,
                       client_private_key, relay_public_key,
                       NULL, NULL, link_type) != 0) {
        pltr_client_link_destroy(client);
        return NULL;
    }
    return client;
}

void pltr_client_link_destroy(PltrClientLink *client) {
    if (client == NULL) return;
    pltr_link_clear(&client->link);
    sodium_memzero(client, sizeof(*client));
    free(client);
}

int pltr_client_link_enable_input_observer(PltrClientLink *client) {
    return client ? pltr_link_enable_input_observer(&client->link) : -1;
}

int pltr_client_link_start(PltrClientLink *client, uint8_t *out,
                           size_t capacity, size_t *written) {
    if (client == NULL) return -1;
    return pltr_link_start(&client->link, out, capacity, written);
}

int pltr_client_link_receive(PltrClientLink *client, const uint8_t *bytes,
                             size_t size, size_t *consumed,
                             uint8_t *reply, size_t reply_capacity,
                             size_t *reply_size, uint16_t *type,
                             uint8_t *payload, size_t payload_capacity,
                             size_t *payload_size) {
    if (client == NULL || consumed == NULL || type == NULL ||
        payload_size == NULL || (payload == NULL && payload_capacity != 0))
        return -1;
    *type = 0;
    *payload_size = 0;
    PltrFrame frame;
    const int result = pltr_link_receive(&client->link, bytes, size,
                                         consumed, reply, reply_capacity,
                                         reply_size, &frame);
    if (result != 1 || frame.type == 0) return result;
    if (frame.payload_size > payload_capacity || payload == NULL) return -1;
    if (frame.payload_size != 0)
        memcpy(payload, frame.payload, frame.payload_size);
    *type = frame.type;
    *payload_size = frame.payload_size;
    return result;
}

int pltr_client_link_send(PltrClientLink *client, uint16_t type,
                          const uint8_t *payload, size_t payload_size,
                          uint8_t *out, size_t capacity, size_t *written) {
    if (client == NULL) return -1;
    return pltr_link_send(&client->link, type, payload, payload_size,
                          out, capacity, written);
}

const char *pltr_client_link_peer_version(const PltrClientLink *client) {
    if (client == NULL || client->link.stage != PLTR_LINK_READY) return NULL;
    return client->link.peer_version;
}
