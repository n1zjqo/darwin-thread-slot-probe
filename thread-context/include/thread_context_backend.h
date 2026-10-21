#ifndef OWNED_THREAD_CONTEXT_BACKEND_H
#define OWNED_THREAD_CONTEXT_BACKEND_H

#include <pthread.h>
#include "thread_context.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Optional POSIX backend seam, primarily for deterministic fault tests. Every
 * callback obeys pthread semantics; failed create/set/delete leaves state
 * unchanged, key lifetime/destructors are real pthread behavior, allocation is
 * zero-filled, and callbacks return normally without cancellation/reentrancy.
 * The backend and user state must support concurrent callers and outlive the
 * manager and all worker joins. No backend may expose another owner's keys.
 */
typedef struct tc_backend {
    void *user;
    int (*key_create)(void *, pthread_key_t *, void (*)(void *));
    int (*key_delete)(void *, pthread_key_t);
    void *(*get)(void *, pthread_key_t);
    int (*set)(void *, pthread_key_t, const void *);
    void *(*zero_allocate)(void *, size_t);
    void (*deallocate)(void *, void *);
} tc_backend;

tc_backend tc_pthread_backend(void);
tc_status tc_manager_create_with_backend(tc_manager **out,
                                         const tc_options *options,
                                         const tc_backend *backend);

#ifdef __cplusplus
}
#endif
#endif
