#include "thread_context.h"
#include "thread_context_backend.h"
#include "slot_candidate.h"

#include <stdatomic.h>
#include <stdlib.h>

#ifndef TC_ENABLE_DARWIN_DIAGNOSTIC
#define TC_ENABLE_DARWIN_DIAGNOSTIC 0
#endif

#if TC_ENABLE_DARWIN_DIAGNOSTIC && defined(__APPLE__) && defined(__aarch64__)
#include <limits.h>
#include <mach/kern_return.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#define TC_HAS_DARWIN_DIAGNOSTIC 1
_Static_assert(CHAR_BIT == 8 && sizeof(uintptr_t) == 8 && sizeof(void *) == 8,
               "Darwin candidate diagnostic requires 64-bit pointers.");
_Static_assert(sizeof(vm_address_t) >= sizeof(uintptr_t),
               "Mach addresses must hold a process address.");
#else
#define TC_HAS_DARWIN_DIAGNOSTIC 0
#endif

enum { OWNER_KEY, GUEST_KEY, READONLY_KEY, KEY_COUNT };

struct tc_manager {
    tc_backend backend;
    pthread_key_t keys[KEY_COUNT];
    bool allocated[KEY_COUNT];
    bool ready;
    bool diagnostic_allowed;
    atomic_uint_fast64_t live;
    atomic_uint_fast64_t bound;
    atomic_uint_fast64_t explicit_releases;
    atomic_uint_fast64_t exit_releases;
    atomic_uint_fast64_t rollbacks;
    atomic_uint_fast64_t cleanup_errors;
};

struct tc_record {
    tc_manager *manager;
    tc_values values;
    bool complete;
    bool cleanup_pending;
};

static int default_create(void *user, pthread_key_t *key, void (*fn)(void *))
{ (void)user; return pthread_key_create(key, fn); }
static int default_delete(void *user, pthread_key_t key)
{ (void)user; return pthread_key_delete(key); }
static void *default_get(void *user, pthread_key_t key)
{ (void)user; return pthread_getspecific(key); }
static int default_set(void *user, pthread_key_t key, const void *value)
{ (void)user; return pthread_setspecific(key, value); }
static void *default_allocate(void *user, size_t size)
{ (void)user; return calloc(1, size); }
static void default_free(void *user, void *value)
{ (void)user; free(value); }

tc_backend tc_pthread_backend(void)
{
    tc_backend out = { NULL, default_create, default_delete, default_get,
                       default_set, default_allocate, default_free };
    return out;
}

static void *get_slot(tc_manager *manager, unsigned index)
{
    return manager->backend.get(manager->backend.user, manager->keys[index]);
}

static int set_slot(tc_manager *manager, unsigned index, const void *value)
{
    return manager->backend.set(manager->backend.user,
                                manager->keys[index], value);
}

static void release_record(struct tc_record *record, bool exiting)
{
    tc_manager *manager = record->manager;
    if (!record->complete) {
        atomic_fetch_add(&manager->rollbacks, 1);
    }
    if (exiting) {
        atomic_fetch_add(&manager->exit_releases, 1);
    } else {
        atomic_fetch_add(&manager->explicit_releases, 1);
    }
    manager->backend.deallocate(manager->backend.user, record);
    /* No manager access follows this final count update. */
    atomic_fetch_sub(&manager->live, 1);
}

static void owner_destructor(void *value)
{
    struct tc_record *record = value;
    tc_manager *manager = record->manager;
    unsigned slot;
    /* pthread has already cleared OWNER_KEY. Never reinstall it here. */
    for (slot = GUEST_KEY; slot <= READONLY_KEY; ++slot) {
        if (set_slot(manager, slot, NULL) != 0) {
            atomic_fetch_add(&manager->cleanup_errors, 1);
        }
    }
    /* Only the cleared owner key held this record, never the borrowed slots.
     * Residual borrowed values disappear when the thread terminates. Other TLS
     * destructors must not use this component during teardown. */
    release_record(record, true);
}

static bool delete_keys(tc_manager *manager)
{
    bool success = true;
    unsigned count = KEY_COUNT;
    while (count != 0) {
        unsigned slot = --count;
        if (manager->allocated[slot]) {
            if (manager->backend.key_delete(manager->backend.user,
                                             manager->keys[slot]) != 0) {
                success = false;
                atomic_fetch_add(&manager->cleanup_errors, 1);
            } else {
                manager->allocated[slot] = false;
            }
        }
    }
    return success;
}

tc_status tc_manager_create_with_backend(tc_manager **out,
                                         const tc_options *options,
                                         const tc_backend *backend)
{
    tc_manager *manager;
    unsigned slot;
    if (out == NULL || *out != NULL || backend == NULL ||
        backend->key_create == NULL || backend->key_delete == NULL ||
        backend->get == NULL || backend->set == NULL ||
        backend->zero_allocate == NULL || backend->deallocate == NULL) {
        return TC_INVALID;
    }
    manager = backend->zero_allocate(backend->user, sizeof(*manager));
    if (manager == NULL) {
        return TC_NO_MEMORY;
    }
    manager->backend = *backend;
    manager->diagnostic_allowed = options != NULL &&
        options->allow_darwin_slot_diagnostic;
    atomic_init(&manager->live, 0);
    atomic_init(&manager->bound, 0);
    atomic_init(&manager->explicit_releases, 0);
    atomic_init(&manager->exit_releases, 0);
    atomic_init(&manager->rollbacks, 0);
    atomic_init(&manager->cleanup_errors, 0);
    for (slot = OWNER_KEY; slot < KEY_COUNT; ++slot) {
        if (backend->key_create(backend->user, &manager->keys[slot],
                                slot == OWNER_KEY ? owner_destructor : NULL)
                != 0) {
            if (!delete_keys(manager)) {
                *out = manager;
                return TC_CLEANUP_REQUIRED;
            }
            backend->deallocate(backend->user, manager);
            return TC_BACKEND_ERROR;
        }
        manager->allocated[slot] = true;
    }
    manager->ready = true;
    *out = manager;
    return TC_OK;
}

tc_status tc_manager_create(tc_manager **out, const tc_options *options)
{
    const tc_backend backend = tc_pthread_backend();
    return tc_manager_create_with_backend(out, options, &backend);
}

tc_status tc_manager_destroy(tc_manager **owner)
{
    tc_manager *manager;
    tc_backend backend;
    if (owner == NULL || *owner == NULL) {
        return TC_INVALID;
    }
    manager = *owner;
    if (atomic_load(&manager->live) != 0) {
        return TC_BUSY;
    }
    manager->ready = false;
    if (!delete_keys(manager)) {
        return TC_CLEANUP_REQUIRED;
    }
    backend = manager->backend;
    *owner = NULL;
    backend.deallocate(backend.user, manager);
    return TC_OK;
}

/* Called with cancellation disabled; record stays reachable on any failure. */
static tc_status detach_record(struct tc_record *record)
{
    tc_manager *manager = record->manager;
    bool cleared = true;
    unsigned slot;
    record->cleanup_pending = true;
    for (slot = GUEST_KEY; slot <= READONLY_KEY; ++slot) {
        if (set_slot(manager, slot, NULL) != 0) {
            atomic_fetch_add(&manager->cleanup_errors, 1);
            cleared = false;
        }
    }
    if (!cleared) {
        return TC_CLEANUP_REQUIRED;
    }
    if (set_slot(manager, OWNER_KEY, NULL) != 0) {
        atomic_fetch_add(&manager->cleanup_errors, 1);
        return TC_CLEANUP_REQUIRED;
    }
    release_record(record, false);
    return TC_OK;
}

static tc_status restore_cancellation(int old_state, tc_status status)
{
    /* Valid state returned by pthread_setcancelstate must be restorable. */
    if (pthread_setcancelstate(old_state, NULL) != 0) {
        abort();
    }
    return status;
}

tc_status tc_bind(tc_manager *manager, tc_values values)
{
    struct tc_record *record;
    int old_state;
    tc_status status;
    if (manager == NULL || !manager->ready || values.guest_tls == NULL ||
        values.readonly_tls == NULL) {
        return TC_INVALID;
    }
    if (pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_state) != 0) {
        return TC_BACKEND_ERROR;
    }
    if (get_slot(manager, OWNER_KEY) != NULL) {
        return restore_cancellation(old_state, TC_ALREADY_BOUND);
    }
    record = manager->backend.zero_allocate(manager->backend.user,
                                             sizeof(*record));
    if (record == NULL) {
        return restore_cancellation(old_state, TC_NO_MEMORY);
    }
    record->manager = manager;
    record->values = values;
    if (set_slot(manager, OWNER_KEY, record) != 0) {
        manager->backend.deallocate(manager->backend.user, record);
        return restore_cancellation(old_state, TC_BACKEND_ERROR);
    }
    atomic_fetch_add(&manager->live, 1);
    if (set_slot(manager, GUEST_KEY, values.guest_tls) != 0 ||
        set_slot(manager, READONLY_KEY, values.readonly_tls) != 0) {
        status = detach_record(record);
        return restore_cancellation(old_state,
            status == TC_OK ? TC_BACKEND_ERROR : status);
    }
    record->complete = true;
    atomic_fetch_add(&manager->bound, 1);
    return restore_cancellation(old_state, TC_OK);
}

tc_status tc_unbind(tc_manager *manager)
{
    struct tc_record *record;
    tc_status status;
    int old_state;
    if (manager == NULL || !manager->ready) {
        return TC_INVALID;
    }
    if (pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_state) != 0) {
        return TC_BACKEND_ERROR;
    }
    record = get_slot(manager, OWNER_KEY);
    status = record == NULL ? TC_NOT_BOUND : detach_record(record);
    return restore_cancellation(old_state, status);
}

tc_status tc_get(tc_manager *manager, tc_values *out)
{
    struct tc_record *record;
    tc_values values;
    if (manager == NULL || !manager->ready || out == NULL) {
        return TC_INVALID;
    }
    record = get_slot(manager, OWNER_KEY);
    if (record == NULL) {
        return TC_NOT_BOUND;
    }
    if (!record->complete || record->cleanup_pending) {
        return TC_CLEANUP_REQUIRED;
    }
    values.guest_tls = get_slot(manager, GUEST_KEY);
    values.readonly_tls = get_slot(manager, READONLY_KEY);
    if (values.guest_tls != record->values.guest_tls ||
        values.readonly_tls != record->values.readonly_tls) {
        return TC_CLEANUP_REQUIRED;
    }
    *out = values;
    return TC_OK;
}

tc_status tc_manager_stats(tc_manager *manager, tc_stats *out)
{
    if (manager == NULL || out == NULL) {
        return TC_INVALID;
    }
    out->live_records = atomic_load(&manager->live);
    out->successful_binds = atomic_load(&manager->bound);
    out->explicit_releases = atomic_load(&manager->explicit_releases);
    out->exit_releases = atomic_load(&manager->exit_releases);
    out->setup_rollbacks = atomic_load(&manager->rollbacks);
    out->cleanup_errors = atomic_load(&manager->cleanup_errors);
    return TC_OK;
}

#if TC_HAS_DARWIN_DIAGNOSTIC
static bool checked_self_read(void *user, uintptr_t address, uint64_t *out)
{
    vm_size_t copied = 0;
    kern_return_t result;
    (void)user;
    result = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
        (vm_size_t)sizeof(*out), (vm_address_t)(uintptr_t)out, &copied);
    return result == KERN_SUCCESS && copied == sizeof(*out);
}
#endif

tc_status tc_check_fast_slots(tc_manager *manager, tc_slot_diagnostic *out)
{
    tc_values values;
    tc_status status;
    tc_slot_diagnostic result = { 0, TC_DIAGNOSTIC_DISABLED,
                                    TC_DIAGNOSTIC_DISABLED };
    if (manager == NULL || out == NULL) {
        return TC_INVALID;
    }
    status = tc_get(manager, &values);
    if (status != TC_OK) {
        return status;
    }
    if (!manager->diagnostic_allowed || !TC_ENABLE_DARWIN_DIAGNOSTIC) {
        *out = result;
        return TC_DIAGNOSTIC_DISABLED;
    }
#if TC_HAS_DARWIN_DIAGNOSTIC
    {
        uintptr_t raw;
        __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(raw));
        result.guest_result = tc_compare_candidate(raw,
            (uintmax_t)manager->keys[GUEST_KEY], (uintptr_t)values.guest_tls,
            checked_self_read, NULL);
        result.readonly_result = tc_compare_candidate(raw,
            (uintmax_t)manager->keys[READONLY_KEY], (uintptr_t)values.readonly_tls,
            checked_self_read, NULL);
        result.checked_slots = 2;
        *out = result;
        return result.guest_result != TC_OK ? result.guest_result :
                                             result.readonly_result;
    }
#else
    result.guest_result = TC_UNSUPPORTED;
    result.readonly_result = TC_UNSUPPORTED;
    *out = result;
    return TC_UNSUPPORTED;
#endif
}

const char *tc_status_name(tc_status status)
{
    switch (status) {
    case TC_OK: return "ok";
    case TC_INVALID: return "invalid";
    case TC_NO_MEMORY: return "no_memory";
    case TC_BACKEND_ERROR: return "backend_error";
    case TC_ALREADY_BOUND: return "already_bound";
    case TC_NOT_BOUND: return "not_bound";
    case TC_CLEANUP_REQUIRED: return "cleanup_required";
    case TC_BUSY: return "busy";
    case TC_DIAGNOSTIC_DISABLED: return "diagnostic_disabled";
    case TC_UNSUPPORTED: return "unsupported";
    case TC_CANDIDATE_REJECTED: return "candidate_rejected";
    case TC_CANDIDATE_UNREADABLE: return "candidate_unreadable";
    case TC_CANDIDATE_MISMATCH: return "candidate_mismatch";
    }
    return "unknown";
}
