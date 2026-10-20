/* Maintainer-owned scalar compiler-output probes. Inspect only; never execute.
 * Independent expectations concern emitted opcode semantics, not AIRS verdicts:
 * count-leading-zero results are bounded by operand width; trailing-zero may
 * lower to bit reversal plus leading-zero count; division is a separate family.
 * All examples use volatile argument/result registers and no source-level calls.
 */
__attribute__((noinline)) unsigned airs_clz64(unsigned long long value) {
    return __builtin_clzll(value);
}
__attribute__((noinline)) unsigned airs_clz32(unsigned value) {
    return __builtin_clz(value);
}
__attribute__((noinline)) unsigned airs_ctz64(unsigned long long value) {
    return __builtin_ctzll(value);
}
__attribute__((noinline)) unsigned long long airs_udiv64(unsigned long long a, unsigned long long b) {
    return a / b;
}
