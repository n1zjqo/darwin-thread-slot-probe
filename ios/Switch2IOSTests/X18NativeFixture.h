#ifndef S2I_X18_NATIVE_FIXTURE_H
#define S2I_X18_NATIVE_FIXTURE_H
#include <stddef.h>
#include <stdint.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && defined(__arm64__) && !defined(__arm64e__) && TARGET_OS_SIMULATOR && TARGET_OS_IOS
#define S2I_X18_NATIVE_SUPPORTED 1
#else
#define S2I_X18_NATIVE_SUPPORTED 0
#endif

typedef struct __attribute__((aligned(16))) {
    uint64_t guest18, scratch_save, guest28, guard;
} S2IX18Context;
typedef struct __attribute__((aligned(16))) {
    S2IX18Context context;
    uint64_t initial9, initial10, initial11, initial_nzcv;
    uint64_t after9, after10, after11, after_nzcv;
    uint64_t helper_sp_before, helper_sp_after, base_before, base_after;
    uint64_t callee_before[10], callee_after[10];
    uint64_t probe_sp_before, probe_sp_after, canary_before, canary_after;
    uint64_t fp_before, fp_after, expected_link, observed_link;
} S2IX18Packet;
typedef void (*S2IX18Function)(S2IX18Packet *);
/* selector = width64*6 + subtract*3 + mode; mode: write, read, repeated. */
enum { S2IX18Write = 0, S2IX18Read = 1, S2IX18Repeated = 2, S2IX18Count = 12 };
S2IX18Function s2i_x18_native_function(unsigned selector);
int s2i_x18_reference(unsigned selector, const S2IX18Packet *input, S2IX18Packet *output);
#if S2I_X18_NATIVE_SUPPORTED
void s2i_x18_caller_probe(S2IX18Packet *packet, S2IX18Function function);
#endif
#define S2I_OFFSET(field, value) _Static_assert(offsetof(S2IX18Packet, field) == value, #field " ABI offset")
_Static_assert(sizeof(S2IX18Context) == 32, "context size");
_Static_assert(_Alignof(S2IX18Context) == 16, "context alignment");
_Static_assert(offsetof(S2IX18Context, scratch_save) == 8, "spill offset");
_Static_assert(offsetof(S2IX18Context, guest28) == 16, "guest28 offset");
_Static_assert(offsetof(S2IX18Context, guard) == 24, "guard offset");
S2I_OFFSET(context, 0); S2I_OFFSET(initial9, 32); S2I_OFFSET(initial10, 40);
S2I_OFFSET(initial11, 48); S2I_OFFSET(initial_nzcv, 56); S2I_OFFSET(after9, 64);
S2I_OFFSET(after10, 72); S2I_OFFSET(after11, 80); S2I_OFFSET(after_nzcv, 88);
S2I_OFFSET(helper_sp_before, 96); S2I_OFFSET(helper_sp_after, 104);
S2I_OFFSET(base_before, 112); S2I_OFFSET(base_after, 120);
S2I_OFFSET(callee_before, 128); S2I_OFFSET(callee_after, 208);
S2I_OFFSET(probe_sp_before, 288); S2I_OFFSET(probe_sp_after, 296);
S2I_OFFSET(canary_before, 304); S2I_OFFSET(canary_after, 312);
S2I_OFFSET(fp_before, 320); S2I_OFFSET(fp_after, 328);
S2I_OFFSET(expected_link, 336); S2I_OFFSET(observed_link, 344);
_Static_assert(sizeof(S2IX18Packet) == 352, "packet size");
_Static_assert(_Alignof(S2IX18Packet) == 16, "packet alignment");
#undef S2I_OFFSET
#endif
