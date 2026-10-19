// Owned NZCV condition families. Linked image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro condition_leaf name, value, select, branch
.globl _conditions_\name
_conditions_\name:
    mov x0, #\value
    cmp w0, #1
    csel w1, w0, wzr, \select
    b.\branch Lother_\name
    nop
    b Ldone_\name
Lother_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
condition_leaf equality, 1, eq, ne
condition_leaf carry, 0, hs, lo
condition_leaf sign, 0, mi, pl
condition_leaf overflow, 0x80000000, vs, vc
condition_leaf unsigned, 2, hi, ls
condition_leaf signed, 0x80000000, ge, lt

.globl _conditions_frame
_conditions_frame:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #1
    cmp w0, #1
    bl _conditions_sink
    ldp x29, x30, [sp]
    b.eq Lframe_taken
    add sp, sp, #16
    ret
Lframe_taken:
    add sp, sp, #16
    ret
Lframe_end:

.globl _conditions_dwarf
_conditions_dwarf:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    bl _conditions_sink
    ldp x29, x30, [sp]
    b.hs Ldwarf_taken
    add sp, sp, #16
    ret
Ldwarf_taken:
    add sp, sp, #16
    ret
    .cfi_endproc

.globl _conditions_bad_cfi
_conditions_bad_cfi:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_same_value x30 // Deliberate saved-LR recovery discrepancy.
    mov x29, sp
    .cfi_def_cfa x29, 16
    bl _conditions_sink
    ldp x29, x30, [sp]
    b.vs Lbadcfi_taken
    add sp, sp, #16
    ret
Lbadcfi_taken:
    add sp, sp, #16
    ret
    .cfi_endproc

.globl _conditions_unsupported
_conditions_unsupported:
    b.al Lunsupported_ret // AL/NV deliberately outside the bounded subset.
    nop
Lunsupported_ret:
    ret
Lunsupported_end:

.globl _conditions_sink
_conditions_sink:
    nop
    ret
Lsink_end:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _conditions_\name
.long Lend_\name-_conditions_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf equality
compact_leaf carry
compact_leaf sign
compact_leaf overflow
compact_leaf unsigned
compact_leaf signed
.quad _conditions_frame
.long Lframe_end-_conditions_frame
.long 0x04000000
.quad 0, 0
.quad _conditions_unsupported
.long Lunsupported_end-_conditions_unsupported
.long 0x02000000
.quad 0, 0
.quad _conditions_sink
.long Lsink_end-_conditions_sink
.long 0x02000000
.quad 0, 0
.subsections_via_symbols
