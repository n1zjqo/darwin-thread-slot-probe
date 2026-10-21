# Independent lifecycle regression checks

These source-only checks exercise the isolated thread-context component. They do
not wire a loader, rewriter, application launch path, or guest execution. Test
binaries are created under a temporary directory and removed by the runner.

## Run

From the component directory on the reviewed Linux/GCC environment:

```sh
make test test-diagnostic
./review-tests/run_review.sh all
```

The runner accepts `strict`, `asan`, or `tsan` to run a subset. `CC` and `CXX` may
be set explicitly; the strict pass uses GCC's `-fanalyzer`, not a portable Clang
flag. The actual reviewed compiler is GCC/G++ 14.2.0, Debian 14.2.0-19.

## Retained tests

- `stress.c`: 12 concurrent threads and 8,000 binding cycles each, repeated three
  times: 288,000 successful binds, 18 ordinary thread-exit releases, and three
  additional deferred-cancellation exits. Verifies isolation, repeated bind
  rejection, get/unbind behavior, exact counters after joins, and destruction.
- `cancel_transition.c`: 12 cases requesting deferred cancellation while each
  guest/readonly/owner unbind clear is in progress, with and without a clear
  failure and with initially enabled/disabled cancellation. Verifies preserved
  caller cancellation state, correct explicit-versus-exit release accounting,
  recovery of retained records, and balanced fixture allocations/frees.
- `cpp_backend.cpp`: C++17 caller linked against the C implementation, using both
  the public backend factory and manager-creation seam.
- The sanitizer passes additionally compile and run the implementation owner's
  full `tests/test_thread_context.c` fault/lifecycle suite.

## Verification results

Initial review on 2026-10-21 in a Linux environment, before the separately
approved one-shot macOS workflow:

- Strict C11 compilation with warnings-as-errors and GCC static analysis: passed.
- Diagnostic-enabled Linux compilation: passed. This checks the unsupported
  platform branch, not the Darwin implementation.
- C++17 backend linkage: initially failed because the backend header lacked C
  linkage guards; corrected guards were independently retested successfully.
- Stress, cancellation-transition, and full fault/lifecycle suites under
  AddressSanitizer plus UndefinedBehaviorSanitizer: passed with
  `ASAN_OPTIONS=detect_leaks=0:abort_on_error=1` and
  `UBSAN_OPTIONS=halt_on_error=1`.
- The same three suites under ThreadSanitizer: passed with
  `TSAN_OPTIONS=halt_on_error=1`.
- LeakSanitizer: not verified. Its initial run terminated with
  `LeakSanitizer does not work under ptrace (strace, gdb, etc)` in this executor.
  Leak detection was disabled for subsequent AddressSanitizer runs; a sanitizer
  leak pass is not claimed. Fixture allocation counters are a separate bounded
  check, not a substitute for a working leak detector.
- Apple SDK compilation, Darwin/arm64 device execution, actual slot-layout
  validation, Xcode integration, game execution, publication, and CI: not run.

## Review conclusions and contract

The manager is opaque and all routine access uses `pthread_getspecific`. Each
manager owns its three created keys; an owner record remains reachable after a
failed partial rollback, and cleanup retry/exit tests verify its release. The
component never dereferences or frees either borrowed value. `readonly_tls` and
`guest_tls` are labels only, not guest-machine or memory-protection semantics.

Destruction requires external exclusion of all component calls and completed
worker/destructor activity. The live count is not concurrent admission control.
Deferred cancellation is masked during transitions; asynchronous cancellation,
signal-handler use, and use from another TLS destructor are outside contract.
No lifecycle defect was reproduced within that contract in these bounded tests.

The Darwin diagnostic must remain compile-time and runtime opt-in, checking only
owned keys. A rejected, unreadable, or mismatching candidate is a supported
nonfatal result and must not turn into a raw-load fast path. The ordinary binding
must remain usable after the diagnostic. The portable test must not require a
specific Darwin slot layout; target-specific matching is separate evidence.

## Final review disposition

Both concrete findings are resolved: the backend API now has C++ linkage guards,
and the Darwin-arm64 diagnostic test now accepts supported candidate failures
while checking that the ordinary binding remains usable. Supervisor exclusion,
join-before-destroy, and `TC_BUSY` versus `TC_CLEANUP_REQUIRED` behavior are
explicitly documented. No unresolved concrete defect was found in this review.

The final implementation SHA-256 remains
`7a68a2e96509c200f64d6d9707d3f58d4b7d065adcea84a153c00da1d19279f0`,
identical to the implementation used in all independent sanitizer passes. Final
changes after those passes were linkage guards, contract documentation, and a
Darwin-only test branch; the linkage guard fix was independently rerun. The
Darwin branch was source-reviewed, not compiled or executed here. The implementation digest above identifies the reviewed core source.
