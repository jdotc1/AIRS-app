// Owned nonflag logical immediates. Linked image is input data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro nonflag_leaf name, op, width, mask, condition
.globl _nonflags_\name
_nonflags_\name:
    mov x0, #8
    cmp w0, #7 // N=0,Z=0,C=1,V=0; nonflag result must not replace these flags.
    \op \width\()2, \width\()0, #\mask
    b.\condition Ltaken_\name
    nop
    b Ldone_\name
Ltaken_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
nonflag_leaf wand, and, w, 1, ne
nonflag_leaf worr, orr, w, 0x80000000, pl
nonflag_leaf weor, eor, w, 8, ne
nonflag_leaf xand, and, x, 1, ne
nonflag_leaf xorr, orr, x, 0x8000000000000000, pl
nonflag_leaf xeor, eor, x, 8, ne

.globl _nonflags_mov_masks
_nonflags_mov_masks:
    mov x0, #8
    cmp w0, #7
    mov w2, #0x55555555
    mov x3, #0xf00000000000000f
    b.hs Lmov_taken
    nop
Lmov_taken:
    ret
Lend_mov_masks:

.globl _nonflags_unknown_result
_nonflags_unknown_result:
    mov x0, #8
    cmp w0, #7
    and x2, x9, #0xff // Unknown result must preserve the concrete comparison flags.
    csel w3, w0, wzr, hs
    b.hs Lunknown_taken
    nop
Lunknown_taken:
    ret
Lend_unknown_result:

.globl _nonflags_unknown_fde
_nonflags_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _nonflags_sink
    mov x2, #0x5555555555555555 // Concrete MOV bitmask does not establish NZCV.
    b.eq Lfde_taken
    nop
Lfde_taken:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _nonflags_bad_cfi
_nonflags_bad_cfi:
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
    eor x2, x9, #0xff
    b.ne Lbad_call
    nop
Lbad_call:
    bl _nonflags_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _nonflags_sp
_nonflags_sp:
    orr sp, x0, #1 // Nonflag destination31 is SP, explicitly outside model.
    ret
Lend_sp:

.globl _nonflags_reserved
_nonflags_reserved:
    b Lreserved_ret
    .long 0xb240fc02 // ORR all-ones mask is reserved, even in dead code.
Lreserved_ret:
    ret
Lend_reserved:

.globl _nonflags_register
_nonflags_register:
    orr x2, x0, x1 // General nonflag register operations remain outside this subset.
    ret
Lend_register:

.globl _nonflags_sink
_nonflags_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _nonflags_\name
.long Lend_\name-_nonflags_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf wand
compact_leaf worr
compact_leaf weor
compact_leaf xand
compact_leaf xorr
compact_leaf xeor
compact_leaf mov_masks
compact_leaf unknown_result
compact_leaf sp
compact_leaf reserved
compact_leaf register
compact_leaf sink
.subsections_via_symbols
