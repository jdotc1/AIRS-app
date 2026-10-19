// Small owned direct-call CFG inputs. The linked dylib is data, never executed.
// Explicit same-value CFI forces Apple DWARF fallback; x19 recovery is deliberately
// incomplete in the saved-pair example. No metadata is derived from engine output.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _fde_calls_choice
_fde_calls_choice:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13 // explicit same-value x19 forces DWARF fallback
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    cmp w0, #7
    b.le Lchoice_other
    bl _fde_calls_sink
    b Lchoice_done
Lchoice_other:
    bl _fde_calls_sink
Lchoice_done:
    ldp x29, x30, [sp], #16
    ret
    .cfi_endproc
Lchoice_end:

.globl _fde_calls_flags
_fde_calls_flags:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13 // explicit same-value x19 forces DWARF fallback
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    mov x0, #8
    cmp w0, #7
    bl _fde_calls_sink
    b.gt Lflags_second
    nop
    b Lflags_done
Lflags_second:
    bl _fde_calls_sink
Lflags_done:
    ldp x29, x30, [sp], #16
    ret
    .cfi_endproc
Lflags_end:

.globl _fde_calls_skip
_fde_calls_skip:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13 // explicit same-value x19 forces DWARF fallback
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    cmp w0, #7
    b.gt Lskip_done
    bl _fde_calls_sink
Lskip_done:
    ldp x29, x30, [sp], #16
    ret
    .cfi_endproc
Lskip_end:

.globl _fde_calls_bad_pair
_fde_calls_bad_pair:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13 // explicit same-value x19 forces DWARF fallback
    sub sp, sp, #32
    .cfi_def_cfa_offset 32
    stp x20, x19, [sp]
    stp x29, x30, [sp, #16]
    add x29, sp, #16
    .cfi_def_cfa x29, 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x0, #8
    cmp w0, #7
    b.le Lbad_done
    mov x19, #7
    bl _fde_calls_sink
Lbad_done:
    ldp x29, x30, [sp, #16]
    ldp x20, x19, [sp]
    add sp, sp, #32
    ret
    .cfi_endproc
Lbad_end:

.globl _fde_calls_known_skip
_fde_calls_known_skip:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13 // explicit same-value x19 forces DWARF fallback
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    mov x0, #8
    cmp w0, #7
    b.gt Lknown_done
    bl _fde_calls_sink
Lknown_done:
    ldp x29, x30, [sp], #16
    ret
    .cfi_endproc
Lknown_end:

.globl _fde_calls_escape
_fde_calls_escape:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13 // explicit same-value x19 forces DWARF fallback
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp
    .cfi_def_cfa x29, 16
    mov x0, sp
    b.le Lescape_done
    bl _fde_calls_sink
Lescape_done:
    ldp x29, x30, [sp], #16
    ret
    .cfi_endproc
Lescape_end:

.globl _fde_calls_sink
_fde_calls_sink:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_escape 0x08, 0x13 // explicit same-value x19 forces DWARF fallback
    nop
    ret
    .cfi_endproc
Lsink_end:

.subsections_via_symbols
