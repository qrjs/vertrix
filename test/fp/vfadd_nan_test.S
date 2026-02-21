    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src1:
    .word 0x7FC00000    // NaN (quiet)
    .float 2.0
    .float 3.0
    .word 0x7FC00000    // NaN (quiet)
src2:
    .float 1.0
    .word 0x7FC00000    // NaN (quiet)
    .float 30.0
    .float 4.0

vdata_start:
dst:
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    // NaN + x = NaN, x + NaN = NaN, normal + normal = normal
    .word 0x7FC00000    // NaN + 1.0 = NaN
    .word 0x7FC00000    // 2.0 + NaN = NaN
    .float 33.0         // 3.0 + 30.0 = 33.0
    .word 0x7FC00000    // NaN + 4.0 = NaN
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
