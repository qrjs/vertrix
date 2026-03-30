    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src_f:
    .float 1.25, 1.75, -1.25, -1.75

src_i:
    .word 16777217, 16777219, 33554433, 33554435

vdata_start:
dst:
    .word 0, 0, 0, 0
    .word 0, 0, 0, 0
    .word 0, 0, 0, 0
    .word 0, 0, 0, 0
vdata_end:

vref_start:
expected:
    .word 1, 1, -2, -2
    .word 2, 2, -1, -1
    .word 0x4b800000, 0x4b800001, 0x4c000000, 0x4c000000
    .word 0x4b800001, 0x4b800002, 0x4c000001, 0x4c000001
vref_end:

    .section .text
    .global main
main:
    la      a0, src_f
    la      a1, src_i
    la      a2, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)
    vle32.v v2, (a1)

    li      t1, 2                  # RDN
    csrw    frm, t1
    vfcvt.x.f.v v3, v1
    vse32.v v3, (a2)

    addi    a2, a2, 16
    li      t1, 3                  # RUP
    csrw    frm, t1
    vfcvt.x.f.v v4, v1
    vse32.v v4, (a2)

    addi    a2, a2, 16
    li      t1, 2                  # RDN
    csrw    frm, t1
    vfcvt.f.x.v v5, v2
    vse32.v v5, (a2)

    addi    a2, a2, 16
    li      t1, 3                  # RUP
    csrw    frm, t1
    vfcvt.f.x.v v6, v2
    vse32.v v6, (a2)

    li      t1, 0
    csrw    frm, t1

    ret
