    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src_a:
    .half 0x3C00, 0x4000, 0x4200, 0x4400

src_b:
    .half 0x4900, 0x4D00, 0x4F80, 0x5100

vdata_start:
dst:
    .half 0x0000, 0x0000, 0x0000, 0x0000
vdata_end:

vref_start:
expected:
    .half 0x4980, 0x4D80, 0x5020, 0x5180
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, dst

    li      t0, 4
    vsetvli t0, t0, e16, m1, ta, ma

    vle16.v v1, (a0)
    vle16.v v2, (a1)

    vfadd.vv v3, v1, v2

    vse16.v v3, (a2)

    ret
