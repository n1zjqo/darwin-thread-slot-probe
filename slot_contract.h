#ifndef SLOT_CONTRACT_H
#define SLOT_CONTRACT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* A hypothesis for this experiment, not a supported Darwin ABI contract. */
#define SLOT_CONTRACT_KEY_LIMIT UINTMAX_C(1024)
#define SLOT_CONTRACT_SLOT_BYTES ((uintptr_t)8)

/*
 * The caller must supply an owned, successfully allocated pthread key.
 * This function checks arithmetic only. Success does not prove readability,
 * ownership of the candidate memory, or equivalence to pthread_getspecific.
 * Failure leaves *address unchanged. No memory at the candidate is accessed.
 */
static inline bool
slot_candidate_address(uintptr_t thread_pointer, uintmax_t owned_key,
                       uintptr_t *address)
{
    const uintptr_t base = thread_pointer & ~(uintptr_t)7;
    uintptr_t offset;
    uintptr_t candidate;

    if (address == NULL || base == 0 ||
        owned_key >= SLOT_CONTRACT_KEY_LIMIT ||
        owned_key > (uintmax_t)(UINTPTR_MAX / SLOT_CONTRACT_SLOT_BYTES)) {
        return false;
    }
    offset = (uintptr_t)owned_key * SLOT_CONTRACT_SLOT_BYTES;
    if (base > UINTPTR_MAX - offset) {
        return false;
    }
    candidate = base + offset;
    if (candidate > UINTPTR_MAX - (SLOT_CONTRACT_SLOT_BYTES - 1)) {
        return false;
    }
    *address = candidate;
    return true;
}

#endif
