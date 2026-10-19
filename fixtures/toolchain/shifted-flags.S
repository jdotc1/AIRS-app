// Owned bounded shifted-register cases. Linked image is never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro shifted_leaf name, left, right, op, width, shift, amount, condition
.globl _shiftflags_\name
_shiftflags_\name:
    mov x0, #\left
    mov x1, #\right
    \op \width\()2, \width\()0, \width\()1, \shift #\amount
    b.\condition Ltaken_\name
    nop
    b Ldone_\name
Ltaken_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
shifted_leaf wlsl, 0, 1, adds, w, lsl, 31, mi
shifted_leaf xlsl, 0, 1, adds, x, lsl, 63, mi
shifted_leaf wlsr, 0, 3, subs, w, lsr, 1, lo
shifted_leaf xlsr, -1, 3, adds, x, lsr, 1, hs
shifted_leaf wasr, 0x40000000, 0x80000000, adds, w, asr, 1, hs
shifted_leaf xasr, 0x4000000000000000, 0x8000000000000000, subs, x, asr, 1, vs

.globl _shiftflags_aliases
_shiftflags_aliases:
    mov x1, #1
    cmn wzr, w1, lsl #31
    cmp xzr, x1, lsr #63
    b.ne Lalias_other
    nop
    b Lalias_done
Lalias_other:
    nop
Lalias_done:
    ret
Lend_aliases:

.globl _shiftflags_unknown_fde
_shiftflags_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _shiftflags_sink
    subs w2, w0, w1, asr #31
    b.vs Lunknown_taken
    nop
Lunknown_taken:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _shiftflags_bad_cfi
_shiftflags_bad_cfi:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_same_value x30
    mov x29, sp
.cfi_def_cfa x29, 16
    mov x0, #0x4000000000000000
    mov x1, #0x8000000000000000
    subs x2, x0, x1, asr #1
    b.vs Lbad_call
    nop
Lbad_call:
    bl _shiftflags_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _shiftflags_reserved
_shiftflags_reserved:
    b Lreserved_ret
    .long 0x2bc10402 // Reserved shift=3, even in dead code.
Lreserved_ret:
    ret
Lend_reserved:

.globl _shiftflags_w32
_shiftflags_w32:
    .long 0x2b018002 // W shifted operand with imm6=32, architecturally reserved.
    ret
Lend_w32:

.globl _shiftflags_sink
_shiftflags_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _shiftflags_\name
.long Lend_\name-_shiftflags_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wlsl
compact_leaf xlsl
compact_leaf wlsr
compact_leaf xlsr
compact_leaf wasr
compact_leaf xasr
compact_leaf aliases
compact_leaf reserved
compact_leaf w32
compact_leaf sink
.subsections_via_symbols
