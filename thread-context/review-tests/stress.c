#include "thread_context.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

enum { THREADS = 12, ROUNDS = 8000 };
struct fixture { tc_manager *m; unsigned id; int guest; int readonly; };
static void *worker(void *raw) {
    struct fixture *f = raw;
    for (unsigned i = 0; i < ROUNDS; ++i) {
        tc_values expected = { &f->guest, &f->readonly };
        tc_values actual = { NULL, NULL };
        assert(tc_bind(f->m, expected) == TC_OK);
        assert(tc_bind(f->m, expected) == TC_ALREADY_BOUND);
        assert(tc_get(f->m, &actual) == TC_OK);
        assert(actual.guest_tls == expected.guest_tls);
        assert(actual.readonly_tls == expected.readonly_tls);
        if (i + 1 == ROUNDS && f->id % 2 == 0) return NULL;
        assert(tc_unbind(f->m) == TC_OK);
        assert(tc_get(f->m, &actual) == TC_NOT_BOUND);
        assert(tc_unbind(f->m) == TC_NOT_BOUND);
    }
    return NULL;
}
static atomic_int cancel_ready;
static void *cancel_worker(void *raw) {
    struct fixture *f = raw;
    tc_values values = { &f->guest, &f->readonly };
    assert(tc_bind(f->m, values) == TC_OK);
    atomic_store(&cancel_ready, 1);
    for (;;) pthread_testcancel();
}
int main(void) {
    for (unsigned round = 0; round < 3; ++round) {
        tc_manager *m = NULL;
        pthread_t threads[THREADS];
        struct fixture f[THREADS];
        tc_stats stats;
        assert(tc_manager_create(&m, NULL) == TC_OK);
        for (unsigned t = 0; t < THREADS; ++t) {
            f[t] = (struct fixture){m, t, 0, 0};
            assert(pthread_create(&threads[t], NULL, worker, &f[t]) == 0);
        }
        for (unsigned t = 0; t < THREADS; ++t) assert(pthread_join(threads[t], NULL) == 0);
        assert(tc_manager_stats(m, &stats) == TC_OK);
        assert(stats.live_records == 0);
        assert(stats.successful_binds == THREADS * ROUNDS);
        assert(stats.explicit_releases == THREADS * ROUNDS - THREADS / 2);
        assert(stats.exit_releases == THREADS / 2);
        assert(stats.setup_rollbacks == 0 && stats.cleanup_errors == 0);
        atomic_store(&cancel_ready, 0);
        assert(pthread_create(&threads[0], NULL, cancel_worker, &f[0]) == 0);
        while (!atomic_load(&cancel_ready)) { }
        assert(pthread_cancel(threads[0]) == 0);
        void *result = NULL;
        assert(pthread_join(threads[0], &result) == 0);
        assert(result == PTHREAD_CANCELED);
        assert(tc_manager_stats(m, &stats) == TC_OK);
        assert(stats.live_records == 0);
        assert(stats.exit_releases == THREADS / 2 + 1);
        assert(tc_manager_destroy(&m) == TC_OK && m == NULL);
    }
    puts("independent stress passed: 288000 binds; 18 exit releases; 3 deferred cancellations");
}
