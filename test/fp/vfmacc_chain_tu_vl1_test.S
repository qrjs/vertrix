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
    vsetvli t0, t0, e32, m1, ta, mu

    vsetvli zero, t0, e32, m1, ta, mu
    vle32.v v8, (a2)

    vsetvli zero, t0, e32, m1, ta, mu
    vle32.v v9, (a0)
    vle32.v v10, (a1)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v10, v9

    addi    a0, a0, 4
    addi    a1, a1, 4
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a0)
    vle32.v v10, (a1)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v10, v9

    addi    a0, a0, 4
    addi    a1, a1, 4
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a0)
    vle32.v v10, (a1)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v10, v9

    addi    a0, a0, 4
    addi    a1, a1, 4
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a0)
    vle32.v v10, (a1)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v10, v9

    vse32.v v8, (a3)

    ret
