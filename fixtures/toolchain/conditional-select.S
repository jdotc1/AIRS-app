// Owned conditional select fixture. Linked image is input data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro select_leaf name, op, width, expected
.globl _select_\name
_select_\name:
    mov x0, #5
    mov x1, #3
    cmp w0, #5 // Z1,C1. NE false; select must preserve these flags.
    \op \width\()2, \width\()0, \width\()1, ne
    b.eq Lvalue_\name
    nop
Lvalue_\name:
    mov x3, #\expected
    cmp \width\()2, \width\()3
    b.eq Lret_\name // Selected value independently expected.
    nop
Lret_\name:
    ret
Lend_\name:
.endmacro
select_leaf wcsel, csel, w, 3
select_leaf wcsinc, csinc, w, 4
select_leaf wcsinv, csinv, w, -4
select_leaf wcsneg, csneg, w, -3
select_leaf xcsel, csel, x, 3
select_leaf xcsinc, csinc, x, 4
select_leaf xcsinv, csinv, x, -4
select_leaf xcsneg, csneg, x, -3

.macro alias_leaf name, op, width, expected, set
.globl _select_\name
_select_\name:
    mov x0, #5
    cmp w0, #5
.if \set
    \op \width\()2, eq
.else
    \op \width\()2, \width\()0, eq
.endif
    mov x3, #\expected
    cmp \width\()2, \width\()3
    b.eq Lret_\name
    nop
Lret_\name:
    ret
Lend_\name:
.endmacro
alias_leaf cset, cset, w, 1, 1
alias_leaf csetm, csetm, x, -1, 1
alias_leaf cinc, cinc, x, 6, 0
alias_leaf cinv, cinv, w, -6, 0
alias_leaf cneg, cneg, x, -5, 0

.globl _select_identity
_select_identity:
    mov x0, #1
    cmp w0, #1
    csneg x19, x19, x9, eq // Known true preserves original x19; false source unknown.
    b.eq Lidentity_ret
    nop
Lidentity_ret:
    ret
Lend_identity:
.globl _select_equal
_select_equal:
    mov x0, #7
    mov x1, #6
    csinc x2, x0, x1, eq // Unknown predicate, equal post-transform alternatives7.
    cmp x2, #7
    b.eq Lequal_ret
    nop
Lequal_ret:
    ret
Lend_equal:
.globl _select_unequal
_select_unequal:
    mov x0, #7
    mov x1, #7
    csinc x2, x0, x1, eq // Raw inputs equal but alternatives7/8 differ.
    cmp x2, #7
    b.eq Lunequal_ret
    nop
Lunequal_ret:
    ret
Lend_unequal:

.globl _select_unknown_fde
_select_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _select_sink
    csneg x2, x0, x1, eq
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _select_bad_cfi
_select_bad_cfi:
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
    csinv x2, xzr, xzr, ne // CSETM EQ, flags remain Z1.
    b.eq Lbad_call
    nop
Lbad_call:
    bl _select_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _select_al
_select_al:
    csneg x2, x0, x1, al
    ret
Lend_al:
.globl _select_reserved
_select_reserved:
    b Lreserved_ret
    .long 0x9a810c02 // CSINC plus reserved bit11.
Lreserved_ret:
    ret
Lend_reserved:
.globl _select_stack
_select_stack:
    add x1, sp, #0
    mov x0, #1
    cmp w0, #1
    csinc x2, x0, x1, eq // Even unselected stack arm is conservatively excluded.
    ret
Lend_stack:
.globl _select_sink
_select_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _select_\name
.long Lend_\name-_select_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wcsel
compact_leaf wcsinc
compact_leaf wcsinv
compact_leaf wcsneg
compact_leaf xcsel
compact_leaf xcsinc
compact_leaf xcsinv
compact_leaf xcsneg
compact_leaf cset
compact_leaf csetm
compact_leaf cinc
compact_leaf cinv
compact_leaf cneg
compact_leaf identity
compact_leaf equal
compact_leaf unequal
compact_leaf al
compact_leaf reserved
compact_leaf stack
compact_leaf sink
.subsections_via_symbols
