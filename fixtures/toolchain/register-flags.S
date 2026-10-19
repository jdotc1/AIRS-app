// Small owned unshifted register flag producers. Linked image is data only.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro register_leaf name, value, op, width, condition, right
.globl _regflags_\name
_regflags_\name:
    .ifc \name,woverflow
    mov x0, #0x80000000
    sub x0, x0, #1
    .else
    mov x0, #\value
    .endif
    mov x1, #\right
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
register_leaf wcarry, -1, adds, w, hs, 1
register_leaf wborrow, 0, subs, w, lo, 2
register_leaf woverflow, 0x7fffffff, adds, w, vs, 1
register_leaf xcarry, -1, adds, x, hs, 1
register_leaf xoverflow, 0x7fffffffffffffff, adds, x, vs, 1
register_leaf xsuboverflow, 0x8000000000000000, subs, x, vs, 1

.globl _regflags_aliases
_regflags_aliases:
    mov x0, #7
    cmn w0, wzr
    cmp xzr, xzr
    b.ne Lalias_other
    nop
    b Lalias_done
Lalias_other:
    nop
Lalias_done:
    ret
Lend_aliases:

.globl _regflags_unknown_fde
_regflags_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _regflags_sink
    adds x2, x0, x1
    b.vs Lunknown_taken
    nop
Lunknown_taken:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _regflags_bad_cfi
_regflags_bad_cfi:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_same_value x30
    mov x29, sp
.cfi_def_cfa x29, 16
    mov x0, #0
    mov x1, #2
    subs x2, x0, x1
    b.lo Lbad_call
    nop
Lbad_call:
    bl _regflags_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _regflags_shift_unsupported
_regflags_shift_unsupported:
    b Lshift_ret
    adds x1, x0, x2, lsl #1 // Even unreachable unsupported effects stay unresolved.
Lshift_ret:
    ret
Lend_shift_unsupported:

.globl _regflags_sink
_regflags_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _regflags_\name
.long Lend_\name-_regflags_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wcarry
compact_leaf wborrow
compact_leaf woverflow
compact_leaf xcarry
compact_leaf xoverflow
compact_leaf xsuboverflow
compact_leaf aliases
compact_leaf shift_unsupported
compact_leaf sink
.subsections_via_symbols
