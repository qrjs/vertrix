    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src:
    .half 0x3C00, 0x4000, 0x4200, 0x4400   // 1.0, 2.0, 3.0, 4.0

scalar_init:
    .float 10.0

vdata_start:
dst:
    .word 0
vdata_end:

vref_start:
expected:
    .word 0x41A00000    // 10.0 + (1.0 + 2.0 + 3.0 + 4.0) = 20.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src
    la      a1, scalar_init
    la      a2, dst

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, ma
    vle32.v v2, (a1)

    li      t0, 4
    vsetvli t0, t0, e16, m1, ta, ma
    vle16.v v1, (a0)

    vfwredusum.vs v4, v1, v2

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, ma
    vse32.v v4, (a2)

    ret
