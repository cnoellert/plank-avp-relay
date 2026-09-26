#ifndef PLANK_RELAY_IDENTITY_H
#define PLANK_RELAY_IDENTITY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PLTR_MAX_PAIRED_CLIENTS 16u

typedef struct PltrIdentityStore {
    int directory_fd;
    int lock_fd;
    uint8_t private_key[32];
    uint8_t public_key[32];
    uint8_t client_keys[PLTR_MAX_PAIRED_CLIENTS][32];
    size_t client_count;
} PltrIdentityStore;

// The directory must already exist, be owned by this process and mode 0700.
// It is locked for the lifetime of the store. Identity and allowlist files
// are mode 0600; malformed or permissive existing files fail closed.
int pltr_identity_store_open(PltrIdentityStore *store, const char *directory);
void pltr_identity_store_close(PltrIdentityStore *store);
int pltr_identity_store_approve(void *context, const uint8_t public_key[32]);
int pltr_identity_store_add(PltrIdentityStore *store,
                            const uint8_t public_key[32]);
int pltr_identity_store_remove(PltrIdentityStore *store,
                               const uint8_t public_key[32]);
// Reserve a nonzero raw-HID attachment generation durably before the worker
// sends DEVICE. The store's lifetime lock serializes reservations across runs.
int pltr_identity_store_next_generation(PltrIdentityStore *store,
                                        uint16_t *generation);

#ifdef __cplusplus
}
#endif

#endif
