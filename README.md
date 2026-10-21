# Darwin thread-slot probe

A small, owned-code experiment for observing Darwin thread behavior and checking a portable slot contract. It is not an application or a compatibility claim.

The three C source/header files are newly written, independent test code. They do not recover, reconstruct, or incorporate another application's source. The experiment does not execute an application, guest machine, JIT, or emulator.

## Hypothesis and limits

On Darwin ARM64 only, the probe tests this candidate address for each of three keys it allocated successfully with `pthread_key_create`:

```
(TPIDRRO_EL0 & ~7) + pthread_key * 8
```

This is deliberately an empirical hypothesis, not a documented Apple TLS ABI or a recommendation to use it in production. No conclusion applies to other keys, processes, architectures, OS versions, or guest workloads. A successful result establishes only the observations in that single process and run. A failing candidate read or mismatch causes a nonzero exit; the probe does not guess another layout.

The API result from `pthread_getspecific` is the reference. The candidate calculation rejects null bases, keys at or above 1024, null output arguments, and arithmetic overflow, including the complete eight-byte read range. It never directly dereferences a candidate address. Instead, it requests exactly eight bytes from its own task with [`vm_read_overwrite`](https://developer.apple.com/documentation/kernel/1585371-vm_read_overwrite), declared in `mach/vm_map.h`. A readable candidate alone does not establish that the layout is correct. Because the layout is the hypothesis, a failed hypothesis could inspect eight bytes of unrelated memory within this same process; the bytes are never printed or exported.

No real host TLS register or x18 is written. “Guest slots” and “host control” below are labels for ordinary, separately allocated pthread keys, not actual guest or host runtime integration. No security settings, other processes, credentials, or existing application sources are accessed.

## What the probe checks

- Main plus two worker threads share three owned keys: two synthetic guest slots and one host-control slot.
- Each thread/slot/version has a distinct, owned sentinel object. Each thread initially sees null, then only its own installed values.
- One thread and one key at a time are cleared and reinstalled. All three threads check their own complete set of keys after each change, checking both slot separation and thread-local isolation.
- Clearing and replacing values must not invoke destructors. Worker exit must invoke each installed value's destructor exactly once, with the key already null. Cleared/old values and main-thread values must not receive a destructor callback.
- Workers synchronize with a mutex and condition variable, not an Apple-unsupported pthread barrier. Partial thread creation aborts the start gate, joins every created worker, and deletes allocated keys. All keys are deleted after normal joins.

The program prints only generic category names and PASS/FAIL counts, never addresses or sentinel values. A zero exit means all executed checks passed. A nonzero exit means a setup/check failure; zero counts in an unexecuted category are not a pass. Unsupported platforms, including Linux, print `unsupported_platform PASS=0 FAIL=0` and return 77. A broken synchronization primitive terminates the process with a generic failure rather than continuing unsafely.

## Local builds

Portable arithmetic tests need only a C11 compiler:

```
cc -std=c11 -Wall -Wextra -Werror -O2 test_slot_contract.c -o /tmp/test-slot-contract
/tmp/test-slot-contract
```

On a Darwin ARM64 host:

```
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O2 -arch arm64 probe.c -o /tmp/thread-slot-probe
/tmp/thread-slot-probe
```

The portable tests cover every candidate key below 1024 with all eight low-bit patterns, invalid keys/null inputs, output preservation on failure, and address-space upper boundaries. They validate integer arithmetic only, not the Darwin hypothesis.

No iOS device execution is claimed or performed by the supplied workflow. Even a successful iPhoneOS SDK compile/link is not evidence that this hypothesis works on iOS. Any later macOS or iOS compatibility claim would need separately scoped execution evidence on the relevant platform.

## Scope

Only five files belong in this public repository:

- `probe.c`: self-contained owned probe.
- `slot_contract.h`: portable slot-contract definitions.
- `test_slot_contract.c`: focused portable contract tests.
- `README.md`: this description.
- `.github/workflows/probe-once.yml`: the one-shot validation workflow.

No application assets, private repository history, credentials, private logs, or private paths belong here. Probe sources must be reviewed before publication.

## One-shot validation

The workflow permits only the first push-triggered workflow run and its first attempt, on `main` in `n1zjqo/darwin-thread-slot-probe`, while that repository is public. The head commit message must contain `[approved-public-probe-once-20261021]`. There is no manual trigger. Later pushes and reruns cannot execute the job without changing the guards.

The single standard `macos-15` ARM64 job has a 15-minute limit. It fetches only the current public commit without authentication, rejects files outside the exact allowlist, builds and runs the contract tests, and executes the owned macOS probe once. Contract-test execution has a 30-second limit; probe execution has a 60-second limit. Individual steps also have two-minute limits.

The final step only compiles and links the same owned probe for the iPhoneOS SDK, targeting ARM64 with an iOS 15.0 deployment minimum. It does not execute on iOS, use a simulator, install on a device, sign for distribution, or establish compatibility with any device or OS version.

No package installation, configured secrets, artifact uploads, releases, or deployments are used. The workflow token has no permissions; repository retrieval is public and unauthenticated. Only the generic validation output appears in the public Actions logs.
