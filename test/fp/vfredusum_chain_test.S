    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

chunk0:
    .float 1.0, 2.0, 3.0, 4.0
chunk1:
    .float 5.0, 6.0, 7.0, 8.0
acc_init:
    .float 10.0

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    # (1+2+3+4) + (5+6+7+8) + 10 = 46
    .float 46.0
vref_end:

    .section .text
    .global main
main:
    la      a0, chunk0
    la      a1, chunk1
    la      a2, acc_init
    la      a3, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vle32.v v1, (a0)

    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vle32.v v2, (a2)

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vfredusum.vs v2, v1, v2

    vle32.v v1, (a1)
    vfredusum.vs v2, v1, v2

    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vse32.v v2, (a3)

    ret
