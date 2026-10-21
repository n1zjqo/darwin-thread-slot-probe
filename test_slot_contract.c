#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "slot_contract.h"

static unsigned passed;
static unsigned failed;

static void
check(bool condition)
{
    if (condition) {
        ++passed;
    } else {
        ++failed;
    }
}

static void
reject(uintptr_t raw, uintmax_t key)
{
    uintptr_t output = (uintptr_t)123;
    check(!slot_candidate_address(raw, key, &output));
    check(output == (uintptr_t)123);
}

int
main(void)
{
    uintptr_t output = 0;
    const uintptr_t high_base = UINTPTR_MAX & ~(uintptr_t)7;
    uintmax_t key;
    uintptr_t tag;

    /* Every supported key and every ignored low bit combination. */
    for (key = 0; key < SLOT_CONTRACT_KEY_LIMIT; ++key) {
        for (tag = 0; tag < (uintptr_t)8; ++tag) {
            check(slot_candidate_address((uintptr_t)0x1000 | tag, key,
                                         &output));
            check(output == (uintptr_t)0x1000 + (uintptr_t)key * 8);
        }
    }

    for (tag = 0; tag < (uintptr_t)8; ++tag) {
        reject(tag, 0);
        reject(tag, 1);
    }
    reject((uintptr_t)0x1000, SLOT_CONTRACT_KEY_LIMIT);
    reject((uintptr_t)0x1000, SLOT_CONTRACT_KEY_LIMIT + 1);
    reject((uintptr_t)0x1000, UINTMAX_MAX);
    check(!slot_candidate_address((uintptr_t)0x1000, 0, NULL));

    check(slot_candidate_address((uintptr_t)8, 0, &output));
    check(output == (uintptr_t)8);
    check(slot_candidate_address((uintptr_t)15, 1, &output));
    check(output == (uintptr_t)16);

    /* An entire eight-byte read must fit, including the highest byte. */
    check(slot_candidate_address(high_base, 0, &output));
    check(output == high_base);
    check(slot_candidate_address(UINTPTR_MAX, 0, &output));
    check(output == high_base);
    reject(high_base, 1);
    reject(UINTPTR_MAX, SLOT_CONTRACT_KEY_LIMIT - 1);

    check(slot_candidate_address(high_base - (uintptr_t)8, 1, &output));
    check(output == high_base);
    reject(high_base - (uintptr_t)8, 2);

    printf("slot_contract PASS=%u FAIL=%u\n", passed, failed);
    return failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
