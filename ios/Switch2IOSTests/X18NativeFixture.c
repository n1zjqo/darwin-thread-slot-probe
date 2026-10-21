#include "X18NativeFixture.h"
#include <string.h>
#if S2I_X18_NATIVE_SUPPORTED
#define DECLARE(name) extern void name(S2IX18Packet *)
DECLARE(s2i_x18_w_add_write); DECLARE(s2i_x18_w_add_read); DECLARE(s2i_x18_w_add_repeated);
DECLARE(s2i_x18_w_sub_write); DECLARE(s2i_x18_w_sub_read); DECLARE(s2i_x18_w_sub_repeated);
DECLARE(s2i_x18_x_add_write); DECLARE(s2i_x18_x_add_read); DECLARE(s2i_x18_x_add_repeated);
DECLARE(s2i_x18_x_sub_write); DECLARE(s2i_x18_x_sub_read); DECLARE(s2i_x18_x_sub_repeated);
#undef DECLARE
#endif
S2IX18Function s2i_x18_native_function(unsigned selector) {
#if S2I_X18_NATIVE_SUPPORTED
    static const S2IX18Function functions[S2IX18Count] = {
        s2i_x18_w_add_write, s2i_x18_w_add_read, s2i_x18_w_add_repeated,
        s2i_x18_w_sub_write, s2i_x18_w_sub_read, s2i_x18_w_sub_repeated,
        s2i_x18_x_add_write, s2i_x18_x_add_read, s2i_x18_x_add_repeated,
        s2i_x18_x_sub_write, s2i_x18_x_sub_read, s2i_x18_x_sub_repeated
    };
    return selector < S2IX18Count ? functions[selector] : NULL;
#else
    (void)selector;
    return NULL;
#endif
}
int s2i_x18_reference(unsigned selector, const S2IX18Packet *input, S2IX18Packet *output) {
    if (selector >= S2IX18Count || input == NULL || output == NULL) return 0;
    const unsigned mode = selector % 3, subtract = (selector / 3) % 2, wide = selector / 6;
    const uint64_t left = mode == S2IX18Write ? input->initial10 : input->context.guest18;
    const uint64_t right = mode == S2IX18Repeated ? input->context.guest18 : input->initial11;
    uint64_t value;
    if (wide) value = subtract ? left - right : left + right;
    else {
        const uint32_t a = (uint32_t)left, b = (uint32_t)right;
        value = (uint32_t)(subtract ? a - b : a + b);
    }
    memcpy(output, input, sizeof(*output));
    output->context.scratch_save = input->initial9;
    if (mode != S2IX18Read) output->context.guest18 = value;
    output->after9 = input->initial9;
    output->after10 = mode == S2IX18Read ? value : input->initial10;
    output->after11 = input->initial11;
    output->after_nzcv = input->initial_nzcv & UINT64_C(0xF0000000);
    return 1;
}
