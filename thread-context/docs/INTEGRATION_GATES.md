# Explicit next integration gates

The module is standalone and intentionally not copied into any application.

1. Identify a real authorized native worker lifecycle in the available source.
   Define manager ownership, launch admission, worker lifetime, cancellation
   policy, and join-before-destroy responsibilities. A loader/rewriter/launch hook
   must actually exist in the authorized integration target; do not infer a
   runtime boundary from this standalone component.
2. Define what synthetic `guest_tls` and `readonly_tls` mean for that runtime,
   their backing storage/ownership, and error propagation. The current pointers
   are deliberately opaque and have no real guest semantics. Add an adapter
   only at those authorized lifecycle boundaries, initially using `tc_get`.
3. Compile this component, not merely the earlier public probe, against the
   chosen Apple SDK/toolchain with default pthread-only mode. Check C/ObjC++
   linkage and deployment minimums. No new CI run, publication, installation,
   paid service, signing, or device action is implicitly authorized here.
4. Run the owned lifecycle tests on each explicitly scoped target. An iOS SDK
   build is compile evidence only; device execution requires separate actual
   evidence. Validate cancellation/error behavior used by the application rather
   than assuming Linux tests establish Apple behavior.
5. If the candidate diagnostic is needed, enable it only in a separately scoped
   owned test. Record target OS/build/device, key allocation, per-thread values,
   and actual result categories. Any mismatch, read failure, unsupported target,
   or rejected key keeps the pthread path. An earlier macOS match cannot enable
   an iOS or production fast path.
6. Raw fast-slot loads, generated-code access, real register emulation, signal
   handlers, synchronous fault recovery, and exclusive-monitor semantics each
   need their own concrete correctness design and independent tests. They are
   not implemented or validated here. Do not patch instructions or register HLE
   as a side effect of this lifecycle component.

Stop at the first unavailable boundary. The completed deliverable is a tested
owned lifecycle primitive and diagnostic boundary, not an IPA or a runnable game.
