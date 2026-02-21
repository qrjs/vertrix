    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src:
    .float -1.0, -4.0, -0.25, -16.0

vdata_start:
dst:
    .float 0.0, 0.0, 0.0, 0.0
vdata_end:

vref_start:
expected:
    // sqrt of negative numbers should produce NaN (0x7fc00000 = canonical NaN)
    .word 0x7fc00000, 0x7fc00000, 0x7fc00000, 0x7fc00000
vref_end:

    .section .text
    .global main
main:
    la      a0, src
    la      a1, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)

    vfsqrt.v v2, v1

    vse32.v v2, (a1)

    ret
