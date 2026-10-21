#include "thread_context.h"
#include "thread_context_backend.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static atomic_uint checks;
#define CHECK(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); \
        exit(EXIT_FAILURE); \
    } \
    atomic_fetch_add(&checks, 1); \
} while (0)

struct faults {
    unsigned creates, deletes, sets, allocates, frees, active_keys;
    unsigned fail_create, fail_allocate, cancel_set;
    uint64_t fail_sets, fail_deletes;
};

static bool fail_bit(uint64_t bits, unsigned call)
{ return call < 64 && (bits & (UINT64_C(1) << call)) != 0; }

static int fault_create(void *opaque, pthread_key_t *key, void (*fn)(void *))
{
    struct faults *f = opaque;
    int status;
    if (++f->creates == f->fail_create) return EAGAIN;
    status = pthread_key_create(key, fn);
    if (status == 0) ++f->active_keys;
    return status;
}

static int fault_delete(void *opaque, pthread_key_t key)
{
    struct faults *f = opaque;
    int status;
    if (fail_bit(f->fail_deletes, ++f->deletes)) return EINVAL;
    status = pthread_key_delete(key);
    if (status == 0) --f->active_keys;
    return status;
}

static void *fault_get(void *opaque, pthread_key_t key)
{ (void)opaque; return pthread_getspecific(key); }

static int fault_set(void *opaque, pthread_key_t key, const void *value)
{
    struct faults *f = opaque;
    unsigned call = ++f->sets;
    /* Request only; the module has already disabled cancellation. The callback
     * still returns normally, permitting a deterministic transition-boundary
     * test without racing the main thread against mutable fault counters. */
    if (call == f->cancel_set) CHECK(pthread_cancel(pthread_self()) == 0);
    if (fail_bit(f->fail_sets, call)) return ENOMEM;
    return pthread_setspecific(key, value);
}

static void *fault_allocate(void *opaque, size_t size)
{
    struct faults *f = opaque;
    if (++f->allocates == f->fail_allocate) return NULL;
    return calloc(1, size);
}

static void fault_free(void *opaque, void *value)
{
    struct faults *f = opaque;
    CHECK(value != NULL);
    ++f->frees;
    free(value);
}

static tc_backend fault_backend(struct faults *f)
{
    tc_backend backend = { f, fault_create, fault_delete, fault_get, fault_set,
                           fault_allocate, fault_free };
    return backend;
}

static tc_manager *make_fault_manager(struct faults *f)
{
    tc_manager *manager = NULL;
    tc_backend backend = fault_backend(f);
    CHECK(tc_manager_create_with_backend(&manager, NULL, &backend) == TC_OK);
    return manager;
}

static tc_stats stats(tc_manager *manager)
{
    tc_stats out;
    CHECK(tc_manager_stats(manager, &out) == TC_OK);
    return out;
}

static int sentinels[8][2];
static tc_values values(unsigned index)
{
    tc_values out = { &sentinels[index][0], &sentinels[index][1] };
    return out;
}

static void check_values(tc_manager *manager, unsigned index)
{
    tc_values actual = { NULL, NULL };
    tc_values expected = values(index);
    CHECK(tc_get(manager, &actual) == TC_OK);
    CHECK(actual.guest_tls == expected.guest_tls);
    CHECK(actual.readonly_tls == expected.readonly_tls);
}

static void check_hidden(tc_manager *manager, tc_status expected)
{
    tc_values actual = values(7);
    CHECK(tc_get(manager, &actual) == expected);
    CHECK(actual.guest_tls == values(7).guest_tls);
    CHECK(actual.readonly_tls == values(7).readonly_tls);
}

static void test_invalid_and_basic(void)
{
    tc_manager *a = NULL, *b = NULL;
    tc_slot_diagnostic diag = { 99, TC_OK, TC_OK };
    tc_values invalid = { NULL, &sentinels[0][1] };
    CHECK(tc_manager_create(NULL, NULL) == TC_INVALID);
    CHECK(tc_manager_destroy(NULL) == TC_INVALID);
    CHECK(tc_manager_destroy(&a) == TC_INVALID);
    CHECK(tc_manager_create(&a, NULL) == TC_OK);
    CHECK(tc_manager_create(&a, NULL) == TC_INVALID);
    CHECK(tc_bind(a, invalid) == TC_INVALID);
    CHECK(tc_get(a, NULL) == TC_INVALID);
    CHECK(tc_manager_stats(a, NULL) == TC_INVALID);
    check_hidden(a, TC_NOT_BOUND);
    CHECK(tc_unbind(a) == TC_NOT_BOUND);
    CHECK(tc_manager_create(&b, NULL) == TC_OK);
    CHECK(tc_bind(a, values(0)) == TC_OK);
    CHECK(tc_bind(b, values(1)) == TC_OK);
    CHECK(tc_bind(a, values(2)) == TC_ALREADY_BOUND);
    check_values(a, 0);
    check_values(b, 1);
    CHECK(tc_manager_destroy(&a) == TC_BUSY);
    CHECK(tc_check_fast_slots(a, &diag) == TC_DIAGNOSTIC_DISABLED);
    CHECK(diag.checked_slots == 0);
    CHECK(diag.guest_result == TC_DIAGNOSTIC_DISABLED);
    CHECK(tc_unbind(a) == TC_OK);
    check_values(b, 1);
    CHECK(tc_unbind(a) == TC_NOT_BOUND);
    CHECK(tc_unbind(b) == TC_OK);
    CHECK(stats(a).successful_binds == 1);
    CHECK(stats(a).explicit_releases == 1);
    CHECK(stats(a).exit_releases == 0);
    CHECK(tc_manager_destroy(&a) == TC_OK && a == NULL);
    CHECK(tc_manager_destroy(&b) == TC_OK && b == NULL);
    puts("basic_and_manager_isolation PASS");
}

static void test_manager_failures(void)
{
    unsigned fail;
    for (fail = 1; fail <= 3; ++fail) {
        struct faults f = { 0 };
        tc_backend backend = fault_backend(&f);
        tc_manager *manager = NULL;
        f.fail_create = fail;
        CHECK(tc_manager_create_with_backend(&manager, NULL, &backend)
              == TC_BACKEND_ERROR);
        CHECK(manager == NULL && f.active_keys == 0);
        CHECK(f.frees == f.allocates);
        CHECK(f.deletes == fail - 1);
    }
    {
        struct faults f = { 0 };
        tc_backend backend = fault_backend(&f);
        tc_manager *manager = NULL;
        f.fail_allocate = 1;
        CHECK(tc_manager_create_with_backend(&manager, NULL, &backend)
              == TC_NO_MEMORY);
        CHECK(manager == NULL && f.creates == 0 && f.frees == 0);
    }
    {
        struct faults f = { 0 };
        tc_backend backend = fault_backend(&f);
        tc_manager *manager = NULL;
        f.fail_create = 3;
        f.fail_deletes = UINT64_C(1) << 1;
        CHECK(tc_manager_create_with_backend(&manager, NULL, &backend)
              == TC_CLEANUP_REQUIRED);
        CHECK(manager != NULL && f.active_keys == 1);
        CHECK(tc_bind(manager, values(0)) == TC_INVALID);
        CHECK(tc_manager_destroy(&manager) == TC_OK);
        CHECK(manager == NULL && f.active_keys == 0 && f.frees == f.allocates);
    }
    for (fail = 1; fail <= 3; ++fail) {
        struct faults f = { 0 };
        tc_manager *manager = make_fault_manager(&f);
        f.fail_deletes = UINT64_C(1) << fail;
        CHECK(tc_manager_destroy(&manager) == TC_CLEANUP_REQUIRED);
        CHECK(manager != NULL && f.active_keys == 1);
        check_hidden(manager, TC_INVALID);
        CHECK(tc_manager_destroy(&manager) == TC_OK);
        CHECK(f.active_keys == 0 && f.frees == f.allocates);
    }
    puts("partial_key_setup_and_delete_recovery PASS");
}

static void test_bind_failures(void)
{
    unsigned fail;
    for (fail = 1; fail <= 3; ++fail) {
        struct faults f = { 0 };
        tc_manager *manager = make_fault_manager(&f);
        f.fail_sets = UINT64_C(1) << fail;
        CHECK(tc_bind(manager, values(0)) == TC_BACKEND_ERROR);
        check_hidden(manager, TC_NOT_BOUND);
        CHECK(stats(manager).live_records == 0);
        CHECK(stats(manager).setup_rollbacks == (fail == 1 ? 0 : 1));
        CHECK(tc_bind(manager, values(1)) == TC_OK);
        check_values(manager, 1);
        CHECK(tc_unbind(manager) == TC_OK);
        CHECK(tc_manager_destroy(&manager) == TC_OK);
        CHECK(f.active_keys == 0 && f.frees == f.allocates);
    }
    {
        struct faults f = { 0 };
        tc_manager *manager = make_fault_manager(&f);
        f.fail_allocate = 2;
        CHECK(tc_bind(manager, values(0)) == TC_NO_MEMORY);
        check_hidden(manager, TC_NOT_BOUND);
        CHECK(f.sets == 0);
        CHECK(tc_manager_destroy(&manager) == TC_OK);
        CHECK(f.frees + 1 == f.allocates);
    }
    /* Third install fails; each subsequent clear (guest, readonly, owner) fails
     * independently once. Retrying unbind must recover the retained record. */
    for (fail = 4; fail <= 6; ++fail) {
        struct faults f = { 0 };
        tc_manager *manager = make_fault_manager(&f);
        f.fail_sets = (UINT64_C(1) << 3) | (UINT64_C(1) << fail);
        CHECK(tc_bind(manager, values(0)) == TC_CLEANUP_REQUIRED);
        check_hidden(manager, TC_CLEANUP_REQUIRED);
        CHECK(tc_bind(manager, values(1)) == TC_ALREADY_BOUND);
        CHECK(tc_manager_destroy(&manager) == TC_BUSY);
        CHECK(stats(manager).live_records == 1);
        CHECK(tc_unbind(manager) == TC_OK);
        CHECK(stats(manager).setup_rollbacks == 1);
        CHECK(stats(manager).cleanup_errors == 1);
        CHECK(tc_manager_destroy(&manager) == TC_OK);
        CHECK(f.active_keys == 0 && f.frees == f.allocates);
    }
    puts("bind_failure_and_rollback_recovery PASS");
}

static void test_unbind_failures(void)
{
    unsigned fail;
    for (fail = 4; fail <= 6; ++fail) {
        struct faults f = { 0 };
        tc_manager *manager = make_fault_manager(&f);
        CHECK(tc_bind(manager, values(0)) == TC_OK);
        f.fail_sets = UINT64_C(1) << fail;
        CHECK(tc_unbind(manager) == TC_CLEANUP_REQUIRED);
        check_hidden(manager, TC_CLEANUP_REQUIRED);
        CHECK(stats(manager).live_records == 1);
        CHECK(stats(manager).explicit_releases == 0);
        CHECK(tc_unbind(manager) == TC_OK);
        CHECK(tc_unbind(manager) == TC_NOT_BOUND);
        CHECK(stats(manager).live_records == 0);
        CHECK(stats(manager).explicit_releases == 1);
        CHECK(stats(manager).setup_rollbacks == 0);
        CHECK(tc_manager_destroy(&manager) == TC_OK);
        CHECK(f.active_keys == 0 && f.frees == f.allocates);
    }
    puts("unbind_failure_and_retry PASS");
}

enum { WORKERS = 4, ROUNDS = 500 };
struct gate {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned ready;
    bool release;
};

struct worker_input { tc_manager *manager; struct gate *gate; unsigned index; };

static void *isolation_worker(void *opaque)
{
    struct worker_input *input = opaque;
    unsigned round;
    check_hidden(input->manager, TC_NOT_BOUND);
    for (round = 0; round < ROUNDS; ++round) {
        CHECK(tc_bind(input->manager, values(input->index)) == TC_OK);
        check_values(input->manager, input->index);
        CHECK(tc_unbind(input->manager) == TC_OK);
        check_hidden(input->manager, TC_NOT_BOUND);
    }
    CHECK(tc_bind(input->manager, values(input->index)) == TC_OK);
    CHECK(pthread_mutex_lock(&input->gate->mutex) == 0);
    ++input->gate->ready;
    CHECK(pthread_cond_broadcast(&input->gate->condition) == 0);
    while (!input->gate->release)
        CHECK(pthread_cond_wait(&input->gate->condition,
                                &input->gate->mutex) == 0);
    CHECK(pthread_mutex_unlock(&input->gate->mutex) == 0);
    check_values(input->manager, input->index);
    return NULL; /* Real pthread key destructor owns final record cleanup. */
}

static void test_multithread(void)
{
    tc_manager *manager = NULL;
    pthread_t threads[WORKERS];
    struct worker_input inputs[WORKERS];
    struct gate gate = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER,
                         0, false };
    unsigned i;
    CHECK(tc_manager_create(&manager, NULL) == TC_OK);
    CHECK(tc_bind(manager, values(0)) == TC_OK);
    for (i = 0; i < WORKERS; ++i) {
        inputs[i] = (struct worker_input){ manager, &gate, i + 1 };
        CHECK(pthread_create(&threads[i], NULL, isolation_worker, &inputs[i]) == 0);
    }
    CHECK(pthread_mutex_lock(&gate.mutex) == 0);
    while (gate.ready != WORKERS)
        CHECK(pthread_cond_wait(&gate.condition, &gate.mutex) == 0);
    CHECK(stats(manager).live_records == WORKERS + 1);
    CHECK(stats(manager).exit_releases == 0);
    check_values(manager, 0);
    gate.release = true;
    CHECK(pthread_cond_broadcast(&gate.condition) == 0);
    CHECK(pthread_mutex_unlock(&gate.mutex) == 0);
    for (i = 0; i < WORKERS; ++i) CHECK(pthread_join(threads[i], NULL) == 0);
    CHECK(stats(manager).successful_binds == 1 + WORKERS * (ROUNDS + 1));
    CHECK(stats(manager).explicit_releases == WORKERS * ROUNDS);
    CHECK(stats(manager).exit_releases == WORKERS);
    CHECK(stats(manager).live_records == 1);
    CHECK(stats(manager).cleanup_errors == 0);
    check_values(manager, 0);
    CHECK(tc_unbind(manager) == TC_OK);
    CHECK(tc_manager_destroy(&manager) == TC_OK);
    CHECK(pthread_cond_destroy(&gate.condition) == 0);
    CHECK(pthread_mutex_destroy(&gate.mutex) == 0);
    puts("multithread_isolation_and_exit PASS");
}

static void *cancellation_worker(void *opaque)
{
    tc_manager *manager = opaque;
    tc_status status = tc_bind(manager, values(0));
    CHECK(status == TC_OK || status == TC_BACKEND_ERROR ||
          status == TC_CLEANUP_REQUIRED);
    pthread_testcancel();
    CHECK(false); /* Every scenario has a pending cancellation request. */
    return NULL;
}

static void test_cancellation(void)
{
    unsigned scenario;
    for (scenario = 0; scenario < 4; ++scenario) {
        struct faults f = { 0 };
        tc_manager *manager = make_fault_manager(&f);
        pthread_t thread;
        void *result = NULL;
        f.cancel_set = 3;
        if (scenario == 1) f.fail_sets = UINT64_C(1) << 3;
        if (scenario == 2) f.fail_sets = (UINT64_C(1) << 3) | (UINT64_C(1) << 4);
        /* Successful binding, then a best-effort destructor clear fails. */
        if (scenario == 3) f.fail_sets = UINT64_C(1) << 4;
        CHECK(pthread_create(&thread, NULL, cancellation_worker, manager) == 0);
        CHECK(pthread_join(thread, &result) == 0);
        CHECK(result == PTHREAD_CANCELED);
        CHECK(stats(manager).live_records == 0);
        CHECK(stats(manager).exit_releases == (scenario == 1 ? 0 : 1));
        CHECK(stats(manager).setup_rollbacks ==
              (scenario == 1 || scenario == 2 ? 1 : 0));
        CHECK(stats(manager).cleanup_errors == (scenario >= 2 ? 1 : 0));
        CHECK(tc_manager_destroy(&manager) == TC_OK);
        CHECK(f.active_keys == 0 && f.frees == f.allocates);
    }
    puts("deferred_cancel_success_rollback_and_exit_cleanup PASS");
}

static void test_diagnostic_opt_in(void)
{
    tc_manager *manager = NULL;
    tc_options options = { true };
    tc_slot_diagnostic diag = { 99, TC_OK, TC_OK };
    CHECK(tc_manager_create(&manager, &options) == TC_OK);
    CHECK(tc_check_fast_slots(manager, &diag) == TC_NOT_BOUND);
    CHECK(diag.checked_slots == 99);
    CHECK(tc_bind(manager, values(0)) == TC_OK);
#if !defined(TC_ENABLE_DARWIN_DIAGNOSTIC) || !TC_ENABLE_DARWIN_DIAGNOSTIC
    CHECK(tc_check_fast_slots(manager, &diag) == TC_DIAGNOSTIC_DISABLED);
    CHECK(diag.checked_slots == 0);
#elif !defined(__APPLE__) || !defined(__aarch64__)
    CHECK(tc_check_fast_slots(manager, &diag) == TC_UNSUPPORTED);
    CHECK(diag.checked_slots == 0);
#else
    /* Mismatch/rejection/read failure is a supported diagnostic outcome. This
     * portable lifecycle suite never requires an undocumented layout to work. */
    {
        tc_status diagnostic_status = tc_check_fast_slots(manager, &diag);
        CHECK(diagnostic_status == TC_OK ||
              diagnostic_status == TC_CANDIDATE_REJECTED ||
              diagnostic_status == TC_CANDIDATE_UNREADABLE ||
              diagnostic_status == TC_CANDIDATE_MISMATCH);
        CHECK(diagnostic_status == (diag.guest_result != TC_OK ?
              diag.guest_result : diag.readonly_result));
        printf("darwin_candidate_observation guest=%s readonly=%s\n",
               tc_status_name(diag.guest_result),
               tc_status_name(diag.readonly_result));
    }
    CHECK(diag.checked_slots == 2);
#endif
    check_values(manager, 0);
    CHECK(tc_unbind(manager) == TC_OK);
    CHECK(tc_manager_destroy(&manager) == TC_OK);
    puts("diagnostic_gate_and_portable_fallback PASS");
}

int main(void)
{
    test_invalid_and_basic();
    test_manager_failures();
    test_bind_failures();
    test_unbind_failures();
    test_multithread();
    test_cancellation();
    test_diagnostic_opt_in();
    printf("thread_context PASS=%u FAIL=0\n", atomic_load(&checks));
    return EXIT_SUCCESS;
}
