#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && defined(__arm64__) && !defined(__arm64e__) && TARGET_OS_SIMULATOR && TARGET_OS_IOS
.text
.p2align 2
// Fixed owned arithmetic bodies; no dynamic code or external instruction inputs.
.p2align 2
.globl _s2i_x18_w_add_write
_s2i_x18_w_add_write:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_w_add_write input=0x0b0b0152
    .long 0xf9000789
    .long 0xf9400389
    .long 0x0b0b0149
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_w_add_read
_s2i_x18_w_add_read:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_w_add_read input=0x0b0b024a
    .long 0xf9000789
    .long 0xf9400389
    .long 0x0b0b012a
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_w_add_repeated
_s2i_x18_w_add_repeated:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_w_add_repeated input=0x0b120252
    .long 0xf9000789
    .long 0xf9400389
    .long 0x0b090129
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_w_sub_write
_s2i_x18_w_sub_write:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_w_sub_write input=0x4b0b0152
    .long 0xf9000789
    .long 0xf9400389
    .long 0x4b0b0149
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_w_sub_read
_s2i_x18_w_sub_read:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_w_sub_read input=0x4b0b024a
    .long 0xf9000789
    .long 0xf9400389
    .long 0x4b0b012a
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_w_sub_repeated
_s2i_x18_w_sub_repeated:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_w_sub_repeated input=0x4b120252
    .long 0xf9000789
    .long 0xf9400389
    .long 0x4b090129
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_x_add_write
_s2i_x18_x_add_write:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_x_add_write input=0x8b0b0152
    .long 0xf9000789
    .long 0xf9400389
    .long 0x8b0b0149
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_x_add_read
_s2i_x18_x_add_read:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_x_add_read input=0x8b0b024a
    .long 0xf9000789
    .long 0xf9400389
    .long 0x8b0b012a
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_x_add_repeated
_s2i_x18_x_add_repeated:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_x_add_repeated input=0x8b120252
    .long 0xf9000789
    .long 0xf9400389
    .long 0x8b090129
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_x_sub_write
_s2i_x18_x_sub_write:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_x_sub_write input=0xcb0b0152
    .long 0xf9000789
    .long 0xf9400389
    .long 0xcb0b0149
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_x_sub_read
_s2i_x18_x_sub_read:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_x_sub_read input=0xcb0b024a
    .long 0xf9000789
    .long 0xf9400389
    .long 0xcb0b012a
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_x_sub_repeated
_s2i_x18_x_sub_repeated:
.cfi_startproc
    stp x29, x30, [sp, #-32]!
.cfi_def_cfa_offset 32
.cfi_offset 29, -32
.cfi_offset 30, -24
    str x28, [sp, #16]
.cfi_offset 28, -16
    mov x29, sp
    mov x28, x0
    ldr x9, [x0, #32]
    ldr x10, [x0, #40]
    ldr x11, [x0, #48]
    mov x12, sp
    str x12, [x0, #96]
    str x28, [x0, #112]
    ldr x12, [x0, #56]
    msr NZCV, x12
// BODY_BEGIN _s2i_x18_x_sub_repeated input=0xcb120252
    .long 0xf9000789
    .long 0xf9400389
    .long 0xcb090129
    .long 0xf9000389
    .long 0xf9400789
// BODY_END
    mrs x12, NZCV
    str x12, [x0, #88]
    str x9, [x0, #64]
    str x10, [x0, #72]
    str x11, [x0, #80]
    mov x12, sp
    str x12, [x0, #104]
    str x28, [x0, #120]
    ldr x28, [sp, #16]
.cfi_restore 28
    ldp x29, x30, [sp], #32
.cfi_restore 29
.cfi_restore 30
.cfi_def_cfa_offset 0
    ret
.cfi_endproc
.p2align 2
.globl _s2i_x18_caller_probe
_s2i_x18_caller_probe:
.cfi_startproc
    sub sp, sp, #128
.cfi_def_cfa_offset 128
    stp x19, x20, [sp, #0]
.cfi_offset 19, -128
.cfi_offset 20, -120
    stp x21, x22, [sp, #16]
.cfi_offset 21, -112
.cfi_offset 22, -104
    stp x23, x24, [sp, #32]
.cfi_offset 23, -96
.cfi_offset 24, -88
    stp x25, x26, [sp, #48]
.cfi_offset 25, -80
.cfi_offset 26, -72
    stp x27, x28, [sp, #64]
.cfi_offset 27, -64
.cfi_offset 28, -56
    stp x29, x30, [sp, #80]
.cfi_offset 29, -48
.cfi_offset 30, -40
    add x29, sp, #80
    stp x0, x1, [sp, #96]
    mov x12, #0x55aa
    str x12, [sp, #112]
    str x12, [x0, #304]
    add x12, sp, #128
    str x12, [x0, #288]
    mov x19, #0x1913
    movk x19, #0xa5a5, lsl #48
    mov x20, #0x1914
    movk x20, #0xa5a5, lsl #48
    mov x21, #0x1915
    movk x21, #0xa5a5, lsl #48
    mov x22, #0x1916
    movk x22, #0xa5a5, lsl #48
    mov x23, #0x1917
    movk x23, #0xa5a5, lsl #48
    mov x24, #0x1918
    movk x24, #0xa5a5, lsl #48
    mov x25, #0x1919
    movk x25, #0xa5a5, lsl #48
    mov x26, #0x191a
    movk x26, #0xa5a5, lsl #48
    mov x27, #0x191b
    movk x27, #0xa5a5, lsl #48
    mov x28, #0x191c
    movk x28, #0xa5a5, lsl #48
    stp x19, x20, [x0, #128]
    stp x21, x22, [x0, #144]
    stp x23, x24, [x0, #160]
    stp x25, x26, [x0, #176]
    stp x27, x28, [x0, #192]
    str x29, [x0, #320]
    adr x12, L_s2i_x18_probe_return
    str x12, [x0, #336]
    ldr x16, [sp, #104]
    blr x16
L_s2i_x18_probe_return:
    ldr x0, [sp, #96]
    stp x19, x20, [x0, #208]
    stp x21, x22, [x0, #224]
    stp x23, x24, [x0, #240]
    stp x25, x26, [x0, #256]
    stp x27, x28, [x0, #272]
    str x29, [x0, #328]
    str x30, [x0, #344]
    ldr x12, [sp, #112]
    str x12, [x0, #312]
    ldp x19, x20, [sp, #0]
.cfi_restore 19
.cfi_restore 20
    ldp x21, x22, [sp, #16]
.cfi_restore 21
.cfi_restore 22
    ldp x23, x24, [sp, #32]
.cfi_restore 23
.cfi_restore 24
    ldp x25, x26, [sp, #48]
.cfi_restore 25
.cfi_restore 26
    ldp x27, x28, [sp, #64]
.cfi_restore 27
.cfi_restore 28
    ldp x29, x30, [sp, #80]
.cfi_restore 29
.cfi_restore 30
    add sp, sp, #128
.cfi_def_cfa_offset 0
    mov x12, sp
    str x12, [x0, #296]
    ret
.cfi_endproc
#endif
