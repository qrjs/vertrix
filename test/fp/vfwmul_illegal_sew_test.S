    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

// Sentinel pattern in destination
vdata_start:
dst:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF
vdata_end:

vref_start:
expected:
    // SEW=8 is illegal for FP widening operations (no FP8 format).
    // The decoder flags this as an illegal instruction (vsew_o = VSEW_INVALID),
    // so the widening FP multiply is never dispatched to the vector pipeline.
    // v4 retains its original sentinel values.
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF
vref_end:

    .section .text
    .global main
main:
    // Load sentinel into v4 so we can detect if it gets modified
    la      a0, dst
    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vle32.v v4, (a0)

    // Set SEW=8 (valid for integer, but illegal for FP)
    vsetvli t0, t0, e8, m1, ta, ma

    // This widening FP multiply with SEW=8 is illegal (no FP8 format).
    // Vicuna does not trap for this case; the instruction executes with
    // undefined format selection and produces garbage in the lower elements.
    vfwmul.vv v4, v1, v2

    // Store v4 to capture the (garbage) result
    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vse32.v v4, (a0)

    ret
