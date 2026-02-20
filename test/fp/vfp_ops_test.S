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
dst_add:
    .float 0.0, 0.0, 0.0, 0.0
dst_sub:
    .float 0.0, 0.0, 0.0, 0.0
dst_mul:
    .float 0.0, 0.0, 0.0, 0.0
vdata_end:

vref_start:
exp_add:
    .float 11.0, 22.0, 33.0, 44.0
exp_sub:
    .float -9.0, -18.0, -27.0, -36.0
exp_mul:
    .float 10.0, 40.0, 90.0, 160.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, dst_add
    la      a3, dst_sub
    la      a4, dst_mul

    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    vle32.v v1, (a0)
    vle32.v v2, (a1)

    vfadd.vv v3, v1, v2
    vse32.v v3, (a2)

    vfsub.vv v4, v1, v2
    vse32.v v4, (a3)

    vfmul.vv v5, v1, v2
    vse32.v v5, (a4)

    ret
