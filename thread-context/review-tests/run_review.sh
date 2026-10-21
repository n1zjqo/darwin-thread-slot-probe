#!/bin/sh
# Independent source-only regression checks. All binaries stay in a temporary directory.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/thread-context-review.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
cc=${CC:-cc}
cxx=${CXX:-c++}
mode=${1:-all}

strict() {
    "$cc" -std=c11 -Wall -Wextra -Wpedantic -Werror -pthread -fanalyzer \
        -I"$root/include" -c "$root/src/thread_context.c" -o "$build/context.o"
    "$cc" -std=c11 -Wall -Wextra -Wpedantic -Werror -pthread \
        -DTC_ENABLE_DARWIN_DIAGNOSTIC=1 -I"$root/include" \
        -c "$root/src/thread_context.c" -o "$build/diagnostic.o"
    "$cxx" -std=c++17 -Wall -Wextra -Wpedantic -Werror -pthread \
        -I"$root/include" "$root/review-tests/cpp_backend.cpp" "$build/context.o" \
        -o "$build/cpp_backend"
    "$build/cpp_backend"
    printf '%s\n' 'strict C11/analyzer, diagnostic-enabled Linux compile, and C++17 linkage passed'
}

asan() {
    "$cc" -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread \
        -fsanitize=address,undefined -fno-omit-frame-pointer -I"$root/include" \
        "$root/src/thread_context.c" "$root/review-tests/stress.c" -o "$build/asan"
    # LeakSanitizer cannot initialize under this executor's ptrace supervision.
    ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$build/asan"
    "$cc" -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread \
        -fsanitize=address,undefined -fno-omit-frame-pointer -I"$root/include" \
        "$root/src/thread_context.c" "$root/tests/test_thread_context.c" -o "$build/fault-asan"
    ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$build/fault-asan"
    "$cc" -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread \
        -fsanitize=address,undefined -fno-omit-frame-pointer -I"$root/include" \
        "$root/src/thread_context.c" "$root/review-tests/cancel_transition.c" -o "$build/cancel-asan"
    ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$build/cancel-asan"
}

tsan() {
    "$cc" -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread \
        -fsanitize=thread -I"$root/include" "$root/src/thread_context.c" \
        "$root/review-tests/stress.c" -o "$build/tsan"
    TSAN_OPTIONS=halt_on_error=1 "$build/tsan"
    "$cc" -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread \
        -fsanitize=thread -I"$root/include" "$root/src/thread_context.c" \
        "$root/tests/test_thread_context.c" -o "$build/fault-tsan"
    TSAN_OPTIONS=halt_on_error=1 "$build/fault-tsan"
    "$cc" -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread \
        -fsanitize=thread -I"$root/include" "$root/src/thread_context.c" \
        "$root/review-tests/cancel_transition.c" -o "$build/cancel-tsan"
    TSAN_OPTIONS=halt_on_error=1 "$build/cancel-tsan"
}

case "$mode" in
    strict) strict ;;
    asan) asan ;;
    tsan) tsan ;;
    all) strict; asan; tsan ;;
    *) printf '%s\n' "Usage: $0 [all|strict|asan|tsan]" >&2; exit 2 ;;
esac
