// Owned MADD/MSUB and MUL/MNEG cases; inspect bytes, never execute.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro multiply_leaf name, width, operation, left, right, accum, expected, alias=0, dest=2
.globl _multiply_\name
_multiply_\name:
    mov x0, #\left
    mov x1, #\right
    mov x3, #\accum
    mov x5, #1
    cmp w5, #1
.if \alias
    \operation \width\()\dest, \width\()0, \width\()1
.else
    \operation \width\()\dest, \width\()0, \width\()1, \width\()3
.endif
    b.eq Lvalue_\name
    nop
Lvalue_\name:
    mov x4, #\expected
    cmp \width\()\dest, \width\()4
    b.eq Lret_\name
    nop
Lret_\name:
    ret
Lend_\name:
.endmacro
multiply_leaf w_madd, w, madd, 4, 5, 27, 47
multiply_leaf x_madd, x, madd, 4, 5, 27, 47
multiply_leaf w_msub, w, msub, 4, 5, 27, 7
multiply_leaf x_msub, x, msub, 4, 5, 27, 7
multiply_leaf w_mul, w, mul, 4, 5, 99, 20, 1
multiply_leaf x_mul, x, mul, 4, 5, 99, 20, 1
multiply_leaf w_mneg, w, mneg, 4, 5, 99, -20, 1
multiply_leaf x_mneg, x, mneg, 4, 5, 99, -20, 1
multiply_leaf w_add_wrap, w, madd, -1, 2, 5, 3
multiply_leaf x_add_wrap, x, madd, -1, 2, 5, 3
multiply_leaf w_sub_wrap, w, msub, 4, 5, 3, -17
multiply_leaf x_sub_wrap, x, msub, 4, 5, 3, -17
multiply_leaf w_overlap, w, madd, 4, 5, 27, 47, 0, 3
multiply_leaf x_overlap, x, msub, 4, 5, 27, 7, 0, 3
.globl _multiply_zr_factor
_multiply_zr_factor:
    mov x1, #5
    mov x3, #27
    madd x2, xzr, x1, x3
    cmp x2, #27
    b.eq Lzr_factor_ret
    nop
Lzr_factor_ret:
    ret
Lend_zr_factor:
.globl _multiply_high_product
_multiply_high_product:
    mov x0, #0x8000000000000000
    mov x1, #2
    mov x3, #7
    msub x2, x0, x1, x3
    cmp x2, #7
    b.eq Lhigh_product_ret
    nop
Lhigh_product_ret:
    ret
Lend_high_product:
.globl _multiply_unknown_factor
_multiply_unknown_factor:
    mov x0, #1
    cmp w0, #1
    mov x1, #0
    madd x2, x9, x1, x0
    b.eq Lunknown_factor_ret
    nop
Lunknown_factor_ret:
    ret
Lend_unknown_factor:
.globl _multiply_unknown_accum
_multiply_unknown_accum:
    mov x0, #0
    cmp w0, #0
    mov x1, #1
    msub x2, x0, x1, x9
    b.eq Lunknown_accum_ret
    nop
Lunknown_accum_ret:
    ret
Lend_unknown_accum:
.globl _multiply_unknown_identity
_multiply_unknown_identity:
    madd x19, xzr, xzr, x19
    ret
Lend_unknown_identity:
.globl _multiply_good_fde
_multiply_good_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _multiply_sink
    madd x2, x0, x1, x3
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _multiply_bad_cfi
_multiply_bad_cfi:
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
    msub x2, x9, x10, x11
    b.eq Lbad_call
    nop
Lbad_call:
    bl _multiply_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _multiply_reserved
_multiply_reserved:
    b Lreserved_ret
    .long 0x3b010803 // Reserved op54.
    .long 0x5b010803 // Reserved op54.
    .long 0x1b610803 // Reserved op31.
Lreserved_ret:
    ret
Lend_reserved:
.globl _multiply_long
_multiply_long:
    b Llong_ret
    smaddl x2, w0, w1, x3 // Valid, outside this bounded family even when dead.
Llong_ret:
    ret
Lend_long:
.globl _multiply_stack_factor
_multiply_stack_factor:
    add x0, sp, #0
    mul x2, x0, xzr // Zero product does not erase provenance.
    ret
Lend_stack_factor:
.globl _multiply_stack_accum
_multiply_stack_accum:
    add x3, sp, #0
    madd x2, xzr, xzr, x3
    ret
Lend_stack_accum:
.globl _multiply_sink
_multiply_sink:
    nop
    ret
Lend_sink:
.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _multiply_\name
.long Lend_\name-_multiply_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf w_madd
compact_leaf x_madd
compact_leaf w_msub
compact_leaf x_msub
compact_leaf w_mul
compact_leaf x_mul
compact_leaf w_mneg
compact_leaf x_mneg
compact_leaf w_add_wrap
compact_leaf x_add_wrap
compact_leaf w_sub_wrap
compact_leaf x_sub_wrap
compact_leaf w_overlap
compact_leaf x_overlap
compact_leaf zr_factor
compact_leaf high_product
compact_leaf unknown_factor
compact_leaf unknown_accum
compact_leaf unknown_identity
compact_leaf reserved
compact_leaf long
compact_leaf stack_factor
compact_leaf stack_accum
compact_leaf sink
.subsections_via_symbols
