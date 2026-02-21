    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

// FP16 source operands
src_a:
    .half 0x3E00, 0x4000, 0x4200, 0x3800   // 1.5, 2.0, 3.0, 0.5

src_b:
    .half 0x4000, 0x4200, 0x4400, 0x4900   // 2.0, 3.0, 4.0, 10.0

// FP32 destination (widened result)
vdata_start:
dst:
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    .word 0x40400000    // 1.5 * 2.0  = 3.0
    .word 0x40C00000    // 2.0 * 3.0  = 6.0
    .word 0x41400000    // 3.0 * 4.0  = 12.0
    .word 0x40A00000    // 0.5 * 10.0 = 5.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, dst

    // Set VL=4, SEW=16 for FP16 sources
    li      t0, 4
    vsetvli t0, t0, e16, m1, ta, ma

    vle16.v v1, (a0)
    vle16.v v2, (a1)

    // Widening multiply: FP16 * FP16 -> FP32
    // vd (e32, EMUL=2) = vs2 (e16) * vs1 (e16)
    vfwmul.vv v4, v1, v2

    // Switch to e32 to store the FP32 results
    vsetvli t0, t0, e32, m1, ta, ma
    vse32.v v4, (a2)

    ret
