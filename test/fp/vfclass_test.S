    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src:
    .float 1.0
    .float -2.0
    .word  0x00000000
    .word  0x7f800000

vdata_start:
dst:
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    .word 0x00000040
    .word 0x00000002
    .word 0x00000010
    .word 0x00000080
vref_end:

    .section .text
    .global main
main:
    la      a0, src
    la      a1, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)

    vfclass.v v2, v1

    vse32.v v2, (a1)

    ret
