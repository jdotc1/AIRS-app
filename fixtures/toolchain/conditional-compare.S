// Owned conditional compare fixture. Linked image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro compare_leaf name, op, width, immediate
.globl _compare_\name
_compare_\name:
    mov x0, #-1
    mov x1, #1
    cmp w1, #1 // EQ true, Z1,C1.
.if \immediate
    \op \width\()0, #1, #0, eq
.else
    \op \width\()0, \width\()1, #0, eq
.endif
    b.hs Ltaken_\name // Both allones-1 and allones+1 set C1.
    nop
    b Ldone_\name
Ltaken_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
compare_leaf wccmp_reg, ccmp, w, 0
compare_leaf wccmp_imm, ccmp, w, 1
compare_leaf wccmn_reg, ccmn, w, 0
compare_leaf wccmn_imm, ccmn, w, 1
compare_leaf xccmp_reg, ccmp, x, 0
compare_leaf xccmp_imm, ccmp, x, 1
compare_leaf xccmn_reg, ccmn, x, 0
compare_leaf xccmn_imm, ccmn, x, 1

.macro fallback_leaf name, op, width, immediate
.globl _compare_\name
_compare_\name:
    mov x0, #1
    cmp w0, #1 // NE false. Unused source X9 remains unknown.
.if \immediate
    \op \width\()9, #31, #9, ne
.else
    \op \width\()9, \width\()10, #9, ne
.endif
    b.vs Ltaken_\name // Literal9=N1,Z0,C0,V1.
    nop
Ltaken_\name:
    ret
Lend_\name:
.endmacro
fallback_leaf wccmp_false, ccmp, w, 1
fallback_leaf xccmp_false, ccmp, x, 0
fallback_leaf wccmn_false, ccmn, w, 0
fallback_leaf xccmn_false, ccmn, x, 1

.globl _compare_unknown_predicate
_compare_unknown_predicate:
    mov x0, #1
    ccmp x0, #1, #6, eq // Entry predicate unknown, both effects must remain possible.
    b.eq Lunknown_ret
    nop
Lunknown_ret:
    ret
Lend_unknown_predicate:
.globl _compare_unknown_operand
_compare_unknown_operand:
    mov x0, #1
    cmp w0, #1
    ccmn x0, x9, #9, eq // True predicate with unknown operand loses prior flags.
    b.eq Loperand_ret
    nop
Loperand_ret:
    ret
Lend_unknown_operand:

.globl _compare_unknown_fde
_compare_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _compare_sink
    mov x0, #1
    ccmp x0, #1, #6, eq // Even matching alternatives remain conservative post-call.
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _compare_bad_cfi
_compare_bad_cfi:
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
    ccmp x9, x10, #9, ne // False predicate: concrete V1 despite unused unknowns.
    b.vs Lbad_call
    nop
Lbad_call:
    bl _compare_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _compare_al
_compare_al:
    ccmp x0, #1, #0, al // Architecturally valid; deliberately outside boundedconditions.
    ret
Lend_al:
.globl _compare_reserved
_compare_reserved:
    b Lreserved_ret
    .long 0x7a410010 // Reserved bit4 even in dead code.
Lreserved_ret:
    ret
Lend_reserved:
.globl _compare_stack
_compare_stack:
    add x0, sp, #0
    ccmp x0, #1, #0, eq // Unknown predicate might use stack-derived operand.
    ret
Lend_stack:
.globl _compare_sink
_compare_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _compare_\name
.long Lend_\name-_compare_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wccmp_reg
compact_leaf wccmp_imm
compact_leaf wccmn_reg
compact_leaf wccmn_imm
compact_leaf xccmp_reg
compact_leaf xccmp_imm
compact_leaf xccmn_reg
compact_leaf xccmn_imm
compact_leaf wccmp_false
compact_leaf xccmp_false
compact_leaf wccmn_false
compact_leaf xccmn_false
compact_leaf unknown_predicate
compact_leaf unknown_operand
compact_leaf al
compact_leaf reserved
compact_leaf stack
compact_leaf sink
.subsections_via_symbols
