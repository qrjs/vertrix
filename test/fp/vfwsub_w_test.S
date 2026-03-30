    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src_a:
    .half 0x3E00, 0x4000, 0x4200, 0x3800   // 1.5, 2.0, 3.0, 0.5

src_b:
    .word 0x40000000, 0x40400000, 0x40800000, 0x41200000   // 2.0, 3.0, 4.0, 10.0

vdata_start:
dst:
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    .word 0x3F000000    // 2.0 - 1.5  = 0.5
    .word 0x3F800000    // 3.0 - 2.0  = 1.0
    .word 0x3F800000    // 4.0 - 3.0  = 1.0
    .word 0x41180000    // 10.0 - 0.5 = 9.5
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, dst

    li      t0, 4
    vsetvli t0, t0, e16, m1, ta, ma

    vle16.v v1, (a0)
    vle32.v v2, (a1)

    vfwsub.wv v4, v2, v1

    vsetvli t0, t0, e32, m1, ta, ma
    vse32.v v4, (a2)

    ret
