# Owned thread-context lifecycle component

This is a new, isolated C11/POSIX component, not application integration. It owns
three successfully allocated pthread keys and its own small per-thread lifecycle
record. Two keys hold borrowed, synthetic `guest_tls` and `readonly_tls` values;
the third holds the record and its exit destructor. Names do not make these real
guest registers or protect memory against writes. Values are never dereferenced
or freed by the component.

The default backend uses only `pthread_key_create`, `pthread_setspecific`,
`pthread_getspecific`, and `pthread_key_delete` for TLS access. There is no guest
execution, machine-code patching, HLE registration, register write, launch hook,
game asset, credential, or recovered application source.

## Build and test

```sh
make test
make test-diagnostic
```

Requires an existing C11 compiler, C++17 compiler (linkage smoke test), `ar`,
`make`, and pthreads. No dependency installation or network access is used.
`build/libthread_context.a` is the default portable library. The diagnostic
executable is separate; its build does not enable diagnostics in that library.

`test-diagnostic` builds with `TC_ENABLE_DARWIN_DIAGNOSTIC=1`. On unsupported
platforms the diagnostic API returns `TC_UNSUPPORTED`, while ordinary lifecycle
behavior remains available. On Darwin ARM64 it attempts the diagnostic and
prints only result categories; mismatch/read failure/rejection are supported
outcomes and do not turn this lifecycle suite into an ABI compatibility test.

Public API: `include/thread_context.h`. Optional backend/fault-test seam:
`include/thread_context_backend.h`. C and C++ callers can link the C library.

## Lifecycle contract

1. A supervisor creates a manager with no concurrent use or cancellation during
   create/destroy. Each worker calls `tc_bind(manager, values)` on itself.
2. Both borrowed values must be non-NULL. Keep their backing storage alive through
   successful `tc_unbind` or the thread's completed exit/join. In particular, do
   not supply expiring worker-stack storage for values needed at TLS teardown.
3. `tc_get` returns both calling-thread values only for a fully bound context.
   Double bind is rejected. A second manager on the same thread is independent.
4. `tc_unbind` clears both value keys, then the owner key, then frees the record.
   Normal return, `pthread_exit`, and deferred cancellation use the owner-key
   destructor if a record remains bound. No user callback is invoked.
5. Join workers and prove there are no outstanding calls/destructors before
   destroying the manager. The live-record counter rejects obvious busy cases;
   it is not a lock or a concurrent manager-admission protocol.

`TC_BACKEND_ERROR` after failed bind means rollback succeeded and no association
remains. `TC_CLEANUP_REQUIRED` after bind/unbind means the record is still owned
by the thread and getters hide the partial state. Keep borrowed values alive,
then retry `tc_unbind` or complete the thread's exit/join. Do not assume a failed
operation left a usable previous binding. A second `tc_bind` is rejected until
cleanup succeeds.

If key creation fails, allocated keys are deleted. If deletion itself fails,
create returns `TC_CLEANUP_REQUIRED` with a disabled manager instead of silently
losing its remaining keys. A partial failed destroy similarly leaves a disabled
manager. Only statistics and destroy retry are valid on that handle; successful
destroy sets it to NULL.

Deferred cancellation is masked through bind/unbind transitions, including
rollback. A pending cancellation can be delivered when cancellation is restored
or at a later cancellation point. An attached record remains reachable by the
destructor. Async cancellation, signal-handler use, reentrant backend callbacks,
and access from other TLS destructors are not supported. Thread exit clears
borrowed slots best-effort, counts failures, and frees only its own record after
pthread already cleared its owner key. Residual borrowed pointers vanish with
thread termination; they are not accessed/freed here. Statistics distinguish
cleanup errors from successful resource release. Counters are individually
atomic, not an atomic snapshot.

The optional backend must obey actual pthread key/destructor behavior, provide
zero-filled allocation, and leave state unchanged on failed create/set/delete.
It must outlive all workers and support their concurrent use. Fault backends in
the tests are deliberately confined to a single worker at a time.

## Diagnostic, not fast-path authorization

Both the compile-time macro and `tc_options.allow_darwin_slot_diagnostic` must be
enabled. For the calling thread's two owned keys only, the diagnostic checks the
candidate `(TPIDRRO_EL0 & ~7) + key * 8`. Arithmetic rejects zero bases, keys at or
above 1024, and overflow including the entire eight-byte read. A checked
same-process `vm_read_overwrite` copies exactly eight bytes and compares them
with `pthread_getspecific`. No candidate address is directly dereferenced,
returned, cached, or written. No TLS register or x18 is changed.

This is an undocumented layout hypothesis. A mistaken hypothesis can read eight
bytes of unrelated memory in the same process; those bytes are not logged or
exported. A successful comparison proves only those two observations in that
thread at that instant. It does not permit raw slot loads, establish a stable
offset contract, prove signal safety, establish exclusive-monitor behavior, or
make another OS/version/device compatible. A failure leaves the ordinary pthread
binding unchanged. See `docs/INTEGRATION_GATES.md` before any further integration.

## Evidence and validation limits

The separate, previously approved public experiment at commit
`caa7e507fdcee81e3df4a7cd721cdb31f5a54f54`,
[run 39529797371](https://github.com/n1zjqo/darwin-thread-slot-probe/actions/runs/39529797371),
succeeded on macOS 15.7.9 ARM64. It also compiled/linked that experiment against
iPhoneOS SDK 18.5 with minimum iOS 15.0, without executing on iOS. That evidence
belongs to that public probe, not this new component. It is not a portable ABI
guarantee and was not rerun as part of this work.

Current component validation is local Linux x86_64/GCC 14.2.0: strict warnings,
C/C++ linkage, real pthread lifecycle/isolation, deterministic faults, and
sanitizers. No Apple compiler/SDK is present here, so this component's Darwin
branch, iOS compilation, and device behavior have not been verified. See
`docs/VALIDATION.md` for exact checks and limits.

## Separately approved one-shot macOS validation

The repository's `context-once.yml` workflow is limited to its first push run and
first attempt on public `main`, at the approved base commit and commit marker.
It verifies the exact file allowlist and that none of the existing public probe
files changed. It retrieves only the exact public commit without authentication.
One standard `macos-15` ARM64 job is capped at 15 minutes; every step and test
process has an additional limit. No PR/manual trigger, package installation,
configured secrets, artifact upload, release, or deployment is used.

The workflow builds and executes the owned lifecycle, arithmetic, isolation,
fault/cancellation, stress, and C++ linkage tests in default and diagnostic-opt-in
modes. A diagnostic mismatch is recorded, not treated as a portable ABI failure.
It also compiles C/C++ objects against the iPhoneOS SDK in both modes; those
objects are not linked into an application, signed, installed, or executed. The
initial local results above remain Linux evidence until a specific subsequent
run supplies separately identified Apple results. Public logs contain build
commands, generic test counts/statuses, and toolchain information, not test
addresses or borrowed values.
