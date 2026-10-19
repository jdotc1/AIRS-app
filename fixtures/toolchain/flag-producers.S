// Owned immediate flag producers. The linked image is input data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro flag_leaf name, value, op, width, condition
.globl _flags_\name
_flags_\name:
    .ifc \name,woverflow
    mov x0, #0x80000000
    sub x0, x0, #1
    .else
    mov x0, #\value
    .endif
    \op \width\()1, \width\()0, #1
    b.\condition Ltaken_\name
    nop
    b Ldone_\name
Ltaken_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
flag_leaf wcarry, -1, adds, w, hs
flag_leaf woverflow, 0x7fffffff, adds, w, vs
flag_leaf xcarry, -1, adds, x, hs
flag_leaf xoverflow, 0x7fffffffffffffff, adds, x, vs
flag_leaf xborrow, 0, subs, x, lo
flag_leaf xsuboverflow, 0x8000000000000000, subs, x, vs

.globl _flags_unknown_fde
_flags_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _flags_sink
    adds x1, x0, #1
    b.vs Lunknown_taken
    nop
Lunknown_taken:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _flags_bad_cfi
_flags_bad_cfi:
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
    adds x1, x0, #1
    b.hs Lbad_call
    nop
Lbad_call:
    bl _flags_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _flags_register_unsupported
_flags_register_unsupported:
    adds x1, x0, x2
    b.eq Lregister_ret
    nop
Lregister_ret:
    ret
Lend_register_unsupported:

.globl _flags_sink
_flags_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _flags_\name
.long Lend_\name-_flags_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wcarry
compact_leaf woverflow
compact_leaf xcarry
compact_leaf xoverflow
compact_leaf xborrow
compact_leaf xsuboverflow
compact_leaf register_unsupported
compact_leaf sink
.subsections_via_symbols
