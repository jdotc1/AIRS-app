// Small owned direct-call CFG inputs. The linked dylib is data, never executed.
// Compact rules are selected explicitly below, independently of engine output.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _calls_choice
_calls_choice:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.le Lchoice_other
    bl _calls_sink
    b Lchoice_done
Lchoice_other:
    bl _calls_sink
Lchoice_done:
    ldp x29, x30, [sp], #16
    ret
Lchoice_end:

.globl _calls_flags
_calls_flags:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #8
    cmp w0, #7
    bl _calls_sink
    b.gt Lflags_second
    nop
    b Lflags_done
Lflags_second:
    bl _calls_sink
Lflags_done:
    ldp x29, x30, [sp], #16
    ret
Lflags_end:

.globl _calls_skip
_calls_skip:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #7
    b.gt Lskip_done
    bl _calls_sink
Lskip_done:
    ldp x29, x30, [sp], #16
    ret
Lskip_end:

.globl _calls_bad_pair
_calls_bad_pair:
    sub sp, sp, #32
    stp x20, x19, [sp]
    stp x29, x30, [sp, #16]
    add x29, sp, #16
    mov x0, #8
    cmp w0, #7
    b.le Lbad_done
    mov x19, #7
    bl _calls_sink
Lbad_done:
    ldp x29, x30, [sp, #16]
    ldp x20, x19, [sp]
    add sp, sp, #32
    ret
Lbad_end:

.globl _calls_known_skip
_calls_known_skip:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #8
    cmp w0, #7
    b.gt Lknown_done
    bl _calls_sink
Lknown_done:
    ldp x29, x30, [sp], #16
    ret
Lknown_end:

.globl _calls_escape
_calls_escape:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, sp
    b.le Lescape_done
    bl _calls_sink
Lescape_done:
    ldp x29, x30, [sp], #16
    ret
Lescape_end:

.globl _calls_sink
_calls_sink:
    nop
    ret
Lsink_end:

// Each object compact-unwind record: code pointer, length, encoding,
// personality pointer, LSDA pointer. Linker emits final __unwind_info.
.section __LD,__compact_unwind,regular,debug
.p2align 3
.quad _calls_choice
.long Lchoice_end-_calls_choice
.long 0x04000000
.quad 0
.quad 0
.quad _calls_flags
.long Lflags_end-_calls_flags
.long 0x04000000
.quad 0
.quad 0
.quad _calls_skip
.long Lskip_end-_calls_skip
.long 0x04000000
.quad 0
.quad 0
.quad _calls_bad_pair
.long Lbad_end-_calls_bad_pair
// Intentionally omits x19/x20 save bit: a supported recovery discrepancy.
.long 0x04000000
.quad 0
.quad 0
.quad _calls_known_skip
.long Lknown_end-_calls_known_skip
.long 0x04000000
.quad 0
.quad 0
.quad _calls_escape
.long Lescape_end-_calls_escape
.long 0x04000000
.quad 0
.quad 0
.quad _calls_sink
.long Lsink_end-_calls_sink
.long 0x02000000
.quad 0
.quad 0
.subsections_via_symbols
