// Owned add/subtract-with-carry fixture. Image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro carry_leaf name, op, width, left, right, cin, condition
.globl _carry_\name
_carry_\name:
    mov x0, #\left
    mov x1, #\right
    mov x3, #\cin
    cmp w3, #1 // cin0:N1,Z0,C0,V0; cin1:N0,Z1,C1,V0.
    \op \width\()2, \width\()0, \width\()1
    b.\condition Ltaken_\name
    nop
    b Ldone_\name
Ltaken_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
carry_leaf wadc, adc, w, 8, 1, 0, mi
carry_leaf wadcs, adcs, w, -1, 0, 1, eq
carry_leaf wsbc, sbc, w, 8, 1, 0, mi
carry_leaf wsbcs, sbcs, w, 0, 0, 1, eq
carry_leaf xadc, adc, x, 8, 1, 0, mi
carry_leaf xadcs, adcs, x, -1, 0, 1, eq
carry_leaf xsbc, sbc, x, 8, 1, 0, mi
carry_leaf xsbcs, sbcs, x, 0, 0, 1, eq
carry_leaf w_add_overflow, adcs, w, 0x7fffffff, 0, 1, vs
carry_leaf x_add_overflow, adcs, x, 0x7fffffffffffffff, 0, 1, vs
carry_leaf w_sub_overflow, sbcs, w, 0x80000000, 0, 0, vs
carry_leaf x_sub_overflow, sbcs, x, 0x8000000000000000, 0, 0, vs

.globl _carry_aliases
_carry_aliases:
    mov x0, #3
    cmp w0, #4 // C0
    ngc w2, w0 // -4, flags remain N1,Z0,C0,V0
    ngcs x3, x0 // -4, N1,Z0,C0,V0
    adcs xzr, xzr, xzr // result0,N0,Z1,C0,V0; ZRdest,notSP
    b.eq Lalias_ret
    nop
Lalias_ret:
    ret
Lend_aliases:

.globl _carry_unknown_c
_carry_unknown_c:
    mov x0, #1
    mov x1, #0
    adcs x2, x0, x1 // Entry C is unknown despite concrete operands.
    b.eq Lunknown_ret
    nop
Lunknown_ret:
    ret
Lend_unknown_c:

.globl _carry_unknown_operand
_carry_unknown_operand:
    mov x0, #1
    cmp w0, #1 // C1
    adcs x2, x0, x9 // Unknown operand invalidates prior Z1 as well as result.
    b.eq Loperand_ret
    nop
Loperand_ret:
    ret
Lend_unknown_operand:

.globl _carry_unknown_fde
_carry_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _carry_sink
    mov x0, #1
    mov x1, #0
    sbcs x2, x0, x1 // Call makes input C unknown.
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _carry_bad_cfi
_carry_bad_cfi:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_same_value x30
    mov x29, sp
.cfi_def_cfa x29, 16
    mov x0, #-1
    mov x1, #0
    cmp w0, #1
    adcs x2, x0, x1 // allones+0+C1 ->0, knownEQ
    b.eq Lbad_call
    nop
Lbad_call:
    bl _carry_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _carry_reserved
_carry_reserved:
    b Lreserved_ret
    .long 0xba010402 // Reserved bit10, even in dead code.
Lreserved_ret:
    ret
Lend_reserved:
.globl _carry_stack
_carry_stack:
    add x0, sp, #0
    adc x2, x0, x1 // Provenance must decline even with unknown C.
    ret
Lend_stack:
.globl _carry_sink
_carry_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _carry_\name
.long Lend_\name-_carry_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wadc
compact_leaf wadcs
compact_leaf wsbc
compact_leaf wsbcs
compact_leaf xadc
compact_leaf xadcs
compact_leaf xsbc
compact_leaf xsbcs
compact_leaf w_add_overflow
compact_leaf x_add_overflow
compact_leaf w_sub_overflow
compact_leaf x_sub_overflow
compact_leaf aliases
compact_leaf unknown_c
compact_leaf unknown_operand
compact_leaf reserved
compact_leaf stack
compact_leaf sink
.subsections_via_symbols
