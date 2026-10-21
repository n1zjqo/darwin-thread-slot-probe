# Owned fixed-word ARM64 native test: source preparation only

Status: NOT BUILT OR RUN ON APPLE. No CI, publication, installation, emulator or
ARM execution occurred in this stage. A later Apple build/run requires separate
explicit authorization. The current checks are stdlib-only structural inspection
and comparison against fixed, independently reviewed expected instruction words.

## Candidate changes for later approval

The lists below are relative to the local preparation baseline. In the intended
public baseline, tests/check_project.py is absent and therefore counts as a new
file. The public source subset is seven additions plus one project modification.
Adding the separately prepared workflow would make eight additions plus one
modification, nine paths total. No publication is authorized by this document.

New project files in the local preparation baseline:
1. Switch2IOSTests/X18NativeFixture.h
2. Switch2IOSTests/X18NativeFixture.c
3. Switch2IOSTests/X18NativeFixture.S
4. Switch2IOSTests/X18NativeTests.m
5. tests/check_x18_native_fixture.py
6. X18-NATIVE-STAGE.md

Modified project files in the local preparation baseline:
1. Switch2IOS.xcodeproj/project.pbxproj: add the three compilable fixture sources
   to Switch2IOSTests only, plus their header/file references.
2. tests/check_project.py: add test-only membership and bridge-exclusion checks.

No production app source, production build phase, runtime C source, Swift bridge,
existing Swift test or target build setting changes. The 73 existing Swift test
methods remain byte-for-byte unchanged, but have NOT been rerun here. The source preparation preserved the existing production sources and test methods.

## Narrow native contract

The proposed platform is iOS Simulator ARM64, excluding arm64e, physical devices,
macOS and x86 simulators. Unsupported-platform XCTest paths explicitly fail; there
is no successful fallback. TargetConditionals guards agree across C/header/assembly.

Twelve ordinary C-callable assembly functions cover W/X, ADD/SUB and three fixed
operand layouts: write virtual guest18 from x10/x11, read virtual guest18 into
x10 with x11, and repeated virtual guest18 in all three operand positions. Caller-
saved x9 is always scratch. The code consists of static .long words compiled into
the test executable, never JIT output or writable executable memory. There is no
file-supplied instruction stream, game adapter, trampoline, TLS bridge or runtime
patch API. A bounded C selector returns only these fixed functions, or NULL for
invalid selectors. Tests never call a rejected function pointer.

A 16-byte-aligned 352-byte POD packet contains a 32-byte private context at offset0,
inputs at32..56, captured outputs at64..120, caller-probe register banks at128 and
208, SP captures at288/296, frame canaries at304/312, frame-pointer captures at
320/328 and expected/observed return links at336/344. The header has exact sizeof,
alignment and offsetof assertions for every field. Context cells are virtual
guest18, scratch save, virtual guest28 and a guard, each eight bytes.

Each fixed helper uses a 32-byte aligned stack frame, saves/restores x28/x29/x30,
and points x29 at its actual saved frame record. x0 retains the packet address.
x28 temporarily points to the owned context; x9/x10/x11 contain fixture operands.
NZCV is seeded immediately before the four/five-word body and sampled immediately
after it. Full64 scratch save/restore surrounds W operations too. The helper does
not touch x19..x27. No assembly instruction references physical x18 at all; its
preservation is a static exclusion claim, NOT a directly sampled native result.

The dedicated caller probe saves x19..x30 in a 128-byte frame, with the real
x29/x30 frame record at SP+80 and x29 set to that address. It stores the packet and
function pointers in stack slots, seeds x19..x28 with distinct 64-bit sentinels
whose upper halves are nonzero, calls one fixed helper, captures the bank, checks
frame/return observations through XCTest, and restores the original saved bank.
Its stack is 16-byte aligned at the call. CFI describes the SP-based saved state;
actual Apple assembler acceptance and unwind behavior remain unverified.

## Intended checks versus current evidence

The proposed XCTest matrix has 1,728 cases: twelve helpers, all sixteen NZCV values
and nine boundary-value rotations. Unsigned C reference arithmetic avoids signed
overflow and checks full-width scratch restoration and W zero-extension. Tests
compare the entire context, all input/non-output packet bytes, captured arithmetic
registers and flags, all ten callee-saved sentinels, SP/frame/return captures and
leading/trailing packet canaries. Additional tests cover two disjoint owned packets
and invalid selectors. No unsafe fault, misaligned-pointer, reentry or arbitrary
code test is executed by this native fixture.

Current source-only checks verified twelve literal bodies (56 instruction words)
against independently reviewed fixed constants, project membership, POD offset declarations,
stack/frame patterns, architecture guards, physical-x18 exclusion and unchanged
baseline sources. These checks do not compile C, Objective-C, assembly or Swift.
They cannot establish successful ABI execution, actual register preservation,
code signing, simulator availability or hardware correctness.

Run current allowed static checks with ordinary Python:

    PYTHONDONTWRITEBYTECODE=1 python ios/tests/check_project.py
    PYTHONDONTWRITEBYTECODE=1 python ios/tests/check_x18_native_fixture.py

The public checker is self-contained and uses only the Python standard library.
It contains fixed expected words for these twelve owned helpers. The expected
constants were separately compared with the reviewed pure Python emitter during
source preparation; that private preparation machinery is not a public dependency.

After a separately authorized Apple assembly step, an optional read-only check is:

    python ios/tests/check_x18_native_fixture.py --object /path/to/X18NativeFixture.o

This mode accepts only the specifically named owned, thin little-endian ARM64
Mach-O relocatable object. It bounds load commands, sections, symbols and file
ranges, resolves the exact helper symbols and compares their body bytes at the
source-verified 48-byte prologue offset. It distinguishes section virtual addresses
from file offsets. Any text-section relocation is rejected; this fixture has no
external direct calls or symbolic body operands. The check covers raw relocation-
free body bytes only, not helper/probe prologue bytes, linked output, or ABI behavior.
Missing, malformed, ambiguous or mismatching objects fail rather
than silently skipping checks. With no object argument, the report explicitly
records object verification as NOT_RUN. No object has been assembled or inspected
as Apple build evidence in this source-only stage; byte inspection is not execution.
