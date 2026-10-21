/* Independently written, owned-process observation. No Darwin ABI guarantee. */
#include <stdio.h>
#include <stdlib.h>

#if !defined(__APPLE__) || !defined(__aarch64__)

int
main(void)
{
    puts("unsupported_platform PASS=0 FAIL=0");
    return 77;
}

#else

#include <limits.h>
#include <mach/kern_return.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#include "slot_contract.h"

enum { THREAD_COUNT = 3, WORKER_COUNT = 2, SLOT_COUNT = 3, VERSION_COUNT = 2 };
enum { GUEST_SLOT_0 = 0, GUEST_SLOT_1 = 1, HOST_CONTROL_SLOT = 2 };

_Static_assert(CHAR_BIT == 8, "The experiment requires eight-bit bytes.");
_Static_assert(sizeof(uintptr_t) == 8, "The experiment requires 64-bit pointers.");
_Static_assert(sizeof(void *) == 8, "The experiment requires 64-bit pointers.");
_Static_assert(sizeof(vm_address_t) >= sizeof(uintptr_t),
               "The Mach address type must hold a process address.");

struct totals {
    unsigned pass;
    unsigned fail;
};

struct participant {
    unsigned index;
    struct totals api;
    struct totals candidate;
    struct totals isolation;
    struct totals lifetime;
};

struct owned_sentinel {
    unsigned char identity;
};

static pthread_key_t owned_keys[SLOT_COUNT];
static struct owned_sentinel sentinels[THREAD_COUNT][SLOT_COUNT][VERSION_COUNT];
static _Atomic unsigned destructor_calls[THREAD_COUNT][SLOT_COUNT][VERSION_COUNT];
static _Atomic unsigned unexpected_destructor;
static _Atomic unsigned destructor_nonnull_key;

/* Start/abort gate and reusable rendezvous, avoiding pthread_barrier on Apple. */
static pthread_mutex_t sync_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sync_condition = PTHREAD_COND_INITIALIZER;
static bool start_allowed;
static bool start_aborted;
static unsigned arrived;
static unsigned generation;

static void
record(struct totals *totals, bool condition)
{
    if (condition) {
        ++totals->pass;
    } else {
        ++totals->fail;
    }
}

static void
require_sync(int result)
{
    if (result != 0) {
        /* A broken primitive cannot safely support further synchronization. */
        fputs("synchronization PASS=0 FAIL=1\n", stderr);
        exit(EXIT_FAILURE);
    }
}

static bool
await_start(void)
{
    bool proceed;
    require_sync(pthread_mutex_lock(&sync_mutex));
    while (!start_allowed && !start_aborted) {
        require_sync(pthread_cond_wait(&sync_condition, &sync_mutex));
    }
    proceed = !start_aborted;
    require_sync(pthread_mutex_unlock(&sync_mutex));
    return proceed;
}

static void
release_start(bool abort_start)
{
    require_sync(pthread_mutex_lock(&sync_mutex));
    start_aborted = abort_start;
    start_allowed = !abort_start;
    require_sync(pthread_cond_broadcast(&sync_condition));
    require_sync(pthread_mutex_unlock(&sync_mutex));
}

static void
rendezvous(void)
{
    unsigned previous_generation;
    require_sync(pthread_mutex_lock(&sync_mutex));
    previous_generation = generation;
    ++arrived;
    if (arrived == THREAD_COUNT) {
        arrived = 0;
        ++generation;
        require_sync(pthread_cond_broadcast(&sync_condition));
    } else {
        while (generation == previous_generation) {
            require_sync(pthread_cond_wait(&sync_condition, &sync_mutex));
        }
    }
    require_sync(pthread_mutex_unlock(&sync_mutex));
}

static uintptr_t
read_thread_pointer(void)
{
    uintptr_t value;
    /* Read only: this experiment never writes a TLS register or x18. */
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(value));
    return value;
}

static bool
candidate_matches(unsigned slot, void *expected)
{
    uintptr_t address;
    uintptr_t copied_value = 0;
    vm_size_t copied_size = 0;
    kern_return_t result;

    /* slot is an index into only this program's successfully allocated keys. */
    if (slot >= SLOT_COUNT ||
        !slot_candidate_address(read_thread_pointer(),
                                (uintmax_t)owned_keys[slot], &address)) {
        return false;
    }
    /*
     * The candidate is never dereferenced. A failed layout assumption is an
     * ordinary failed VM read or comparison, not an unchecked pointer load.
     * Exactly eight bytes are requested from our own task, never another task.
     */
    result = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                              (vm_size_t)sizeof(copied_value),
                              (vm_address_t)(uintptr_t)&copied_value,
                              &copied_size);
    return result == KERN_SUCCESS && copied_size == sizeof(copied_value) &&
           copied_value == (uintptr_t)expected;
}

static void
owned_destructor(void *value)
{
    unsigned thread;
    unsigned slot;
    unsigned version;

    /* Compare identities without dereferencing the callback's input pointer. */
    for (thread = 0; thread < THREAD_COUNT; ++thread) {
        for (slot = 0; slot < SLOT_COUNT; ++slot) {
            for (version = 0; version < VERSION_COUNT; ++version) {
                if (value == &sentinels[thread][slot][version]) {
                    atomic_fetch_add(&destructor_calls[thread][slot][version], 1);
                    if (pthread_getspecific(owned_keys[slot]) != NULL) {
                        atomic_fetch_add(&destructor_nonnull_key, 1);
                    }
                    return;
                }
            }
        }
    }
    atomic_fetch_add(&unexpected_destructor, 1);
}

static bool
no_destructors_yet(void)
{
    unsigned thread;
    unsigned slot;
    unsigned version;
    if (atomic_load(&unexpected_destructor) != 0 ||
        atomic_load(&destructor_nonnull_key) != 0) {
        return false;
    }
    for (thread = 0; thread < THREAD_COUNT; ++thread) {
        for (slot = 0; slot < SLOT_COUNT; ++slot) {
            for (version = 0; version < VERSION_COUNT; ++version) {
                if (atomic_load(&destructor_calls[thread][slot][version]) != 0) {
                    return false;
                }
            }
        }
    }
    return true;
}

static void
verify_slots(struct participant *self, void *const expected[SLOT_COUNT],
             bool check_isolation)
{
    unsigned slot;
    for (slot = 0; slot < SLOT_COUNT; ++slot) {
        void *actual = pthread_getspecific(owned_keys[slot]);
        record(&self->api, actual == expected[slot]);
        /* Check both the API result and the independently expected identity. */
        record(&self->candidate, candidate_matches(slot, actual));
        if (check_isolation) {
            record(&self->isolation, actual == expected[slot]);
        }
    }
}

static void
exercise_slots(struct participant *self)
{
    void *expected[SLOT_COUNT] = { NULL, NULL, NULL };
    unsigned slot;
    unsigned actor;

    verify_slots(self, expected, false);
    for (slot = 0; slot < SLOT_COUNT; ++slot) {
        expected[slot] = &sentinels[self->index][slot][0];
        record(&self->api, pthread_setspecific(owned_keys[slot], expected[slot]) == 0);
    }
    rendezvous();
    verify_slots(self, expected, true);

    /*
     * One thread changes one owned key at a time. Every thread verifies all
     * three keys after each change, including the two untouched synthetic
     * guest/control slots and the other threads' unchanged local identities.
     */
    for (actor = 0; actor < THREAD_COUNT; ++actor) {
        for (slot = GUEST_SLOT_0; slot <= HOST_CONTROL_SLOT; ++slot) {
            if (self->index == actor) {
                expected[slot] = NULL;
                record(&self->api, pthread_setspecific(owned_keys[slot], NULL) == 0);
            }
            rendezvous();
            verify_slots(self, expected, true);
            if (self->index == actor) {
                expected[slot] = &sentinels[self->index][slot][1];
                record(&self->api,
                       pthread_setspecific(owned_keys[slot], expected[slot]) == 0);
            }
            rendezvous();
            verify_slots(self, expected, true);
        }
    }

    rendezvous();
    record(&self->lifetime, no_destructors_yet());
    /* Main returns normally, so explicitly clear its values before key deletion. */
    if (self->index == 0) {
        for (slot = 0; slot < SLOT_COUNT; ++slot) {
            expected[slot] = NULL;
            record(&self->api, pthread_setspecific(owned_keys[slot], NULL) == 0);
        }
    }
    rendezvous();
    verify_slots(self, expected, true);
    record(&self->lifetime, no_destructors_yet());
    /* Nobody may exit and invoke a destructor before all zero-count checks. */
    rendezvous();
}

static void *
worker_main(void *argument)
{
    struct participant *self = argument;
    if (await_start()) {
        exercise_slots(self);
    }
    return NULL;
}

static void
add_totals(struct totals *sum, const struct totals *part)
{
    sum->pass += part->pass;
    sum->fail += part->fail;
}

static void
print_totals(const char *label, const struct totals *totals)
{
    printf("%s PASS=%u FAIL=%u\n", label, totals->pass, totals->fail);
}

int
main(void)
{
    struct participant participants[THREAD_COUNT] = { 0 };
    pthread_t workers[WORKER_COUNT];
    struct totals setup = { 0, 0 };
    struct totals api = { 0, 0 };
    struct totals candidate = { 0, 0 };
    struct totals isolation = { 0, 0 };
    struct totals lifetime = { 0, 0 };
    unsigned keys_created = 0;
    unsigned workers_created = 0;
    unsigned thread;
    unsigned slot;
    unsigned version;
    bool ran = false;
    bool joined_all = true;

    for (thread = 0; thread < THREAD_COUNT; ++thread) {
        participants[thread].index = thread;
        for (slot = 0; slot < SLOT_COUNT; ++slot) {
            for (version = 0; version < VERSION_COUNT; ++version) {
                sentinels[thread][slot][version].identity =
                    (unsigned char)(1 + thread * SLOT_COUNT * VERSION_COUNT +
                                    slot * VERSION_COUNT + version);
            }
        }
    }
    for (slot = 0; slot < SLOT_COUNT; ++slot) {
        int result = pthread_key_create(&owned_keys[slot], owned_destructor);
        record(&setup, result == 0);
        if (result != 0) {
            goto cleanup;
        }
        ++keys_created;
        record(&setup, (uintmax_t)owned_keys[slot] < SLOT_CONTRACT_KEY_LIMIT);
        if ((uintmax_t)owned_keys[slot] >= SLOT_CONTRACT_KEY_LIMIT) {
            goto cleanup;
        }
    }
    record(&setup, owned_keys[GUEST_SLOT_0] != owned_keys[GUEST_SLOT_1] &&
                   owned_keys[GUEST_SLOT_0] != owned_keys[HOST_CONTROL_SLOT] &&
                   owned_keys[GUEST_SLOT_1] != owned_keys[HOST_CONTROL_SLOT]);
    if (setup.fail != 0) {
        goto cleanup;
    }
    for (thread = 0; thread < WORKER_COUNT; ++thread) {
        int result = pthread_create(&workers[thread], NULL, worker_main,
                                    &participants[thread + 1]);
        record(&setup, result == 0);
        if (result != 0) {
            break;
        }
        ++workers_created;
    }
    /* Partial creation must release waiting workers, then join and clean keys. */
    release_start(workers_created != WORKER_COUNT);
    if (workers_created == WORKER_COUNT) {
        exercise_slots(&participants[0]);
        ran = true;
    }
    for (thread = 0; thread < workers_created; ++thread) {
        int result = pthread_join(workers[thread], NULL);
        record(&setup, result == 0);
        if (result != 0) {
            joined_all = false;
        }
    }
    if (!joined_all) {
        /* Do not delete keys or destroy primitives potentially still in use. */
        print_totals("setup", &setup);
        return EXIT_FAILURE;
    }
    if (ran) {
        for (thread = 0; thread < THREAD_COUNT; ++thread) {
            add_totals(&api, &participants[thread].api);
            add_totals(&candidate, &participants[thread].candidate);
            add_totals(&isolation, &participants[thread].isolation);
            add_totals(&lifetime, &participants[thread].lifetime);
            for (slot = 0; slot < SLOT_COUNT; ++slot) {
                for (version = 0; version < VERSION_COUNT; ++version) {
                    unsigned expected_count = thread != 0 && version == 1 ? 1 : 0;
                    record(&lifetime,
                           atomic_load(&destructor_calls[thread][slot][version]) ==
                           expected_count);
                }
            }
        }
        record(&lifetime, atomic_load(&unexpected_destructor) == 0);
        record(&lifetime, atomic_load(&destructor_nonnull_key) == 0);
        for (slot = 0; slot < SLOT_COUNT; ++slot) {
            record(&api, pthread_getspecific(owned_keys[slot]) == NULL);
            record(&candidate, candidate_matches(slot, NULL));
        }
    }

cleanup:
    for (slot = 0; slot < keys_created; ++slot) {
        record(&setup, pthread_key_delete(owned_keys[slot]) == 0);
    }
    record(&setup, pthread_cond_destroy(&sync_condition) == 0);
    record(&setup, pthread_mutex_destroy(&sync_mutex) == 0);
    print_totals("setup", &setup);
    print_totals("pthread_api", &api);
    print_totals("candidate_layout", &candidate);
    print_totals("slot_isolation", &isolation);
    print_totals("destructor_lifetime", &lifetime);
    return ran && setup.fail == 0 && api.fail == 0 && candidate.fail == 0 &&
           isolation.fail == 0 && lifetime.fail == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

#endif
