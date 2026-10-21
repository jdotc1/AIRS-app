// Maintainer-owned inspection fixtures. PREPARED ONLY: never execute this image.
// Reuse: AIRS canonical/high-multiply compact records and saved-pair patterns;
// AIRS loops.S / owned MacScope control_flow.s branch and counted-loop shapes.
// No CFI is synthesized here: explicit compact rules are the controlled input.
.section __TEXT,__text,regular,pure_instructions
.p2align 2

// 80-byte frame: local slots SP+0/+8; x24/x23 at +16/+24;
// x22/x21 at +32/+40; x20/x19 at +48/+56; FP/LR at +64/+72.
// FP=entrySP-16. Compact reads lower-numbered saved registers at higher addresses.
.macro nl_setup
    sub sp, sp, #80
    stp x20, x19, [sp, #48]
    stp x22, x21, [sp, #32]
    stp x24, x23, [sp, #16]
    stp x29, x30, [sp, #64]
    add x29, sp, #64
.endmacro
.macro nl_teardown
    ldp x29, x30, [sp, #64]
    ldp x24, x23, [sp, #16]
    ldp x22, x21, [sp, #32]
    ldp x20, x19, [sp, #48]
    add sp, sp, #80
    ret
.endmacro

.globl _airs_nl_pressure_branch
_airs_nl_pressure_branch:
    nl_setup
    mov x19, #19
    mov x20, #20
    mov x21, #21
    mov x22, #22
    mov x23, #23
    mov x24, #24
    str x0, [sp]
    ldr x8, [sp]
    str w8, [sp, #8]
    ldr w9, [sp, #8]
    cmp w9, #0
    b.eq Lnl_zero
    mov x19, #6
    bl _airs_nl_sink
    b Lnl_join
Lnl_zero:
    mov x19, #9
    bl _airs_nl_sink
Lnl_join:
    nl_teardown
Lend_nl_pressure_branch:

.globl _airs_nl_call_loop
_airs_nl_call_loop:
    nl_setup
    mov x19, #2
Lnl_loop:
    bl _airs_nl_sink
    subs x19, x19, #1
    b.ne Lnl_loop
    nl_teardown
Lend_nl_call_loop:

// Intentionally wrong compact rule omits saved integer pairs. Actual return
// still restores every original register; BL recovery sees known live x19=6.
.globl _airs_nl_wrong_rule
_airs_nl_wrong_rule:
    nl_setup
    mov x19, #6
    bl _airs_nl_sink
    nl_teardown
Lend_nl_wrong_rule:

// The same omission must not turn a symbolic quotient into a known mismatch.
.globl _airs_nl_unknown_recovery
_airs_nl_unknown_recovery:
    nl_setup
    udiv x19, x0, x1
    bl _airs_nl_sink
    nl_teardown
Lend_nl_unknown_recovery:

// Two ISA-valid but deliberately unsupported forms. Inventory BOTH after future
// independent disassembly; the engine's first stop alone cannot rank the body.
.globl _airs_nl_unsupported
_airs_nl_unsupported:
    nl_setup
    sdiv x0, x0, x1
    ldr x0, [x29]
    bl _airs_nl_sink
    nl_teardown
Lend_nl_unsupported:

// Reserved bitfield sf=1,N=0. It is retained as data; no target is executed.
.globl _airs_nl_invalid
_airs_nl_invalid:
    nl_setup
    .long 0x93000000
    bl _airs_nl_sink
    nl_teardown
Lend_nl_invalid:

// Clearing the live argument is insufficient: the stored pointer still escapes.
.globl _airs_nl_pointer_escape
_airs_nl_pointer_escape:
    nl_setup
    add x0, sp, #0
    str x0, [sp]
    mov x0, #0
    bl _airs_nl_sink
    nl_teardown
Lend_nl_pointer_escape:

.globl _airs_nl_sink
.private_extern _airs_nl_sink
_airs_nl_sink:
    nop
    ret
Lend_nl_sink:

// Reuse the accepted explicit compact-unwind record layout; no compiler-derived
// CFI expectations or engine-produced expected verdicts are substituted.
.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro nl_compact name, encoding
    .quad _airs_nl_\name
    .long Lend_nl_\name-_airs_nl_\name
    .long \encoding
    .quad 0, 0
.endmacro
nl_compact pressure_branch, 0x04000007
nl_compact call_loop, 0x04000007
nl_compact wrong_rule, 0x04000000
nl_compact unknown_recovery, 0x04000000
nl_compact unsupported, 0x04000007
nl_compact invalid, 0x04000007
nl_compact pointer_escape, 0x04000007
nl_compact sink, 0x02000000
.subsections_via_symbols
