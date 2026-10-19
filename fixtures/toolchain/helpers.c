/* Owned code for compiler-output observation. No input library is executed. */
__attribute__((noinline)) void airs_sink(void) {
    __asm__ volatile("nop");
}

/* Different optimization levels may emit different instruction/control-flow
 * shapes. The starter should honestly leave unsupported shapes unresolved. */
__attribute__((noinline)) int airs_branch(int value) {
    if (value > 7) {
        return value + 3;
    }
    return value * 2;
}
