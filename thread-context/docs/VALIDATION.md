# Local validation, 2026-10-21 UTC

Environment: Linux x86_64, GCC/G++ 14.2.0. No Apple SDK/compiler or iOS device.

## Passed on the component

- `make test test-diagnostic`, C11/C++17, `-Wall -Wextra -Werror -pedantic`.
- C static archive linked by a C++17 caller, including optional backend API.
- Main thread plus four simultaneous pthread workers, 500 bind/get/unbind cycles
  per worker, final installed values released by actual thread-exit destructors;
  two independent managers on the same thread; duplicate/repeated operations.
- Injected manager/record allocation failure; each of three key-create failures;
  partial-create deletion failure; each key-delete failure and destroy retry.
- Each owner/guest/readonly install failure; each rollback-clear failure;
  each explicit-unbind clear failure; hidden partial state; retryable cleanup.
- Deferred cancellation requested while transitions are masked: successful bind,
  failed bind with successful rollback, failed rollback with retained owner, and
  destructor borrowed-slot clear failure. Actual canceled-thread joins verify
  final record counts and balanced owned allocations/keys.
- Candidate arithmetic across all 1024 keys and eight low-bit patterns, null
  arguments/bases, upper address boundaries, overflow; fake checked-reader match,
  mismatch, unreadable, and rejected candidates. These are portable logic tests,
  not Darwin layout evidence.
- Default-disabled diagnostic and opt-in unsupported-platform fallback; ordinary
  pthread binding remains usable after diagnostic status returns.
- AddressSanitizer + UndefinedBehaviorSanitizer on the complete owned tests and
  diagnostic-fallback build, with `ASAN_OPTIONS=detect_leaks=0:halt_on_error=1`
  and `UBSAN_OPTIONS=halt_on_error=1`.
- ThreadSanitizer on the same complete owned tests and fallback build.

Strict/ASan/UBSan/TSan commands and output are retained locally in
`test-results/strict.log`, `asan-ubsan.log`, and `tsan.log`. Assertion totals vary
slightly with condition-variable wakeups; named test categories must all pass.
Injected-backend allocation/key accounting checks are not a general leak proof.

## Not claimed

- LeakSanitizer: disabled because this host's tracing environment blocks its
  initialization in the independent review harness. No leak-detector pass.
- Apple compilation/execution of this new component, iOS device execution,
  application integration, game execution, graphics, audio, filesystem/HLE,
  performance, signal/async-cancellation safety, or exclusive-monitor safety.
- Compatibility beyond the recorded previous public probe run. No CI or remote
  execution was started for this component.

## Reproduce sanitizer checks

```sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
make BUILD=build-asan \
  CFLAGS='-std=c11 -O1 -g -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined -fno-omit-frame-pointer' \
  CXXFLAGS='-std=c++17 -O1 -g -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined -fno-omit-frame-pointer' \
  LDFLAGS='-fsanitize=address,undefined' test test-diagnostic

make BUILD=build-tsan \
  CFLAGS='-std=c11 -O1 -g -Wall -Wextra -Werror -pedantic -fsanitize=thread' \
  CXXFLAGS='-std=c++17 -O1 -g -Wall -Wextra -Werror -pedantic -fsanitize=thread' \
  LDFLAGS='-fsanitize=thread' test test-diagnostic
```
