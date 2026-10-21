#include "thread_context_backend.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

/* One worker owns each fault fixture between pthread_create and pthread_join. */
struct fault_state { unsigned sets, cancel_at, fail_at, allocations, frees; };
static int create_key(void *u, pthread_key_t *k, void (*d)(void *)) {
    (void)u;
    return pthread_key_create(k, d);
}
static int delete_key(void *u, pthread_key_t k) {
    (void)u;
    return pthread_key_delete(k);
}
static void *get_key(void *u, pthread_key_t k) {
    (void)u;
    return pthread_getspecific(k);
}
static int set_key(void *u, pthread_key_t k, const void *value) {
    struct fault_state *f = u;
    unsigned call = ++f->sets;
    if (call == f->cancel_at) assert(pthread_cancel(pthread_self()) == 0);
    if (call == f->fail_at) return ENOMEM;
    return pthread_setspecific(k, value);
}
static void *allocate(void *u, size_t n) {
    struct fault_state *f = u;
    ++f->allocations;
    return calloc(1, n);
}
static void deallocate(void *u, void *p) {
    struct fault_state *f = u;
    ++f->frees;
    free(p);
}
struct input { tc_manager *manager; int guest, readonly; bool disabled; };
static void *worker(void *u) {
    struct input *input = u;
    int old_state;
    if (input->disabled)
        assert(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL) == 0);
    assert(tc_bind(input->manager,
                   (tc_values){&input->guest, &input->readonly}) == TC_OK);
    tc_status status = tc_unbind(input->manager);
    assert(status == TC_OK || status == TC_CLEANUP_REQUIRED);
    if (input->disabled) {
        assert(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_state) == 0);
        assert(old_state == PTHREAD_CANCEL_DISABLE);
        assert(pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL) == 0);
    }
    pthread_testcancel();
    assert(!"Expected cancellation was not delivered");
    return NULL;
}
int main(void) {
    for (unsigned disabled = 0; disabled < 2; ++disabled) {
        for (unsigned clear = 4; clear <= 6; ++clear) {
            for (unsigned fail = 0; fail < 2; ++fail) {
                struct fault_state f = {0, clear, fail ? clear : 0, 0, 0};
                tc_backend b = {&f, create_key, delete_key, get_key, set_key,
                                allocate, deallocate};
                tc_manager *manager = NULL;
                tc_stats stats;
                pthread_t t;
                void *result = NULL;
                assert(tc_manager_create_with_backend(&manager, NULL, &b) == TC_OK);
                struct input input = {manager, 0, 0, disabled != 0};
                assert(pthread_create(&t, NULL, worker, &input) == 0);
                assert(pthread_join(t, &result) == 0);
                assert(result == PTHREAD_CANCELED);
                assert(tc_manager_stats(manager, &stats) == TC_OK);
                assert(stats.live_records == 0 && stats.successful_binds == 1);
                assert(stats.explicit_releases == (fail ? 0 : 1));
                assert(stats.exit_releases == (fail ? 1 : 0));
                assert(stats.setup_rollbacks == 0 && stats.cleanup_errors == fail);
                assert(tc_manager_destroy(&manager) == TC_OK && manager == NULL);
                assert(f.allocations == f.frees);
            }
        }
    }
    puts("independent cancel transition passed: 12 unbind-clear/cancellation-state cases");
}
