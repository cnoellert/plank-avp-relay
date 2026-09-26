#define _POSIX_C_SOURCE 200809L
#include "pair_budget.h"

#include <errno.h>
#include <fcntl.h>
#include <sodium.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BUDGET_NAME "pair-budget"
#define LOCKOUT_SECONDS 600u

typedef struct PairBudget {
    unsigned used;
    uint64_t until;
} PairBudget;

static int load(PltrIdentityStore *store, PairBudget *state) {
    if (store == NULL || store->directory_fd < 0 || state == NULL) return -1;
    memset(state, 0, sizeof(*state));
    int fd = openat(store->directory_fd, BUDGET_NAME,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    struct stat statbuf;
    char bytes[64] = {0};
    if (fstat(fd, &statbuf) != 0 || !S_ISREG(statbuf.st_mode) ||
        statbuf.st_uid != geteuid() || statbuf.st_nlink != 1 ||
        (statbuf.st_mode & 0777) != 0600 ||
        statbuf.st_size <= 0 || statbuf.st_size >= (off_t)sizeof(bytes)) {
        close(fd);
        return -1;
    }
    const ssize_t size = read(fd, bytes, sizeof(bytes) - 1);
    const int close_result = close(fd);
    if (size != statbuf.st_size || close_result != 0) return -1;
    unsigned version = 0, used = 0;
    unsigned long long until = 0;
    char extra = 0;
    if (sscanf(bytes, "v%u %u %llu %c", &version, &used, &until, &extra) != 3 ||
        version != 1 || used > 3 ||
        (used < 3 && until != 0) || (used == 3 && until == 0)) return -1;
    char canonical[64];
    const int expected = snprintf(canonical, sizeof(canonical),
                                  "v1 %u %llu\n", used, until);
    if (expected != size || memcmp(bytes, canonical, size) != 0) return -1;
    state->used = used;
    state->until = until;
    return 0;
}

static int save(PltrIdentityStore *store, const PairBudget *state) {
    if (store == NULL || store->directory_fd < 0 || state == NULL ||
        sodium_init() < 0) return -1;
    char contents[64];
    const int length = snprintf(contents, sizeof(contents), "v1 %u %llu\n",
                                state->used,
                                (unsigned long long)state->until);
    if (length < 0 || length >= (int)sizeof(contents)) return -1;
    uint8_t random[8];
    randombytes_buf(random, sizeof(random));
    char temporary[48];
    const int name_length = snprintf(temporary, sizeof(temporary),
        "pair-budget.%02x%02x%02x%02x%02x%02x%02x%02x.tmp",
        random[0], random[1], random[2], random[3],
        random[4], random[5], random[6], random[7]);
    if (name_length < 0 || name_length >= (int)sizeof(temporary)) return -1;
    const int fd = openat(store->directory_fd, temporary,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          0600);
    if (fd < 0) return -1;
    int result = 0;
    int offset = 0;
    while (offset < length) {
        const ssize_t written = write(fd, contents + offset, length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            result = -1;
            break;
        }
        offset += (int)written;
    }
    if (result == 0 && fsync(fd) != 0) result = -1;
    if (close(fd) != 0) result = -1;
    if (result == 0 &&
        renameat(store->directory_fd, temporary,
                  store->directory_fd, BUDGET_NAME) != 0)
        result = -1;
    if (result == 0 && fsync(store->directory_fd) != 0)
        result = -1;
    if (result != 0)
        (void)unlinkat(store->directory_fd, temporary, 0);
    return result;
}

int pltr_pair_budget_reserve(PltrIdentityStore *store, uint64_t now_seconds) {
    PairBudget state;
    if (load(store, &state) != 0) return -1;
    if (state.used == 3) {
        if (now_seconds < state.until) return -1;
        state.used = 0;
        state.until = 0;
    }
    if (state.used >= 3) return -1;
    ++state.used;
    if (state.used == 3)
        state.until = now_seconds > UINT64_MAX - LOCKOUT_SECONDS ?
                      UINT64_MAX : now_seconds + LOCKOUT_SECONDS;
    return save(store, &state);
}

int pltr_pair_budget_succeeded(PltrIdentityStore *store) {
    PairBudget state;
    if (load(store, &state) != 0) return -1;
    state.used = 0;
    state.until = 0;
    return save(store, &state);
}
