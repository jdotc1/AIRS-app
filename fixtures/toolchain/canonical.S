// Owned ARM64 assembly for independent Apple-toolchain validation.
// This file is supplied but has not been assembled in the Linux environment.
// The build recipe links it as a dylib and never executes that dylib.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _airs_canonical
_airs_canonical:
    .cfi_startproc
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset 29, -16
    .cfi_offset 30, -8
    mov x29, sp
    .cfi_def_cfa 29, 16
    nop
    bl _airs_sink
    ldp x29, x30, [sp], #16
    .cfi_def_cfa 31, 0
    .cfi_restore 29
    .cfi_restore 30
    ret
    .cfi_endproc

.p2align 2
.globl _airs_leaf
_airs_leaf:
    .cfi_startproc
    sub sp, sp, #32
    .cfi_def_cfa_offset 32
    nop
    add sp, sp, #32
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc

.subsections_via_symbols
