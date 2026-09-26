#ifndef PLANK_RELAY_PAIR_BUDGET_H
#define PLANK_RELAY_PAIR_BUDGET_H

#include "identity.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Reserve one physical pairing attempt before the window opens. It remains
// consumed after a crash or restart. Three reserved attempts cause a ten
// minute lockout for subsequent attempts. now_seconds is wall-clock UTC.
int pltr_pair_budget_reserve(PltrIdentityStore *store, uint64_t now_seconds);
// Clear the persistent count only after mutual confirmation succeeds.
int pltr_pair_budget_succeeded(PltrIdentityStore *store);

#ifdef __cplusplus
}
#endif
#endif
