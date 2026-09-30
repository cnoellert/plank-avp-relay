// SPDX-License-Identifier: GPL-3.0-or-later
#include <stdint.h>
#include <stddef.h>
typedef struct ManagementPeer ManagementPeer;
ManagementPeer *management_peer_create(const uint8_t *client_private, uint8_t *relay_public);
int management_peer_receive(ManagementPeer *, const uint8_t *, size_t, uint8_t *, size_t, size_t *);
unsigned management_peer_requests(ManagementPeer *);
void management_peer_destroy(ManagementPeer *);
