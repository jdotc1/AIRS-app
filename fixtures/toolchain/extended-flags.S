// Small owned extended-register cases. The linked image is input data only.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro extended_leaf name, left, right, op, width, sourcewidth, extend, amount, condition
.globl _extflags_\name
_extflags_\name:
    mov x0, #\left
    mov x1, #\right
    \op \width\()2, \width\()0, \sourcewidth\()1, \extend #\amount
    b.\condition Ltaken_\name
    nop
    b Ldone_\name
Ltaken_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
extended_leaf uxtb, -3856, 0xf1, adds, w, w, uxtb, 4, hs
extended_leaf uxth, 0, 0x8000, subs, w, w, uxth, 0, lo
extended_leaf uxtw, 0, -1, adds, x, w, uxtw, 0, pl
extended_leaf uxtx, 0, 1, adds, x, x, uxtx, 4, ne
extended_leaf sxtb, 16, 0xff, adds, w, w, sxtb, 4, hs
extended_leaf sxth, 0, 0x8000, subs, w, w, sxth, 0, pl
extended_leaf sxtw, 0, 0x80000000, adds, x, w, sxtw, 0, mi
extended_leaf sxtx, 0x7fffffffffffffff, -1, subs, x, x, sxtx, 0, vs

.globl _extflags_aliases
_extflags_aliases:
    mov x0, #7
    mov x1, #0xff
    cmn w0, wzr, uxth #4
    cmp x0, w1, sxtb
    b.eq Lalias_other
    nop
    b Lalias_done
Lalias_other:
    nop
Lalias_done:
    ret
Lend_aliases:

.globl _extflags_unknown_fde
_extflags_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _extflags_sink
    adds x2, x0, w1, sxtb #4
    b.vs Lunknown_taken
    nop
Lunknown_taken:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _extflags_bad_cfi
_extflags_bad_cfi:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_same_value x30
    mov x29, sp
.cfi_def_cfa x29, 16
    mov x0, #0x7fffffffffffffff
    mov x1, #0xff
    subs x2, x0, w1, sxtb
    b.vs Lbad_call
    nop
Lbad_call:
    bl _extflags_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _extflags_sp
_extflags_sp:
    cmp sp, w1, sxtw // Architectural SP source deliberately excluded.
    ret
Lend_sp:

.globl _extflags_shift5
_extflags_shift5:
    b Lshift5_ret
    .long 0xab215402 // UX TW with imm3=5, even in dead code.
Lshift5_ret:
    ret
Lend_shift5:

.globl _extflags_w64
_extflags_w64:
    .long 0x2b216002 // W option UXTX deliberately outside bounded subset.
    ret
Lend_w64:

.globl _extflags_sink
_extflags_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _extflags_\name
.long Lend_\name-_extflags_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf uxtb
compact_leaf uxth
compact_leaf uxtw
compact_leaf uxtx
compact_leaf sxtb
compact_leaf sxth
compact_leaf sxtw
compact_leaf sxtx
compact_leaf aliases
compact_leaf sp
compact_leaf shift5
compact_leaf w64
compact_leaf sink
.subsections_via_symbols
