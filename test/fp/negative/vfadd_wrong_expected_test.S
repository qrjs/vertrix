    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src1:
    .float 1.0, 2.0, 3.0, 4.0
src2:
    .float 10.0, 20.0, 30.0, 40.0

vdata_start:
dst:
    .float 0.0, 0.0, 0.0, 0.0
vdata_end:

vref_start:
expected:
    // Intentionally WRONG expected values (correct would be 11, 22, 33, 44)
    .float 99.0, 99.0, 99.0, 99.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src1
    la      a1, src2
    la      a2, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)
    vle32.v v2, (a1)

    vfadd.vv v3, v1, v2

    vse32.v v3, (a2)

    ret
