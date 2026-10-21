#ifndef OWNED_THREAD_CONTEXT_H
#define OWNED_THREAD_CONTEXT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tc_manager tc_manager;

typedef enum tc_status {
    TC_OK = 0,
    TC_INVALID,
    TC_NO_MEMORY,
    TC_BACKEND_ERROR,
    TC_ALREADY_BOUND,
    TC_NOT_BOUND,
    TC_CLEANUP_REQUIRED,
    TC_BUSY,
    TC_DIAGNOSTIC_DISABLED,
    TC_UNSUPPORTED,
    TC_CANDIDATE_REJECTED,
    TC_CANDIDATE_UNREADABLE,
    TC_CANDIDATE_MISMATCH
} tc_status;

/* Labels for synthetic, borrowed values; neither has guest-machine semantics. */
typedef struct tc_values {
    void *guest_tls;
    void *readonly_tls;
} tc_values;

typedef struct tc_options {
    bool allow_darwin_slot_diagnostic;
} tc_options;

typedef struct tc_stats {
    uint64_t live_records;
    uint64_t successful_binds;
    uint64_t explicit_releases;
    uint64_t exit_releases;
    uint64_t setup_rollbacks;
    uint64_t cleanup_errors;
} tc_stats;

typedef struct tc_slot_diagnostic {
    size_t checked_slots;
    /* A point-in-time comparison only, never permission to use raw TLS loads. */
    tc_status guest_result;
    tc_status readonly_result;
} tc_slot_diagnostic;

/*
 * Create/destroy are supervisor operations: externally exclude ALL concurrent
 * component calls and cancellation during them. Before destroy, join workers
 * (or otherwise prove all API calls AND TLS destructors finished). A live-count
 * check alone is not a concurrency admission protocol. *out initially is NULL.
 * On a partial-key
 * cleanup failure create returns CLEANUP_REQUIRED and leaves an owned, disabled
 * manager in *out; only stats/destroy are then permitted. Otherwise failure
 * leaves NULL. Destroy returning CLEANUP_REQUIRED disables the retained manager
 * for retry; BUSY leaves the manager and its bindings unchanged.
 */
tc_status tc_manager_create(tc_manager **out, const tc_options *options);
tc_status tc_manager_destroy(tc_manager **manager);

/*
 * Thread-affine bind/unbind. Values must both be non-NULL and remain alive until
 * successful unbind or thread exit + join, including CLEANUP_REQUIRED outcomes.
 * The component never dereferences or frees these borrowed values. A failed bind
 * with successful rollback returns BACKEND_ERROR and retains no association.
 * CLEANUP_REQUIRED retains an owner record; call unbind again, or exit/join.
 * Deferred cancellation is masked during transitions; async cancellation is not
 * supported. Do not call any API from a signal handler or another TLS destructor.
 */
tc_status tc_bind(tc_manager *manager, tc_values values);
tc_status tc_unbind(tc_manager *manager);

/* Output unchanged on failure; partial/cleanup-pending bindings are hidden. */
tc_status tc_get(tc_manager *manager, tc_values *out);

/* Atomic counters, not an atomic multi-counter snapshot. Manager must be alive. */
tc_status tc_manager_stats(tc_manager *manager, tc_stats *out);

/*
 * Compile-time AND runtime opt-in. Checks only this manager's allocated keys on
 * the calling bound thread. No register writes, direct candidate dereferences,
 * saved addresses, guest execution, or patching. Failure preserves the pthread
 * binding; normal access always continues through tc_get/pthread_getspecific.
 */
tc_status tc_check_fast_slots(tc_manager *manager, tc_slot_diagnostic *out);

const char *tc_status_name(tc_status status);

#ifdef __cplusplus
}
#endif
#endif
