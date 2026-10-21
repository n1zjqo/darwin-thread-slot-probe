#include "slot_candidate.h"

#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); \
    exit(EXIT_FAILURE); } ++checks; } while (0)

struct reader_state { uintptr_t address; uint64_t value; bool readable; unsigned calls; };
static bool fake_read(void *opaque, uintptr_t address, uint64_t *out)
{
    struct reader_state *state = opaque;
    CHECK(address == state->address);
    ++state->calls;
    *out = state->value;
    return state->readable;
}

static void reject(uintptr_t raw, uintmax_t key)
{
    uintptr_t address = 123;
    CHECK(!tc_slot_address(raw, key, &address));
    CHECK(address == 123);
}

int main(void)
{
    uintptr_t address = 0;
    uintptr_t tag;
    uintmax_t key;
    const uintptr_t high = UINTPTR_MAX & ~(uintptr_t)7;
    struct reader_state state = { 0x1018, 0x1234, true, 0 };
    for (key = 0; key < 1024; ++key) {
        for (tag = 0; tag < 8; ++tag) {
            CHECK(tc_slot_address(0x1000 | tag, key, &address));
            CHECK(address == 0x1000 + key * 8);
        }
    }
    for (tag = 0; tag < 8; ++tag) reject(tag, 0);
    reject(0x1000, 1024);
    reject(0x1000, UINTMAX_MAX);
    CHECK(!tc_slot_address(0x1000, 0, NULL));
    CHECK(tc_slot_address(high, 0, &address) && address == high);
    CHECK(tc_slot_address(UINTPTR_MAX, 0, &address) && address == high);
    CHECK(tc_slot_address(high - 8, 1, &address) && address == high);
    reject(high, 1);
    reject(high - 8, 2);
    CHECK(tc_compare_candidate(0x1007, 3, 0x1234, fake_read, &state) == TC_OK);
    CHECK(state.calls == 1);
    CHECK(tc_compare_candidate(0x1000, 3, 0x5678, fake_read, &state)
          == TC_CANDIDATE_MISMATCH);
    state.readable = false;
    CHECK(tc_compare_candidate(0x1000, 3, 0x1234, fake_read, &state)
          == TC_CANDIDATE_UNREADABLE);
    CHECK(tc_compare_candidate(0x1000, 1024, 0x1234, fake_read, &state)
          == TC_CANDIDATE_REJECTED);
    CHECK(state.calls == 3);
    CHECK(tc_compare_candidate(0x1000, 3, 0x1234, NULL, &state)
          == TC_CANDIDATE_REJECTED);
    printf("slot_candidate_arithmetic_and_comparison PASS=%u FAIL=0\n", checks);
    return EXIT_SUCCESS;
}
