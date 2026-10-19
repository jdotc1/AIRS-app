// Small owned multiple-return inputs; linked image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _returns_leaf
_returns_leaf:
    sub sp, sp, #32
    cmp w0, #7
    b.gt Lleaf_second
    nop
    add sp, sp, #32
    ret
Lleaf_second:
    nop
    add sp, sp, #32
    ret
Lleaf_end:

.globl _returns_frame
_returns_frame:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.gt Lframe_second
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
Lframe_second:
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
Lframe_end:

.globl _returns_dwarf
_returns_dwarf:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    cmp w0, #7
    b.gt Ldwarf_second
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
Ldwarf_second:
    // Explicit row at the later physical arm; no remember/restore-state opcode.
    .cfi_def_cfa x29, 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
    .cfi_endproc

.globl _returns_bad_cfi
_returns_bad_cfi:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    // Deliberately wrong retained LR instead of the saved LR slot.
    .cfi_same_value x30
    mov x29, sp
    .cfi_def_cfa x29, 16
    mov x0, #8
    cmp w0, #7
    b.le Lbadcfi_second
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
Lbadcfi_second:
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
    .cfi_endproc

.globl _returns_bad_state
_returns_bad_state:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.gt Lstate_second
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
Lstate_second:
    mov x19, #7
    ldp x29, x30, [sp], #16
    ret
Lstate_end:

.globl _returns_bad_edge
_returns_bad_edge:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.gt Ledge_ret
    bl _returns_sink
    ldp x29, x30, [sp], #16
Ledge_ret:
    ret
    bl _returns_sink
    ldp x29, x30, [sp], #16
    ret
Ledge_end:

.globl _returns_sink
_returns_sink:
    nop
    ret
Lsink_end:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.quad _returns_leaf
.long Lleaf_end-_returns_leaf
.long 0x02002000
.quad 0, 0
.quad _returns_frame
.long Lframe_end-_returns_frame
.long 0x04000000
.quad 0, 0
.quad _returns_bad_state
.long Lstate_end-_returns_bad_state
.long 0x04000000
.quad 0, 0
.quad _returns_bad_edge
.long Ledge_end-_returns_bad_edge
.long 0x04000000
.quad 0, 0
.quad _returns_sink
.long Lsink_end-_returns_sink
.long 0x02000000
.quad 0, 0
.subsections_via_symbols
