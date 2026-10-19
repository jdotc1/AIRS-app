// Owned EXTR / ROR-immediate fixture. Image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro extract_leaf name, width, high, low, amount, expected, rotate, zr
.globl _extract_\name
_extract_\name:
    mov x0, #\high
    mov x1, #\low
    mov x4, #1
    cmp w4, #1 // Z1,C1; EXTR/ROR must preserve flags.
.if \rotate
    ror \width\()2, \width\()0, #\amount
.elseif \zr
    extr \width\()2, \width\()zr, \width\()1, #\amount
.else
    extr \width\()2, \width\()0, \width\()1, #\amount
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
extract_leaf w_zero, w, 0x12, 0x34, 0, 0x34, 0, 0
extract_leaf w_pair, w, 0x12, 0x34, 8, 0x12000000, 0, 0
extract_leaf w_max, w, 1, 0x80000000, 31, 3, 0, 0
extract_leaf x_zero, x, 0x12, 0x34, 0, 0x34, 0, 0
extract_leaf x_pair, x, 0x12, 0x34, 8, 0x1200000000000000, 0, 0
extract_leaf x_max, x, 1, 0x8000000000000000, 63, 3, 0, 0
extract_leaf w_ror_zero, w, 0x8000000180000001, 0, 0, 0x8000000180000001, 1, 0
extract_leaf w_ror_one, w, 0x8000000180000001, 0, 1, 0xc0000000, 1, 0
extract_leaf w_ror_max, w, 0x8000000180000001, 0, 31, 3, 1, 0
extract_leaf x_ror_zero, x, 0x8000000000000001, 0, 0, 0x8000000000000001, 1, 0
extract_leaf x_ror_one, x, 0x8000000000000001, 0, 1, 0xc000000000000000, 1, 0
extract_leaf x_ror_max, x, 0x8000000000000001, 0, 63, 3, 1, 0
extract_leaf zr_high, x, 0x12, 8, 1, 4, 0, 1

.globl _extract_unknown_source
_extract_unknown_source:
    mov x0, #1
    cmp w0, #1
    extr x2, x9, x10, #8
    b.eq Lunknown_ret
    nop
Lunknown_ret:
    ret
Lend_unknown_source:
.globl _extract_unknown_ror_zero
_extract_unknown_ror_zero:
    ror x19, x19, #0 // No invented copy identity from unknown source.
    ret
Lend_unknown_ror_zero:
.globl _extract_unknown_fde
_extract_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _extract_sink
    ror x2, x0, #1
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _extract_bad_cfi
_extract_bad_cfi:
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
    extr x2, x9, x10, #8 // Unknown result keeps known Z1.
    b.eq Lbad_call
    nop
Lbad_call:
    bl _extract_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _extract_invalid_n
_extract_invalid_n:
    b Ln_ret
    .long 0x13c10002 // W N1, invalid.
    .long 0x93810002 // X N0, invalid.
Ln_ret:
    ret
Lend_invalid_n:
.globl _extract_invalid_w
_extract_invalid_w:
    .long 0x13818002 // W shift32, invalid.
    ret
Lend_invalid_w:
.globl _extract_reserved
_extract_reserved:
    b Lreserved_ret
    .long 0x13a10002 // Reserved bit21.
    .long 0x33810002 // Reserved op control.
Lreserved_ret:
    ret
Lend_reserved:
.globl _extract_stack
_extract_stack:
    add x0, sp, #0
    mov x1, #1
    extr x2, x0, x1, #0 // High operand unused arithmetically, still outside provenance subset.
    ret
Lend_stack:
.globl _extract_sink
_extract_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _extract_\name
.long Lend_\name-_extract_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf w_zero
compact_leaf w_pair
compact_leaf w_max
compact_leaf x_zero
compact_leaf x_pair
compact_leaf x_max
compact_leaf w_ror_zero
compact_leaf w_ror_one
compact_leaf w_ror_max
compact_leaf x_ror_zero
compact_leaf x_ror_one
compact_leaf x_ror_max
compact_leaf zr_high
compact_leaf unknown_source
compact_leaf unknown_ror_zero
compact_leaf invalid_n
compact_leaf invalid_w
compact_leaf reserved
compact_leaf stack
compact_leaf sink
.subsections_via_symbols
