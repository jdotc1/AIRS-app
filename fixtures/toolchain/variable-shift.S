// Small owned register-shift corpus. Inspect as data; never execute.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro shift_leaf name, width, operation, source, count, expected
.globl _vshift_\name
_vshift_\name:
    mov x0, #\source
    mov x1, #\count
    mov x4, #1
    cmp w4, #1
    \operation \width\()2, \width\()0, \width\()1
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
shift_leaf w_lsl, w, lsl, 12, 1, 24
shift_leaf w_lsr, w, lsr, 12, 1, 6
shift_leaf w_asr, w, asr, 0x8000000180000001, 1, 0xc0000000
shift_leaf w_ror, w, ror, 0x8000000180000001, 1, 0xc0000000
shift_leaf x_lsl, x, lsl, 12, 1, 24
shift_leaf x_lsr, x, lsr, 12, 1, 6
shift_leaf x_asr, x, asr, 0x8000000000000001, 1, 0xc000000000000000
shift_leaf x_ror, x, ror, 0x8000000000000001, 1, 0xc000000000000000
shift_leaf w_lsl_wrap, w, lsl, 12, 33, 24
shift_leaf x_lsl_wrap, x, lsl, 12, 65, 24
shift_leaf w_ror_zero, w, ror, 0x8000000180000001, 32, 0x8000000180000001
shift_leaf x_ror_zero, x, ror, 0x8000000000000001, 64, 0x8000000000000001
shift_leaf w_asr_max, w, asr, 0x8000000180000001, 31, -1
shift_leaf x_asr_max, x, asr, 0x8000000000000001, 63, -1
.globl _vshift_zr_count
_vshift_zr_count:
    mov x0, #12
    lsl x2, x0, xzr
    cmp x2, #12
    b.eq Lzr_count_ret
    nop
Lzr_count_ret:
    ret
Lend_zr_count:
.globl _vshift_zr_source
_vshift_zr_source:
    mov x1, #63
    asr x2, xzr, x1
    cmp x2, #0
    b.eq Lzr_source_ret
    nop
Lzr_source_ret:
    ret
Lend_zr_source:
.globl _vshift_unknown_source
_vshift_unknown_source:
    mov x0, #1
    cmp w0, #1
    mov x1, #0
    ror x2, x9, x1
    b.eq Lunknown_source_ret
    nop
Lunknown_source_ret:
    ret
Lend_unknown_source:
.globl _vshift_unknown_count
_vshift_unknown_count:
    mov x0, #0
    cmp w0, #0
    lsl x2, x0, x9
    b.eq Lunknown_count_ret
    nop
Lunknown_count_ret:
    ret
Lend_unknown_count:
.globl _vshift_unknown_identity
_vshift_unknown_identity:
    ror x19, x19, xzr
    ret
Lend_unknown_identity:
.globl _vshift_good_fde
_vshift_good_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _vshift_sink
    asr x2, x0, x1
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _vshift_bad_cfi
_vshift_bad_cfi:
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
    lsr x2, x9, x10 // Unknown output preserves known Z1.
    b.eq Lbad_call
    nop
Lbad_call:
    bl _vshift_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc
.globl _vshift_reserved
_vshift_reserved:
    b Lreserved_ret
    .long 0x3ac12002 // S=1 unallocated.
    .long 0x5ac12002 // One-source space with invalid opcode2.
    .long 0x1ae12002 // Fixed bit21 changed.
Lreserved_ret:
    ret
Lend_reserved:
.globl _vshift_stack_value
_vshift_stack_value:
    add x0, sp, #0
    lsl x2, x0, xzr // Even zero count cannot hide stack provenance.
    ret
Lend_stack_value:
.globl _vshift_stack_count
_vshift_stack_count:
    add x1, sp, #0
    mov x0, #0
    ror x2, x0, x1 // Even zero value cannot hide count provenance.
    ret
Lend_stack_count:
.globl _vshift_sink
_vshift_sink:
    nop
    ret
Lend_sink:
.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _vshift_\name
.long Lend_\name-_vshift_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf w_lsl
compact_leaf w_lsr
compact_leaf w_asr
compact_leaf w_ror
compact_leaf x_lsl
compact_leaf x_lsr
compact_leaf x_asr
compact_leaf x_ror
compact_leaf w_lsl_wrap
compact_leaf x_lsl_wrap
compact_leaf w_ror_zero
compact_leaf x_ror_zero
compact_leaf w_asr_max
compact_leaf x_asr_max
compact_leaf zr_count
compact_leaf zr_source
compact_leaf unknown_source
compact_leaf unknown_count
compact_leaf unknown_identity
compact_leaf reserved
compact_leaf stack_value
compact_leaf stack_count
compact_leaf sink
.subsections_via_symbols
