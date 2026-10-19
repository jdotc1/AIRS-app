// Owned logical register fixture. Linked image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro logic_leaf name, op, width, rhs, shift, amount, condition
.globl _logic_\name
_logic_\name:
    mov x0, #8
    mov x1, #\rhs
    cmp w0, #7 // NZCV=0010; result must not replace these flags.
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
logic_leaf wand, and, w, 1, lsr, 1, ne
logic_leaf wbic, bic, w, 8, lsl, 0, ne
logic_leaf worr, orr, w, 1, ror, 1, pl
logic_leaf worn, orn, w, 8, asr, 1, pl
logic_leaf weor, eor, w, 8, lsl, 0, ne
logic_leaf weon, eon, w, 8, lsr, 1, pl
logic_leaf xand, and, x, 1, lsr, 1, ne
logic_leaf xbic, bic, x, 8, lsl, 0, ne
logic_leaf xorr, orr, x, 1, ror, 1, pl
logic_leaf xorn, orn, x, 8, asr, 1, pl
logic_leaf xeor, eor, x, 8, lsl, 0, ne
logic_leaf xeon, eon, x, 8, lsr, 1, pl

.globl _logic_aliases
_logic_aliases:
    mov x0, #8
    cmp w0, #7
    mov x2, x19 // Retains original X identity under existing exact alias.
    mov w3, w0
    mvn x4, x0, ror #63
    orr xzr, x0, x0 // ZR destination, not SP.
    b.hs Lalias_ret
    nop
Lalias_ret:
    ret
Lend_aliases:

.globl _logic_unknown
_logic_unknown:
    mov x0, #8
    cmp w0, #7
    orn x2, x0, x9, lsl #3
    csel w3, w0, wzr, hs
    b.hs Lunknown_ret
    nop
Lunknown_ret:
    ret
Lend_unknown:

.globl _logic_unknown_fde
_logic_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _logic_sink
    eon x2, xzr, xzr // Concrete allones does not establish NZCV.
    b.eq Lfde_ret
    nop
Lfde_ret:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _logic_bad_cfi
_logic_bad_cfi:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_same_value x30
    mov x29, sp
.cfi_def_cfa x29, 16
    mov x0, #8
    cmp w0, #7
    eon x2, x0, x9, ror #7
    b.ne Lbad_call
    nop
Lbad_call:
    bl _logic_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _logic_reserved
_logic_reserved:
    b Lreserved_ret
    .long 0x2a018002 // W ORR shift32, reserved even in dead code.
Lreserved_ret:
    ret
Lend_reserved:
.globl _logic_carry
_logic_carry:
    .long 0xba010002 // ADCS remains unsupported.
    ret
Lend_carry:
.globl _logic_stack
_logic_stack:
    add x0, sp, #0
    orr x2, x0, x1
    ret
Lend_stack:
.globl _logic_sink
_logic_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _logic_\name
.long Lend_\name-_logic_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wand
compact_leaf wbic
compact_leaf worr
compact_leaf worn
compact_leaf weor
compact_leaf weon
compact_leaf xand
compact_leaf xbic
compact_leaf xorr
compact_leaf xorn
compact_leaf xeor
compact_leaf xeon
compact_leaf aliases
compact_leaf unknown
compact_leaf reserved
compact_leaf carry
compact_leaf stack
compact_leaf sink
.subsections_via_symbols
