    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

val_a:
    .float 3.0
val_b:
    .float 5.0

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    .float 8.0
vref_end:

    .section .text
    .global main
main:
    la      a0, val_a
    la      a1, val_b
    la      a2, dst

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)
    vle32.v v2, (a1)

    vfadd.vv v3, v1, v2

    vse32.v v3, (a2)

    ret
