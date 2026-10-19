// Owned two-loop CFG recovery witnesses. Inspect bytes only; never execute.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _two_loops_agree
_two_loops_agree:
    mov x0, #2
Lgood_first:
    subs x0, x0, #1
    b.ne Lgood_first
    mov x1, #2
Lgood_second:
    subs x1, x1, #1
    b.ne Lgood_second
    ret
Lend_good:

.globl _two_loops_bad_rule
_two_loops_bad_rule:
    sub sp, sp, #16
    mov x0, #2
Lbad_first:
    subs x0, x0, #1
    b.ne Lbad_first
    mov x1, #2
Lbad_second:
    subs x1, x1, #1
    b.ne Lbad_second
    add sp, sp, #16
    ret
Lend_bad:

.globl _two_loops_middle_entry
_two_loops_middle_entry:
    b.eq Lmiddle
Lmiddle_header:
    nop
Lmiddle:
    nop
    b.ne Lmiddle_header
    mov x0, #2
Lmiddle_second:
    subs x0, x0, #1
    b.ne Lmiddle_second
    ret
Lend_middle:

.section __LD,__compact_unwind,regular,debug
.p2align 3
.quad _two_loops_agree
.long Lend_good-_two_loops_agree
.long 0x02000000
.quad 0, 0
.quad _two_loops_bad_rule
.long Lend_bad-_two_loops_bad_rule
.long 0x02002000
.quad 0, 0
.quad _two_loops_middle_entry
.long Lend_middle-_two_loops_middle_entry
.long 0x02000000
.quad 0, 0
.subsections_via_symbols
