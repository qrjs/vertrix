    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src_a:
    .word 0xbed93271, 0xbed93271, 0xbed93271, 0xbed93271

src_b:
    .word 0xbf20eb63, 0xbdb1c556, 0xbf0d61c8, 0x3ea7597b

zero_acc:
    .float 0.0

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    .word 0x3ecc577b
vref_end:

    .section .text
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, zero_acc
    la      a3, dst

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, mu

    vle32.v v3, (a2)

    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v2, v1

    addi    a0, a0, 4
    addi    a1, a1, 4
    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v2, v1

    addi    a0, a0, 4
    addi    a1, a1, 4
    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v2, v1

    addi    a0, a0, 4
    addi    a1, a1, 4
    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vfmacc.vv v3, v2, v1

    vse32.v v3, (a3)

    la      a0, dst
    la      a1, vdata_end
    # Tail-call spill_cache so it returns to the original caller instead of
    # looping on main's local return address.
    j       spill_cache
