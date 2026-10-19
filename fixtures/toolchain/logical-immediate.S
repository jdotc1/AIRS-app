// Owned logical-immediate masks. Linked image is data, never executed.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro mask_leaf name, width, mask, condition
.globl _immflags_\name
_immflags_\name:
    mov x0, #-1
    ands \width\()2, \width\()0, #\mask
    b.\condition Ltaken_\name
    nop
    b Ldone_\name
Ltaken_\name:
    nop
Ldone_\name:
    ret
Lend_\name:
.endmacro
mask_leaf repeat2, w, 0x55555555, ne
mask_leaf rotate4, w, 0xbbbbbbbb, mi
mask_leaf rotate8, w, 0xf0f0f0f0, mi
mask_leaf rotate16, w, 0xff00ff00, mi
mask_leaf rotate32, w, 0xffff0000, mi
mask_leaf repeat32x, x, 0xffff0000ffff0000, mi
mask_leaf rotate64, x, 0xf00000000000000f, mi
mask_leaf long64, x, 0xbfffffffffffffff, mi

.globl _immflags_aliases
_immflags_aliases:
    mov x0, #3
    ands x2, xzr, #0xff
    tst w0, #1
    b.ne Lalias_taken
    nop
Lalias_taken:
    ret
Lend_aliases:

.globl _immflags_clear_cv
_immflags_clear_cv:
    mov x0, #0x80000000
    cmp w0, #1
    mov x0, #3
    ands w2, w0, #1
    csel w3, w2, wzr, vc
    b.lo Lclear_taken
    nop
Lclear_taken:
    ret
Lend_clear_cv:

.globl _immflags_unknown_fde
_immflags_unknown_fde:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    bl _immflags_sink
    ands x2, x0, #0xf0f0f0f0f0f0f0f0
    b.eq Lunknown_taken
    nop
Lunknown_taken:
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _immflags_bad_cfi
_immflags_bad_cfi:
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
    ands x2, x0, #0xf00000000000000f
    b.mi Lbad_call
    nop
Lbad_call:
    bl _immflags_sink
    ldp x29, x30, [sp]
    add sp, sp, #16
    ret
.cfi_endproc

.globl _immflags_wn1
_immflags_wn1:
    .long 0x72400002 // W N=1 is reserved.
    ret
Lend_wn1:

.globl _immflags_allones
_immflags_allones:
    .long 0xf240fc02 // X full-width all-ones encoding is reserved.
    ret
Lend_allones:

.globl _immflags_shortlen
_immflags_shortlen:
    b Lshortlen_ret
    .long 0x7200f802 // N=0, imms=62 selects invalid element length, even dead.
Lshortlen_ret:
    ret
Lend_shortlen:

.globl _immflags_sink
_immflags_sink:
    nop
    ret
Lend_sink:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact_leaf name
.quad _immflags_\name
.long Lend_\name-_immflags_\name
.long 0x02000000
.quad 0, 0
.endmacro
compact_leaf repeat2
compact_leaf rotate4
compact_leaf rotate8
compact_leaf rotate16
compact_leaf rotate32
compact_leaf repeat32x
compact_leaf rotate64
compact_leaf long64
compact_leaf aliases
compact_leaf clear_cv
compact_leaf wn1
compact_leaf allones
compact_leaf shortlen
compact_leaf sink
.subsections_via_symbols
