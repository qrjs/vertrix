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

dst_init_a:
    .float 100.0, 200.0, 300.0, 400.0

dst_init_b:
    .float -1.0, -2.0, -3.0, -4.0

mask_a:
    .byte 0x05, 0x00, 0x00, 0x00

mask_b:
    .byte 0x0A, 0x00, 0x00, 0x00

vdata_start:
dst:
    .float 0.0, 0.0, 0.0, 0.0
    .float 0.0, 0.0, 0.0, 0.0
vdata_end:

vref_start:
expected:
    .float 11.0, 200.0, 33.0, 400.0
    .float -1.0, 22.0, -3.0, 44.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, dst_init_a
    la      a3, dst_init_b
    la      a4, mask_a
    la      a5, mask_b
    la      a6, dst

    li      t0, 4
    vsetvli t0, t0, e32, m1, tu, mu

    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vle32.v v3, (a2)

    li      t1, 4
    vsetvli t1, t1, e8, m1, tu, mu
    vle8.v  v0, (a4)

    li      t0, 4
    vsetvli t0, t0, e32, m1, tu, mu
    vfadd.vv v3, v1, v2, v0.t

    li      t1, 4
    vsetvli t1, t1, e8, m1, tu, mu
    vle8.v  v0, (a5)

    li      t0, 4
    vsetvli t0, t0, e32, m1, tu, mu
    vle32.v v4, (a3)
    vfadd.vv v4, v1, v2, v0.t

    vse32.v v3, (a6)
    addi    a6, a6, 16
    vse32.v v4, (a6)

    ret
