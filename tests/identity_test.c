#define _POSIX_C_SOURCE 200809L
#include "identity.h"
#include "noise.h"

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void path(char *out, size_t capacity, const char *dir, const char *name) {
    assert(snprintf(out, capacity, "%s/%s", dir, name) < (int)capacity);
}

int main(void) {
    char directory[] = "/tmp/pltr-identity-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    PltrIdentityStore store, second;
    assert(pltr_identity_store_open(&store, directory) == 0);
    assert(store.client_count == 0);
    char identity[128], peers[128], lock[128], generations[128];
    path(identity, sizeof(identity), directory, "identity.key");
    path(peers, sizeof(peers), directory, "paired-clients.json");
    path(lock, sizeof(lock), directory, "store.lock");
    path(generations, sizeof(generations), directory, "tablet-generation.bin");
    struct stat st;
    assert(stat(identity, &st) == 0 && (st.st_mode & 0777) == 0600);
    assert(stat(peers, &st) == 0 && (st.st_mode & 0777) == 0600);
    uint16_t generation = 0;
    assert(pltr_identity_store_next_generation(&store, &generation) == 0 &&
           generation == 1);
    assert(pltr_identity_store_next_generation(&store, &generation) == 0 &&
           generation == 2);
    assert(stat(generations, &st) == 0 && (st.st_mode & 0777) == 0600);
    assert(pltr_identity_store_open(&second, directory) != 0);

    uint8_t client_private[32], client_public[32], original_relay[32];
    for (size_t i = 0; i < sizeof(client_private); ++i)
        client_private[i] = (uint8_t)(i + 5);
    assert(pltr_noise_public_key(client_private, client_public) == 0);
    memcpy(original_relay, store.public_key, 32);
    assert(pltr_identity_store_approve(&store, client_public) == 0);
    assert(pltr_identity_store_add(&store, client_public) == 0);
    assert(pltr_identity_store_add(&store, client_public) != 0);
    assert(pltr_identity_store_approve(&store, client_public) == 1);
    pltr_identity_store_close(&store);

    assert(pltr_identity_store_open(&store, directory) == 0);
    assert(pltr_identity_store_next_generation(&store, &generation) == 0 &&
           generation == 3);
    assert(chmod(generations, 0644) == 0);
    assert(pltr_identity_store_next_generation(&store, &generation) != 0);
    assert(chmod(generations, 0600) == 0);
    int generation_fd = open(generations, O_WRONLY | O_TRUNC);
    assert(generation_fd >= 0);
    const uint8_t malformed_generation[] = {3};
    assert(write(generation_fd, malformed_generation,
                 sizeof(malformed_generation)) == sizeof(malformed_generation));
    assert(close(generation_fd) == 0);
    assert(pltr_identity_store_next_generation(&store, &generation) != 0);
    generation_fd = open(generations, O_WRONLY | O_TRUNC);
    assert(generation_fd >= 0);
    const uint8_t last_generation[] = {0xff, 0xff};
    assert(write(generation_fd, last_generation,
                 sizeof(last_generation)) == sizeof(last_generation));
    assert(close(generation_fd) == 0);
    assert(pltr_identity_store_next_generation(&store, &generation) == 0 &&
           generation == 1);
    assert(unlink(generations) == 0);
    assert(symlink(identity, generations) == 0);
    assert(pltr_identity_store_next_generation(&store, &generation) != 0);
    assert(unlink(generations) == 0);
    assert(memcmp(original_relay, store.public_key, 32) == 0);
    assert(store.client_count == 1 &&
           pltr_identity_store_approve(&store, client_public) == 1);
    assert(pltr_identity_store_remove(&store, client_public) == 0);
    assert(pltr_identity_store_approve(&store, client_public) == 0);
    pltr_identity_store_close(&store);

    assert(chmod(peers, 0644) == 0);
    assert(pltr_identity_store_open(&store, directory) != 0);
    assert(chmod(peers, 0600) == 0);
    int fd = open(peers, O_WRONLY | O_TRUNC);
    assert(fd >= 0);
    const char malformed[] = "{\"version\":1,\"clients\":[,]}";
    assert(write(fd, malformed, sizeof(malformed) - 1) == sizeof(malformed) - 1);
    assert(close(fd) == 0);
    assert(pltr_identity_store_open(&store, directory) != 0);

    assert(unlink(peers) == 0);
    assert(symlink(identity, peers) == 0);
    assert(pltr_identity_store_open(&store, directory) != 0);
    assert(unlink(peers) == 0);
    assert(unlink(identity) == 0);
    assert(unlink(lock) == 0);
    assert(rmdir(directory) == 0);
    return 0;
}
