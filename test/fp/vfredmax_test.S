    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src:
    .float 6.5, -2.25, 9.0, 1.5

scalar_init:
    .float 3.25

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    .float 9.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src
    la      a1, scalar_init
    la      a2, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vle32.v v1, (a0)

    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vle32.v v2, (a1)

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vfredmax.vs v3, v1, v2

    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vse32.v v3, (a2)

    ret
