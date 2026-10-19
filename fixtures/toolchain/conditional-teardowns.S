// Owned conditional restore transfers; inspected dylib is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _conditional_leaf
_conditional_leaf:
    sub sp, sp, #32
    cmp w0, #7
    nop
    add sp, sp, #16
    b.gt Lleaf_taken
    add sp, sp, #16
    ret
Lleaf_taken:
    add sp, sp, #16
    ret
Lleaf_end:

.globl _conditional_frame
_conditional_frame:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #8
    cmp w0, #7
    bl _conditional_sink
    ldp x29, x30, [sp]
    b.gt Lframe_taken
    add sp, sp, #16
    ret
Lframe_taken:
    add sp, sp, #16
    ret
Lframe_end:

.globl _conditional_dwarf
_conditional_dwarf:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    bl _conditional_sink
    ldp x29, x30, [sp]
    b.le Ldwarf_taken
    add sp, sp, #16
    ret
Ldwarf_taken:
    add sp, sp, #16
    ret
    .cfi_endproc

.globl _conditional_bad_cfi
_conditional_bad_cfi:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_same_value x30 // Deliberate supported LR discrepancy at BL.
    mov x29, sp
    .cfi_def_cfa x29, 16
    bl _conditional_sink
    ldp x29, x30, [sp]
    b.gt Lbadcfi_taken
    add sp, sp, #16
    ret
Lbadcfi_taken:
    add sp, sp, #16
    ret
    .cfi_endproc

.globl _conditional_bad_return
_conditional_bad_return:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _conditional_sink
    ldp x29, x30, [sp]
    b.gt Lbadreturn_taken
    add sp, sp, #16
    ret
Lbadreturn_taken:
    add sp, sp, #32 // Unknown NZCV means this bad successor cannot be pruned.
    ret
Lbadreturn_end:

.globl _conditional_bad_fallthrough
_conditional_bad_fallthrough:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _conditional_sink
    ldp x29, x30, [sp]
    b.gt Lbadfall_taken
    mov x0, #0 // Body effect: fallthrough is not a recognized teardown successor.
    add sp, sp, #16
    ret
Lbadfall_taken:
    add sp, sp, #16
    ret
Lbadfall_end:

.globl _conditional_sink
_conditional_sink:
    nop
    ret
Lsink_end:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.quad _conditional_leaf
.long Lleaf_end-_conditional_leaf
.long 0x02002000
.quad 0, 0
.quad _conditional_frame
.long Lframe_end-_conditional_frame
.long 0x04000000
.quad 0, 0
.quad _conditional_bad_return
.long Lbadreturn_end-_conditional_bad_return
.long 0x04000000
.quad 0, 0
.quad _conditional_bad_fallthrough
.long Lbadfall_end-_conditional_bad_fallthrough
.long 0x04000000
.quad 0, 0
.quad _conditional_sink
.long Lsink_end-_conditional_sink
.long 0x02000000
.quad 0, 0
.subsections_via_symbols
