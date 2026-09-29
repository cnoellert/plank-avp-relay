#define _POSIX_C_SOURCE 200809L
#include "identity.h"
#include "noise.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <sodium.h>

#define STORE_NAME "paired-clients.json"
#define IDENTITY_NAME "identity.key"
#define LOCK_NAME "store.lock"
#define GENERATION_NAME "tablet-generation.bin"
#define STORE_LIMIT 2048u

static int secure_file(int fd) {
    struct stat st;
    return fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
           st.st_uid == geteuid() && (st.st_mode & 0777) == 0600 &&
           st.st_nlink == 1;
}

static int write_all(int fd, const uint8_t *bytes, size_t size) {
    while (size) {
        ssize_t n = write(fd, bytes, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        bytes += n;
        size -= (size_t)n;
    }
    return 0;
}

static int atomic_save(int dirfd, const char *name,
                       const uint8_t *bytes, size_t size) {
    char temporary[40];
    uint8_t salt[8];
    randombytes_buf(salt, sizeof(salt));
    snprintf(temporary, sizeof(temporary), ".pltr-%02x%02x%02x%02x%02x%02x%02x%02x",
             salt[0], salt[1], salt[2], salt[3],
             salt[4], salt[5], salt[6], salt[7]);
    int fd = openat(dirfd, temporary,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    int result = write_all(fd, bytes, size);
    if (result == 0 && fsync(fd) != 0) result = -1;
    if (close(fd) != 0) result = -1;
    if (result == 0 && renameat(dirfd, temporary, dirfd, name) != 0) result = -1;
    if (result == 0 && fsync(dirfd) != 0) result = -1;
    if (result != 0) unlinkat(dirfd, temporary, 0);
    return result;
}

static int read_file(int dirfd, const char *name, uint8_t *bytes,
                     size_t capacity, size_t *size) {
    int fd = openat(dirfd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    int result = -1;
    struct stat st;
    if (secure_file(fd) && fstat(fd, &st) == 0 &&
        st.st_size >= 0 && (uint64_t)st.st_size <= capacity) {
        size_t got = 0;
        while (got < (size_t)st.st_size) {
            ssize_t n = read(fd, bytes + got, (size_t)st.st_size - got);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            got += (size_t)n;
        }
        uint8_t extra;
        if (got == (size_t)st.st_size && read(fd, &extra, 1) == 0) {
            *size = got;
            result = 0;
        }
    }
    close(fd);
    return result;
}

static int hex_digit(uint8_t c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static int parse_store(PltrIdentityStore *store,
                       const uint8_t *bytes, size_t size) {
    const char prefix[] = "{\"version\":1,\"clients\":[";
    const size_t prefix_size = sizeof(prefix) - 1;
    if (size < prefix_size + 2 ||
        memcmp(bytes, prefix, prefix_size) != 0) return -1;
    size_t at = prefix_size;
    store->client_count = 0;
    while (at < size && bytes[at] != ']') {
        if (store->client_count == PLTR_MAX_PAIRED_CLIENTS ||
            bytes[at++] != '"' || size - at < 65) return -1;
        uint8_t *key = store->client_keys[store->client_count];
        for (size_t i = 0; i < 32; ++i) {
            int hi = hex_digit(bytes[at++]);
            int lo = hex_digit(bytes[at++]);
            if (hi < 0 || lo < 0) return -1;
            key[i] = (uint8_t)((hi << 4) | lo);
        }
        if (bytes[at++] != '"') return -1;
        for (size_t i = 0; i < store->client_count; ++i)
            if (sodium_memcmp(store->client_keys[i], key, 32) == 0) return -1;
        ++store->client_count;
        if (at < size && bytes[at] == ',') {
            ++at;
            if (at >= size || bytes[at] == ']') return -1;
        }
        else if (at >= size || bytes[at] != ']') return -1;
    }
    return at + 2 == size && bytes[at] == ']' && bytes[at + 1] == '}' ? 0 : -1;
}

static int save_clients(PltrIdentityStore *store,
                        const uint8_t keys[PLTR_MAX_PAIRED_CLIENTS][32],
                        size_t count) {
    static const char hex[] = "0123456789abcdef";
    uint8_t bytes[STORE_LIMIT];
    const char prefix[] = "{\"version\":1,\"clients\":[";
    size_t at = sizeof(prefix) - 1;
    memcpy(bytes, prefix, at);
    for (size_t i = 0; i < count; ++i) {
        if (i) bytes[at++] = ',';
        bytes[at++] = '"';
        for (size_t j = 0; j < 32; ++j) {
            bytes[at++] = hex[keys[i][j] >> 4];
            bytes[at++] = hex[keys[i][j] & 15];
        }
        bytes[at++] = '"';
    }
    bytes[at++] = ']';
    bytes[at++] = '}';
    if (at > sizeof(bytes)) return -1;
    return atomic_save(store->directory_fd, STORE_NAME, bytes, at);
}

int pltr_identity_store_open(PltrIdentityStore *store, const char *directory) {
    if (store == NULL || directory == NULL || sodium_init() < 0) return -1;
    memset(store, 0, sizeof(*store));
    store->directory_fd = store->lock_fd = -1;
    int dirfd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (dirfd < 0) return -1;
    struct stat st;
    if (fstat(dirfd, &st) != 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != geteuid() || (st.st_mode & 0777) != 0700) {
        close(dirfd);
        return -1;
    }
    store->directory_fd = dirfd;
    store->lock_fd = openat(dirfd, LOCK_NAME,
                            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (store->lock_fd < 0 || !secure_file(store->lock_fd) ||
        flock(store->lock_fd, LOCK_EX | LOCK_NB) != 0) goto error;

    size_t size;
    if (read_file(dirfd, IDENTITY_NAME, store->private_key,
                  sizeof(store->private_key), &size) != 0) {
        if (faccessat(dirfd, IDENTITY_NAME, F_OK, AT_SYMLINK_NOFOLLOW) == 0 ||
            errno != ENOENT) goto error;
        randombytes_buf(store->private_key, sizeof(store->private_key));
        if (atomic_save(dirfd, IDENTITY_NAME, store->private_key,
                        sizeof(store->private_key)) != 0) goto error;
        size = sizeof(store->private_key);
    }
    if (size != sizeof(store->private_key) ||
        pltr_noise_public_key(store->private_key, store->public_key) != 0)
        goto error;

    uint8_t json[STORE_LIMIT];
    if (read_file(dirfd, STORE_NAME, json, sizeof(json), &size) == 0) {
        if (parse_store(store, json, size) != 0) goto error;
    } else {
        if (faccessat(dirfd, STORE_NAME, F_OK, AT_SYMLINK_NOFOLLOW) == 0 ||
            errno != ENOENT || save_clients(store, store->client_keys, 0) != 0)
            goto error;
    }
    return 0;
error:
    pltr_identity_store_close(store);
    return -1;
}

void pltr_identity_store_close(PltrIdentityStore *store) {
    if (store == NULL) return;
    if (store->lock_fd >= 0) close(store->lock_fd);
    if (store->directory_fd >= 0) close(store->directory_fd);
    sodium_memzero(store, sizeof(*store));
    store->directory_fd = store->lock_fd = -1;
}

int pltr_identity_store_approve(void *context, const uint8_t public_key[32]) {
    PltrIdentityStore *store = context;
    if (store == NULL || public_key == NULL || store->directory_fd < 0) return 0;
    int found = 0;
    for (size_t i = 0; i < store->client_count; ++i)
        found |= sodium_memcmp(store->client_keys[i], public_key, 32) == 0;
    return found;
}

int pltr_identity_store_add(PltrIdentityStore *store,
                            const uint8_t public_key[32]) {
    if (store == NULL || public_key == NULL || store->directory_fd < 0 ||
        store->client_count >= PLTR_MAX_PAIRED_CLIENTS ||
        pltr_identity_store_approve(store, public_key)) return -1;
    uint8_t keys[PLTR_MAX_PAIRED_CLIENTS][32];
    memcpy(keys, store->client_keys, sizeof(keys));
    memcpy(keys[store->client_count], public_key, 32);
    int result = save_clients(store, keys, store->client_count + 1);
    sodium_memzero(keys, sizeof(keys));
    if (result != 0) return -1;
    memcpy(store->client_keys[store->client_count++], public_key, 32);
    return 0;
}

int pltr_identity_store_clear_clients(PltrIdentityStore *store) {
    if (!store || store->directory_fd < 0 || store->lock_fd < 0) return -1;
    if (save_clients(store, store->client_keys, 0) != 0) return -1;
    sodium_memzero(store->client_keys, sizeof(store->client_keys));
    store->client_count = 0;
    return 0;
}

int pltr_identity_store_remove(PltrIdentityStore *store,
                               const uint8_t public_key[32]) {
    if (store == NULL || public_key == NULL || store->directory_fd < 0) return -1;
    uint8_t keys[PLTR_MAX_PAIRED_CLIENTS][32];
    size_t count = 0;
    int found = 0;
    for (size_t i = 0; i < store->client_count; ++i) {
        if (sodium_memcmp(store->client_keys[i], public_key, 32) == 0)
            found = 1;
        else memcpy(keys[count++], store->client_keys[i], 32);
    }
    if (!found) return -1;
    int result = save_clients(store, keys, count);
    if (result == 0) {
        sodium_memzero(store->client_keys, sizeof(store->client_keys));
        memcpy(store->client_keys, keys, count * 32);
        store->client_count = count;
    }
    sodium_memzero(keys, sizeof(keys));
    return result;
}

int pltr_identity_store_next_generation(PltrIdentityStore *store,
                                        uint16_t *generation) {
    if (store == NULL || generation == NULL || store->directory_fd < 0 ||
        store->lock_fd < 0) return -1;
    uint8_t bytes[2];
    size_t size = 0;
    uint16_t previous = 0;
    if (read_file(store->directory_fd, GENERATION_NAME,
                  bytes, sizeof(bytes), &size) == 0) {
        if (size != sizeof(bytes)) return -1;
        previous = (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
    } else if (faccessat(store->directory_fd, GENERATION_NAME, F_OK,
                         AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
        return -1;
    }
    uint16_t next = (uint16_t)(previous + 1);
    if (next == 0) next = 1;
    bytes[0] = (uint8_t)next;
    bytes[1] = (uint8_t)(next >> 8);
    if (atomic_save(store->directory_fd, GENERATION_NAME,
                    bytes, sizeof(bytes)) != 0) return -1;
    *generation = next;
    return 0;
}
