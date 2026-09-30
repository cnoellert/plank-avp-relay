// SPDX-License-Identifier: GPL-3.0-or-later
// A real encrypted relay responder for the Swift management-session tests.
#include "ManagementPeer.h"
#include "link.h"
#include <stdlib.h>
#include <string.h>
struct ManagementPeer { PltrLink link; uint8_t client[32]; unsigned requests; };
static int approve(void *context, const uint8_t *key) {
    return memcmp(((ManagementPeer *) context)->client, key, 32) == 0;
}
ManagementPeer *management_peer_create(const uint8_t *client_private, uint8_t *relay_public) {
    ManagementPeer *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    uint8_t secret[32]; memset(secret, 72, sizeof(secret));
    if (pltr_noise_public_key(client_private, p->client) ||
        pltr_noise_public_key(secret, relay_public) ||
        pltr_link_init(&p->link, PLTR_NOISE_RESPONDER, secret, NULL, approve, p, 2) ||
        pltr_link_enable_tablet_management(&p->link)) { free(p); return NULL; }
    return p;
}
int management_peer_receive(ManagementPeer *p, const uint8_t *data, size_t size,
                            uint8_t *out, size_t capacity, size_t *written) {
    *written = 0;
    while (size) {
        size_t used = 0, reply = 0; PltrFrame frame;
        if (pltr_link_receive(&p->link, data, size, &used, out + *written,
            capacity - *written, &reply, &frame) < 0 || !used) return -1;
        data += used; size -= used; *written += reply;
        if (frame.type == PLTR_TABLET_REQUEST) {
            p->requests++;
            if (pltr_link_send(&p->link, PLTR_TABLET_RESPONSE, frame.payload, frame.payload_size,
                out + *written, capacity - *written, &reply)) return -1;
            *written += reply;
        }
    }
    return 0;
}
unsigned management_peer_requests(ManagementPeer *p) { return p->requests; }
void management_peer_destroy(ManagementPeer *p) { pltr_link_clear(&p->link); free(p); }
