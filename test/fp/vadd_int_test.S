    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src_a:
    .word 1, 2, 3, 4

src_b:
    .word 10, 20, 30, 40

vdata_start:
dst:
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    .word 11, 22, 33, 44
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)
    vle32.v v2, (a1)

    vadd.vv v3, v1, v2

    vse32.v v3, (a2)

    ret
