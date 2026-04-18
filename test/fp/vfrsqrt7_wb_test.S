    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src:
    .word 0x3F800000    // 1.0
    .word 0x40800000    // 4.0
    .word 0x3E800000    // 0.25
    .word 0x00000000    // +0.0

vdata_start:
dst:
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    .word 0x3F800000    // rsqrt(1.0)  = 1.0
    .word 0x3F000000    // rsqrt(4.0)  = 0.5
    .word 0x40000000    // rsqrt(0.25) = 2.0
    .word 0x7F800000    // rsqrt(+0.0) = +Inf
vref_end:

    .section .text
    .global main
main:
    la      a0, src
    la      a1, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)

    vfrsqrt7.v v2, v1

    vse32.v v2, (a1)

    ret
