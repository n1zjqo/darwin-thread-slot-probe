#import <XCTest/XCTest.h>
#import "X18NativeFixture.h"
#include <string.h>

@interface X18NativeTests : XCTestCase
@end
@implementation X18NativeTests
- (void)testFixedOwnedNativeMatrix {
#if !S2I_X18_NATIVE_SUPPORTED
    XCTFail(@"Owned native fixture requires iOS Simulator ARM64, not device/arm64e; no successful fallback.");
    return;
#else
    static const uint64_t edges[] = {0, 1, UINT64_C(0x7fffffff), UINT64_C(0x80000000),
        UINT64_C(0xffffffff), UINT64_C(0x100000000), UINT64_C(0x7fffffffffffffff),
        UINT64_C(0x8000000000000000), UINT64_MAX};
    struct __attribute__((aligned(16))) Guarded { uint64_t head[2]; S2IX18Packet packet; uint64_t tail[2]; };
    _Static_assert(offsetof(struct Guarded, packet) == 16, "guard alignment");
    _Static_assert(offsetof(struct Guarded, tail) == 368, "trailing guard offset");
    for (unsigned selector = 0; selector < S2IX18Count; ++selector) {
        S2IX18Function function = s2i_x18_native_function(selector);
        XCTAssertTrue(function != NULL);
        if (function == NULL) return;
        for (unsigned flags = 0; flags < 16; ++flags) {
            for (unsigned index = 0; index < 9; ++index) {
                struct Guarded owned;
                memset(&owned, 0xcc, sizeof(owned));
                owned.head[0] = UINT64_C(0x13579bdf2468ace0);
                owned.head[1] = UINT64_C(0x1020304050607080);
                owned.tail[0] = UINT64_C(0xdeadbeefcafebabe);
                owned.tail[1] = UINT64_C(0x8877665544332211);
                S2IX18Packet *p = &owned.packet;
                p->context.guest18 = edges[index];
                p->context.scratch_save = UINT64_C(0xa5a5a5a55a5a5a5a);
                p->context.guest28 = UINT64_C(0x2819281928192819);
                p->context.guard = UINT64_C(0xd00dfacefeedbabe);
                p->initial9 = UINT64_C(0xfedcba9876543210);
                p->initial10 = edges[(index + 1) % 9];
                p->initial11 = edges[(index + 2) % 9];
                p->initial_nzcv = (uint64_t)flags << 28;
                S2IX18Packet input = *p, expected;
                XCTAssertEqual(s2i_x18_reference(selector, &input, &expected), 1);
                s2i_x18_caller_probe(p, function);
                XCTAssertEqual(memcmp(&p->context, &expected.context, 32), 0);
                XCTAssertEqual(memcmp((const unsigned char *)p + 32,
                                      (const unsigned char *)&input + 32, 32), 0);
                XCTAssertEqual(p->after9, expected.after9);
                XCTAssertEqual(p->after10, expected.after10);
                XCTAssertEqual(p->after11, expected.after11);
                XCTAssertEqual(p->after_nzcv, expected.after_nzcv);
                XCTAssertEqual(p->helper_sp_before, p->helper_sp_after);
                XCTAssertEqual(p->helper_sp_before & 15, 0ULL);
                XCTAssertEqual(p->base_before, (uint64_t)(uintptr_t)&p->context);
                XCTAssertEqual(p->base_after, p->base_before);
                for (unsigned r = 0; r < 10; ++r) {
                    XCTAssertEqual(p->callee_before[r], UINT64_C(0xa5a5000000001900) + 19 + r);
                    XCTAssertEqual(p->callee_after[r], p->callee_before[r]);
                }
                XCTAssertEqual(p->probe_sp_before, p->probe_sp_after);
                XCTAssertEqual(p->probe_sp_before & 15, 0ULL);
                XCTAssertEqual(p->canary_before, UINT64_C(0x55aa));
                XCTAssertEqual(p->canary_after, p->canary_before);
                XCTAssertEqual(p->fp_after, p->fp_before);
                XCTAssertEqual(p->observed_link, p->expected_link);
                XCTAssertEqual(owned.head[0], UINT64_C(0x13579bdf2468ace0));
                XCTAssertEqual(owned.head[1], UINT64_C(0x1020304050607080));
                XCTAssertEqual(owned.tail[0], UINT64_C(0xdeadbeefcafebabe));
                XCTAssertEqual(owned.tail[1], UINT64_C(0x8877665544332211));
            }
        }
    }
#endif
}
- (void)testTwoOwnedContextsRemainIndependent {
#if !S2I_X18_NATIVE_SUPPORTED
    XCTFail(@"Owned native fixture requires iOS Simulator ARM64, not device/arm64e; no successful fallback.");
    return;
#else
    S2IX18Packet packets[2];
    memset(packets, 0x5a, sizeof(packets));
    for (unsigned i = 0; i < 2; ++i) {
        packets[i].context.guest18 = 100 + i;
        packets[i].initial9 = UINT64_C(0xabcdef0123456789) + i;
        packets[i].initial10 = 20 + i;
        packets[i].initial11 = 5 + i;
        packets[i].initial_nzcv = (uint64_t)i << 28;
    }
    S2IX18Packet untouched = packets[1];
    S2IX18Function function = s2i_x18_native_function(6);
    XCTAssertTrue(function != NULL);
    if (function == NULL) return;
    s2i_x18_caller_probe(&packets[0], function);
    XCTAssertEqual(memcmp(&packets[1], &untouched, sizeof(untouched)), 0);
    S2IX18Packet first_after = packets[0];
    s2i_x18_caller_probe(&packets[1], function);
    XCTAssertEqual(memcmp(&packets[0], &first_after, sizeof(first_after)), 0);
    XCTAssertEqual(packets[0].context.guest18, 25ULL);
    XCTAssertEqual(packets[1].context.guest18, 27ULL);
#endif
}
- (void)testInvalidSelectorsNeverReturnCallableCode {
    XCTAssertTrue(s2i_x18_native_function(S2IX18Count) == NULL);
    XCTAssertTrue(s2i_x18_native_function(UINT32_MAX) == NULL);
    S2IX18Packet input, output, unchanged;
    memset(&input, 0, sizeof(input));
    memset(&output, 0xa5, sizeof(output));
    unchanged = output;
    XCTAssertEqual(s2i_x18_reference(S2IX18Count, &input, &output), 0);
    XCTAssertEqual(memcmp(&output, &unchanged, sizeof(output)), 0);
    XCTAssertEqual(s2i_x18_reference(0, NULL, &output), 0);
    XCTAssertEqual(s2i_x18_reference(0, &input, NULL), 0);
}
@end
