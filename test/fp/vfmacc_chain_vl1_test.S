    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src_a:
    .float 1.0, 2.0, 3.0, 4.0

src_b:
    .float 10.0, 20.0, 30.0, 40.0

zero_acc:
    .float 0.0

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    .float 300.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, zero_acc
    la      a3, dst

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v3, (a2)

    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v1, v2

    addi    a0, a0, 4
    addi    a1, a1, 4
    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v1, v2

    addi    a0, a0, 4
    addi    a1, a1, 4
    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v1, v2

    addi    a0, a0, 4
    addi    a1, a1, 4
    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v1, v2

    vse32.v v3, (a3)

    ret
