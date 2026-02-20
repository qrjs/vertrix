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

vdata_start:
dst:
    .float 0.0, 0.0, 0.0, 0.0
vdata_end:

vref_start:
expected:
    .float -9.0, -18.0, -27.0, -36.0
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

    vfsub.vv v3, v1, v2

    vse32.v v3, (a2)

    ret
