// Owned shared return suffix inputs. Linked image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _suffix_leaf
_suffix_leaf:
    sub sp, sp, #32
    cmp w0, #7
    b.gt Lleaf_other
    nop
    add sp, sp, #16
    b Lleaf_common
Lleaf_other:
    nop
    add sp, sp, #16
Lleaf_common:
    add sp, sp, #16
    ret
Lleaf_end:

.globl _suffix_frame
_suffix_frame:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.gt Lframe_other
    bl _suffix_sink
    ldp x29, x30, [sp]
    b Lframe_common
Lframe_other:
    bl _suffix_sink
    ldp x29, x30, [sp]
Lframe_common:
    add sp, sp, #16
    ret
Lframe_end:

.globl _suffix_dwarf
_suffix_dwarf:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    cmp w0, #7
    b.gt Ldwarf_other
    bl _suffix_sink
    ldp x29, x30, [sp]
    b Ldwarf_common
Ldwarf_other:
    .cfi_def_cfa x29, 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    bl _suffix_sink
    ldp x29, x30, [sp]
Ldwarf_common:
    add sp, sp, #16
    ret
    .cfi_endproc

.globl _suffix_bad_cfi
_suffix_bad_cfi:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_same_value x30 // Deliberately wrong recovery at calls.
    mov x29, sp
    .cfi_def_cfa x29, 16
    mov x0, #8
    cmp w0, #7
    b.le Lbadcfi_other
    bl _suffix_sink
    ldp x29, x30, [sp]
    b Lbadcfi_common
Lbadcfi_other:
    bl _suffix_sink
    ldp x29, x30, [sp]
Lbadcfi_common:
    add sp, sp, #16
    ret
    .cfi_endproc

.globl _suffix_bad_state
_suffix_bad_state:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.gt Lstate_other
    bl _suffix_sink
    ldp x29, x30, [sp]
    b Lstate_common
Lstate_other:
    mov x19, #7
    ldp x29, x30, [sp]
Lstate_common:
    add sp, sp, #16
    ret
Lstate_end:

.globl _suffix_bad_edge
_suffix_bad_edge:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.gt Ledge_common // Ordinary body edge may not bypass the restore.
    bl _suffix_sink
    ldp x29, x30, [sp]
    b Ledge_common
    bl _suffix_sink
    ldp x29, x30, [sp]
Ledge_common:
    add sp, sp, #16
    ret
Ledge_end:

.globl _suffix_sink
_suffix_sink:
    nop
    ret
Lsink_end:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.quad _suffix_leaf
.long Lleaf_end-_suffix_leaf
.long 0x02002000
.quad 0, 0
.quad _suffix_frame
.long Lframe_end-_suffix_frame
.long 0x04000000
.quad 0, 0
.quad _suffix_bad_state
.long Lstate_end-_suffix_bad_state
.long 0x04000000
.quad 0, 0
.quad _suffix_bad_edge
.long Ledge_end-_suffix_bad_edge
.long 0x04000000
.quad 0, 0
.quad _suffix_sink
.long Lsink_end-_suffix_sink
.long 0x02000000
.quad 0, 0
.subsections_via_symbols
