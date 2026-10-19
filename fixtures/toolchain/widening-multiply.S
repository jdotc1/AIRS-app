// Small owned widening multiply corpus. Read as data; never execute.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro widening_leaf name, operation, left, right, accum, expected, alias=0, dest=2, add=0
.globl _widen_\name
_widen_\name:
    mov x0, #\left
    mov x1, #\right
    mov x3, #\accum
    mov x5, #1
    cmp w5, #1
.if \alias
    \operation x\dest, w0, w1
.else
    \operation x\dest, w0, w1, x3
.endif
    b.eq Lvalue_\name
    nop
Lvalue_\name:
    mov x4, #\expected
.if \add
    add x4, x4, #\add
.endif
    cmp x\dest, x4
    b.eq Lret_\name
    nop
Lret_\name:
    ret
Lend_\name:
.endmacro
widening_leaf smaddl, smaddl, -1, 2, 7, 5
widening_leaf smsubl, smsubl, -1, 2, 7, 9
widening_leaf umaddl, umaddl, -1, 2, 2, 0x200000000
widening_leaf umsubl, umsubl, -1, 2, 0x200000000, 2
widening_leaf smull, smull, -1, 1, 99, -1, 1
widening_leaf smnegl, smnegl, -1, 1, 99, 1, 1
widening_leaf umull, umull, -1, 1, 99, 0xffffffff, 1
widening_leaf umnegl, umnegl, -1, 1, 99, 0xffffffff00000001, 1
widening_leaf signed_min, smaddl, 0x80000000, 0x80000000, 0, 0x4000000000000000
widening_leaf unsigned_max, umaddl, -1, -1, 0, 0xfffffffe00000000, 0, 2, 1
widening_leaf signed_accum_high, smaddl, 4, 5, 0x100000000, 0x100000000, 0, 2, 20
widening_leaf unsigned_accum_high, umaddl, 4, 5, 0x100000000, 0x100000000, 0, 2, 20
widening_leaf signed_overlap, smsubl, -1, 2, 7, 9, 0, 3
widening_leaf unsigned_overlap, umsubl, -1, 2, 0x200000000, 2, 0, 3
widening_leaf signed_wrap, smaddl, 1, 1, -1, 0
widening_leaf unsigned_wrap, umsubl, 4, 5, 3, -17
.globl _widen_zr_factor
_widen_zr_factor:
    mov x1, #5
    mov x3, #27
    smaddl x2, wzr, w1, x3
    cmp x2, #27
    b.eq Lzr_ret
    nop
Lzr_ret:
    ret
Lend_zr_factor:
.globl _widen_unknown_factor
_widen_unknown_factor:
    mov x0, #1
    cmp w0, #1
    mov x1, #0
    smaddl x2, w9, w1, x0
    b.eq Lunknown_factor_ret
    nop
Lunknown_factor_ret:
    ret
Lend_unknown_factor:
.globl _widen_unknown_accum
_widen_unknown_accum:
    mov x0, #0
    cmp w0, #0
    mov x1, #1
    umsubl x2, w0, w1, x9
    b.eq Lunknown_accum_ret
    nop
Lunknown_accum_ret:
    ret
Lend_unknown_accum:
.globl _widen_unknown_identity
_widen_unknown_identity:
    smaddl x19, wzr, wzr, x19
    ret
Lend_unknown_identity:
.globl _widen_good_fde
_widen_good_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _widen_sink
    smaddl x2, w0, w1, x3
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _widen_bad_cfi
_widen_bad_cfi:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_same_value x30
    mov x29, sp
.cfi_def_cfa x29, 16
    mov x0, #1
    cmp w0, #1
    umsubl x2, w9, w10, x11
    b.eq Lbad_call
    nop
Lbad_call:
    bl _widen_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _widen_reserved
_widen_reserved:
    b Lreserved_ret
    .long 0x1b210c02 // W/sf0 widening, invalid.
    .long 0xbb210c02 // Reserved op54.
    .long 0x9b610c02 // Reserved op31.
Lreserved_ret:
    ret
Lend_reserved:
.globl _widen_high
_widen_high:
    b Lhigh_ret
    smulh x2, x0, x1 // Valid high-half multiply stays unsupported even dead.
Lhigh_ret:
    ret
Lend_high:
.globl _widen_stack_factor
_widen_stack_factor:
    add x0, sp, #0
    smull x2, w0, wzr // Raw provenance checked before W projection.
    ret
Lend_stack_factor:
.globl _widen_stack_accum
_widen_stack_accum:
    add x3, sp, #0
    umaddl x2, wzr, wzr, x3
    ret
Lend_stack_accum:
.globl _widen_sink
_widen_sink:
    nop
    ret
Lend_sink:
.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _widen_\name
.long Lend_\name-_widen_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf smaddl
compact_leaf smsubl
compact_leaf umaddl
compact_leaf umsubl
compact_leaf smull
compact_leaf smnegl
compact_leaf umull
compact_leaf umnegl
compact_leaf signed_min
compact_leaf unsigned_max
compact_leaf signed_accum_high
compact_leaf unsigned_accum_high
compact_leaf signed_overlap
compact_leaf unsigned_overlap
compact_leaf signed_wrap
compact_leaf unsigned_wrap
compact_leaf zr_factor
compact_leaf unknown_factor
compact_leaf unknown_accum
compact_leaf unknown_identity
compact_leaf reserved
compact_leaf high
compact_leaf stack_factor
compact_leaf stack_accum
compact_leaf sink
.subsections_via_symbols
