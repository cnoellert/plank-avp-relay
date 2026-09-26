#define _POSIX_C_SOURCE 200809L
#include "pair_budget.h"

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char directory[] = "/tmp/pltr-budget-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    PltrIdentityStore store;
    assert(pltr_identity_store_open(&store, directory) == 0);
    assert(pltr_pair_budget_reserve(&store, 1000) == 0);
    assert(pltr_pair_budget_reserve(&store, 1001) == 0);
    assert(pltr_pair_budget_reserve(&store, 1002) == 0);
    pltr_identity_store_close(&store);
    assert(pltr_identity_store_open(&store, directory) == 0);
    assert(pltr_pair_budget_reserve(&store, 1003) != 0);
    assert(pltr_pair_budget_reserve(&store, 1601) != 0);
    assert(pltr_pair_budget_reserve(&store, 1602) == 0);
    assert(pltr_pair_budget_succeeded(&store) == 0);
    assert(pltr_pair_budget_reserve(&store, 1603) == 0);

    char path[160];
    assert(snprintf(path, sizeof(path), "%s/pair-budget", directory) <
           (int)sizeof(path));
    assert(chmod(path, 0644) == 0);
    assert(pltr_pair_budget_reserve(&store, 2000) != 0);
    assert(chmod(path, 0600) == 0);
    const int fd = open(path, O_WRONLY | O_TRUNC);
    assert(fd >= 0);
    const char bad[] = "v1 0 123\n";
    assert(write(fd, bad, sizeof(bad) - 1) == (ssize_t)sizeof(bad) - 1);
    assert(close(fd) == 0);
    assert(pltr_pair_budget_reserve(&store, 2000) != 0);

    pltr_identity_store_close(&store);
    const char *files[] = {"identity.key", "paired-clients.json", "store.lock",
                           "pair-budget"};
    for (size_t i = 0; i < 4; ++i) {
        assert(snprintf(path, sizeof(path), "%s/%s", directory, files[i]) <
               (int)sizeof(path));
        assert(unlink(path) == 0);
    }
    assert(rmdir(directory) == 0);
    return 0;
}
