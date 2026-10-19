// Owned A64 logical flags. Linked image is data and is never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro logical_leaf name, right, op, width, shift, amount, condition
.globl _logicflags_\name
_logicflags_\name:
    mov x0, #-1
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
logical_leaf wlsl, 3, ands, w, lsl, 1, ne
logical_leaf wlsr, 3, bics, w, lsr, 1, mi
logical_leaf wasr, 0x80000000, ands, w, asr, 1, mi
logical_leaf wror, 3, bics, w, ror, 1, pl
logical_leaf xlsl, 3, bics, x, lsl, 1, mi
logical_leaf xlsr, 3, ands, x, lsr, 1, ne
logical_leaf xasr, 0x8000000000000000, bics, x, asr, 1, pl
logical_leaf xror, 3, ands, x, ror, 1, mi

.globl _logicflags_clear_cv
_logicflags_clear_cv:
    mov x0, #0x80000000
    cmp w0, #1 // Arithmetic C=1,V=1 before logical instruction.
    mov x0, #3
    mov x1, #1
    ands w2, w0, w1 // Logical C=0,V=0.
    csel w3, w2, wzr, vc
    b.lo Lclear_taken
    nop
Lclear_taken:
    ret
Lend_clear_cv:

.globl _logicflags_tst
_logicflags_tst:
    mov x0, #3
    mov x1, #1
    tst w0, w1
    b.ne Ltst_taken
    nop
Ltst_taken:
    ret
Lend_tst:

.globl _logicflags_unknown_fde
_logicflags_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _logicflags_sink
    ands x2, x0, x1, ror #1
    b.eq Lunknown_taken
    nop
Lunknown_taken:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _logicflags_bad_cfi
_logicflags_bad_cfi:
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
    mov x1, #3
    bics x2, x0, x1, ror #1
    b.pl Lbad_call
    nop
Lbad_call:
    bl _logicflags_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _logicflags_w32
_logicflags_w32:
    .long 0x6a018002 // W logical imm6=32 is reserved.
    ret
Lend_w32:

.globl _logicflags_immediate
_logicflags_immediate:
    b Limmediate_ret
    tst x0, #1 // Logical immediate deliberately outside this subset, even dead.
Limmediate_ret:
    ret
Lend_immediate:

.globl _logicflags_sink
_logicflags_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _logicflags_\name
.long Lend_\name-_logicflags_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wlsl
compact_leaf wlsr
compact_leaf wasr
compact_leaf wror
compact_leaf xlsl
compact_leaf xlsr
compact_leaf xasr
compact_leaf xror
compact_leaf clear_cv
compact_leaf tst
compact_leaf w32
compact_leaf immediate
compact_leaf sink
.subsections_via_symbols
