// Owned bitfield fixture. Linked image is input data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro bit_leaf name, op, width, source, r, s, expected, zr
.globl _bitfield_\name
_bitfield_\name:
    mov x0, #\source
    mov x2, #0x1234
    mov x1, #1
    cmp w1, #1 // Z1,C1; bitfield must preserve NZCV.
.if \zr
    \op \width\()2, \width\()zr, #\r, #\s
.else
    \op \width\()2, \width\()0, #\r, #\s
.endif
    b.eq Lvalue_\name
    nop
Lvalue_\name:
    mov x3, #\expected
    cmp \width\()2, \width\()3
    b.eq Lret_\name
    nop
Lret_\name:
    ret
Lend_\name:
.endmacro
bit_leaf w_unsigned_extract, ubfm, w, 0xab, 4, 7, 10, 0
bit_leaf w_signed_extract, sbfm, w, 0xab, 4, 7, -6, 0
bit_leaf w_insert_low, bfm, w, 0xab, 4, 7, 0x123a, 0
bit_leaf x_unsigned_insert, ubfm, x, 0xab, 60, 3, 0xb0, 0
bit_leaf x_signed_insert, sbfm, x, 0xab, 60, 3, -80, 0
bit_leaf x_insert, bfm, x, 0xab, 60, 3, 0x12b4, 0
bit_leaf w_lsl, ubfm, w, 0xab, 31, 30, 0x156, 0
bit_leaf x_lsl, ubfm, x, 0xab, 63, 62, 0x156, 0
bit_leaf x_lsr, ubfm, x, 0xab, 4, 63, 10, 0
bit_leaf x_asr, sbfm, x, 0x8000000000000000, 63, 63, -1, 0
bit_leaf x_sxtb, sbfm, x, 0x80, 0, 7, -128, 0
bit_leaf x_sxtw, sbfm, x, 0x80000000, 0, 31, -2147483648, 0
bit_leaf x_bfc, bfm, x, 0, 60, 3, 0x1204, 1

.globl _bitfield_unknown_source
_bitfield_unknown_source:
    mov x0, #1
    cmp w0, #1
    ubfm x2, x9, #4, #7
    b.eq Lunknown_ret
    nop
Lunknown_ret:
    ret
Lend_unknown_source:
.globl _bitfield_unknown_old
_bitfield_unknown_old:
    mov x0, #1
    bfm x19, x0, #0, #63 // Conservative: old destination is unknown, even full replacement.
    ret
Lend_unknown_old:
.globl _bitfield_unknown_fde
_bitfield_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _bitfield_sink
    sbfm x2, x0, #4, #7
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _bitfield_bad_cfi
_bitfield_bad_cfi:
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
    ubfm x2, x9, #4, #7 // Unknown result preserves known Z1.
    b.eq Lbad_call
    nop
Lbad_call:
    bl _bitfield_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _bitfield_invalid_n
_bitfield_invalid_n:
    b Ln_ret
    .long 0x53400002 // W UBFM N1, invalid.
    .long 0xd3000002 // X UBFM N0, invalid.
Ln_ret:
    ret
Lend_invalid_n:
.globl _bitfield_invalid_w
_bitfield_invalid_w:
    .long 0x53200002 // W immr32, invalid.
    ret
Lend_invalid_w:
.globl _bitfield_stack
_bitfield_stack:
    add x0, sp, #0
    ubfm x2, x0, #4, #7
    ret
Lend_stack:
.globl _bitfield_sink
_bitfield_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _bitfield_\name
.long Lend_\name-_bitfield_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf w_unsigned_extract
compact_leaf w_signed_extract
compact_leaf w_insert_low
compact_leaf x_unsigned_insert
compact_leaf x_signed_insert
compact_leaf x_insert
compact_leaf w_lsl
compact_leaf x_lsl
compact_leaf x_lsr
compact_leaf x_asr
compact_leaf x_sxtb
compact_leaf x_sxtw
compact_leaf x_bfc
compact_leaf unknown_source
compact_leaf unknown_old
compact_leaf invalid_n
compact_leaf invalid_w
compact_leaf stack
compact_leaf sink
.subsections_via_symbols
