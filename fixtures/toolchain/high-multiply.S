// Owned high-half multiply cases; inspect bytes, never execute.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro high_leaf name, operation, left, right, expected, dest=2
.globl _high_\name
_high_\name:
    mov x0, #\left
    mov x1, #\right
    mov x4, #1
    cmp w4, #1
    \operation x\dest, x0, x1
    b.eq Lvalue_\name
    nop
Lvalue_\name:
    mov x3, #\expected
    cmp x\dest, x3
    b.eq Lret_\name
    nop
Lret_\name:
    ret
Lend_\name:
.endmacro
high_leaf signed_neg_one, smulh, -1, 1, -1
high_leaf unsigned_neg_one, umulh, -1, 1, 0
high_leaf signed_min_three, smulh, 0x8000000000000000, 3, -2
high_leaf unsigned_min_three, umulh, 0x8000000000000000, 3, 1
high_leaf signed_min_square, smulh, 0x8000000000000000, 0x8000000000000000, 0x4000000000000000
high_leaf unsigned_min_square, umulh, 0x8000000000000000, 0x8000000000000000, 0x4000000000000000
high_leaf signed_max_square, smulh, -1, -1, 0
high_leaf unsigned_max_square, umulh, -1, -1, -2
high_leaf signed_small, smulh, 4, 5, 0
high_leaf unsigned_small, umulh, 4, 5, 0
high_leaf signed_bit32, smulh, 0x100000000, 0x100000000, 1
high_leaf unsigned_bit32, umulh, 0x100000000, 0x100000000, 1
high_leaf signed_overlap, smulh, -1, 1, -1, 0
high_leaf unsigned_overlap, umulh, -1, -1, -2, 1
.globl _high_signed_zr
_high_signed_zr:
    mov x1, #5
    smulh x2, xzr, x1
    cmp x2, #0
    b.eq Lsigned_zr_ret
    nop
Lsigned_zr_ret:
    ret
Lend_signed_zr:
.globl _high_unsigned_zr
_high_unsigned_zr:
    mov x0, #5
    umulh x2, x0, xzr
    cmp x2, #0
    b.eq Lunsigned_zr_ret
    nop
Lunsigned_zr_ret:
    ret
Lend_unsigned_zr:
.globl _high_unknown_factor
_high_unknown_factor:
    mov x0, #1
    cmp w0, #1
    mov x1, #0
    smulh x2, x9, x1
    b.eq Lunknown_ret
    nop
Lunknown_ret:
    ret
Lend_unknown_factor:
.globl _high_unknown_identity
_high_unknown_identity:
    umulh x19, x19, xzr
    ret
Lend_unknown_identity:
.globl _high_good_fde
_high_good_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _high_sink
    smulh x2, x0, x1
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _high_bad_cfi
_high_bad_cfi:
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
    umulh x2, x9, x10
    b.eq Lbad_call
    nop
Lbad_call:
    bl _high_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _high_invalid
_high_invalid:
    b Linvalid_ret
    .long 0x1b417c02 // sf0 high multiply, invalid.
    .long 0xbb417c02 // Reserved op54.
    .long 0x9b41fc02 // o0=1 high multiply, invalid.
Linvalid_ret:
    ret
Lend_invalid:
.globl _high_noncanonical
_high_noncanonical:
    b Lnoncanonical_ret
    .long 0x9b410002 // Ra0: outside AIRS canonical subset, not claimed ISA-invalid.
    .long 0x9bc10402 // Ra1: outside AIRS canonical subset.
Lnoncanonical_ret:
    ret
Lend_noncanonical:
.globl _high_stack
_high_stack:
    add x0, sp, #0
    smulh x2, x0, xzr
    ret
Lend_stack:
.globl _high_sink
_high_sink:
    nop
    ret
Lend_sink:
.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _high_\name
.long Lend_\name-_high_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf signed_neg_one
compact_leaf unsigned_neg_one
compact_leaf signed_min_three
compact_leaf unsigned_min_three
compact_leaf signed_min_square
compact_leaf unsigned_min_square
compact_leaf signed_max_square
compact_leaf unsigned_max_square
compact_leaf signed_small
compact_leaf unsigned_small
compact_leaf signed_bit32
compact_leaf unsigned_bit32
compact_leaf signed_overlap
compact_leaf unsigned_overlap
compact_leaf signed_zr
compact_leaf unsigned_zr
compact_leaf unknown_factor
compact_leaf unknown_identity
compact_leaf invalid
compact_leaf noncanonical
compact_leaf stack
compact_leaf sink
.subsections_via_symbols
