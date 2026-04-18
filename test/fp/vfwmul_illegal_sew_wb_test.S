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
    // The illegal instruction must trap before the destination register is
    // modified, so the sentinel values remain intact.
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

    // Set SEW=8 (valid for integer, but illegal for FP widening)
    vsetvli t0, t0, e8, m1, ta, ma

    // This must be reported as an illegal instruction by the coprocessor path.
    vfwmul.vv v4, v1, v2

    // If execution reaches here, the illegal instruction path failed.
    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vse32.v v4, (a0)

    ret

    .global exception_handler
exception_handler:
    sw      zero, 0(zero)
1:
    j       1b
