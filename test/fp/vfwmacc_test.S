    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

// FP16 source operands
src_a:
    .half 0x3C00, 0x4000, 0x4200, 0x4400   // 1.0, 2.0, 3.0, 4.0

src_b:
    .half 0x4900, 0x4D00, 0x4F80, 0x5100   // 10.0, 20.0, 30.0, 40.0

// FP32 initial accumulator
acc_init:
    .word 0x3F800000    // 1.0
    .word 0x40000000    // 2.0
    .word 0x40400000    // 3.0
    .word 0x40800000    // 4.0

// FP32 destination (widened macc result)
vdata_start:
dst:
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    .word 0x41300000    // 1.0 + 1.0*10.0  = 11.0
    .word 0x42280000    // 2.0 + 2.0*20.0  = 42.0
    .word 0x42BA0000    // 3.0 + 3.0*30.0  = 93.0
    .word 0x43240000    // 4.0 + 4.0*40.0  = 164.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, acc_init
    la      a3, dst

    // Load FP32 accumulator into v4
    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vle32.v v4, (a2)

    // Switch to e16 for widening multiply-accumulate
    vsetvli t0, t0, e16, m1, ta, ma
    vle16.v v1, (a0)
    vle16.v v2, (a1)

    // Widening macc: v4 (FP32) += v1 (FP16) * v2 (FP16)
    vfwmacc.vv v4, v1, v2

    // Switch to e32 to store FP32 results
    vsetvli t0, t0, e32, m1, ta, ma
    vse32.v v4, (a3)

    ret
