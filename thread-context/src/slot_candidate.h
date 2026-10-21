#ifndef TC_SLOT_CANDIDATE_H
#define TC_SLOT_CANDIDATE_H

#include <stdbool.h>
#include <stdint.h>
#include "thread_context.h"

/* Owned public experiment's arithmetic, not an Apple ABI contract. */
static inline bool tc_slot_address(uintptr_t raw, uintmax_t key, uintptr_t *out)
{
    const uintptr_t base = raw & ~(uintptr_t)7;
    uintptr_t offset;
    uintptr_t candidate;
    if (out == NULL || base == 0 || key >= UINTMAX_C(1024) ||
        key > (uintmax_t)(UINTPTR_MAX / (uintptr_t)8)) {
        return false;
    }
    offset = (uintptr_t)key * (uintptr_t)8;
    if (base > UINTPTR_MAX - offset) {
        return false;
    }
    candidate = base + offset;
    if (candidate > UINTPTR_MAX - (uintptr_t)7) {
        return false;
    }
    *out = candidate;
    return true;
}

/* Internal reader contract: checked, same-process copy of exactly eight bytes. */
typedef bool (*tc_candidate_reader)(void *, uintptr_t, uint64_t *);

static inline tc_status tc_compare_candidate(uintptr_t raw, uintmax_t key,
                                             uintptr_t expected,
                                             tc_candidate_reader reader,
                                             void *user)
{
    uintptr_t address;
    uint64_t copied = 0;
    if (reader == NULL || !tc_slot_address(raw, key, &address)) {
        return TC_CANDIDATE_REJECTED;
    }
    if (!reader(user, address, &copied)) {
        return TC_CANDIDATE_UNREADABLE;
    }
    return copied == (uint64_t)expected ? TC_OK : TC_CANDIDATE_MISMATCH;
}

#endif
