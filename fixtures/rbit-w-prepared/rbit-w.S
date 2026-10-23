// Maintainer-owned source preparation only. Never execute the selected image.
// Reuse AIRS RBIT/CLZ literal sequences and compact leaf-record pattern.
// MacScope owned scalar one-source decoder/evaluator supplies width semantics.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _airs_wrbit_constant
_airs_wrbit_constant:
    mov x0, #1
    rbit w0, w0
    ret
Lend_wrbit_constant:

.globl _airs_wrbit_unknown_ctz
_airs_wrbit_unknown_ctz:
    rbit w8, w0
    clz w0, w8
    ret
Lend_wrbit_unknown_ctz:

.globl _airs_wrbit_zero
_airs_wrbit_zero:
    rbit w0, wzr
    ret
Lend_wrbit_zero:

.globl _airs_xrbit_control
_airs_xrbit_control:
    rbit x8, x0
    clz x0, x8
    ret
Lend_xrbit_control:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro leaf_record name
    .quad _airs_\name
    .long Lend_\name-_airs_\name
    .long 0x02000000
    .quad 0, 0
.endmacro
leaf_record wrbit_constant
leaf_record wrbit_unknown_ctz
leaf_record wrbit_zero
leaf_record xrbit_control
.subsections_via_symbols
