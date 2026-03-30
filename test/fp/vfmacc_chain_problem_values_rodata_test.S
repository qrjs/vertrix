    .section .rodata
    .balign 16
src_a:
    .word 0xbed93271, 0xbed93271, 0xbed93271, 0xbed93271

src_b:
    .word 0xbf20eb63, 0xbdb1c556, 0xbf0d61c8, 0x3ea7597b

zero_acc:
    .float 0.0

vref_start:
expected:
    .word 0x3ecc577b
vref_end:

    .section .bss
    .balign 4
    .global vdata_start
    .global vdata_end
vdata_start:
dst:
    .skip 4
vdata_end:

    .section .text
    .global vref_start
    .global vref_end
    .global main
main:
    la      a0, src_a
    la      a1, src_b
    la      a2, zero_acc
    la      a3, dst

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, mu

    vle32.v v8, (a2)
    vle32.v v9, (a1)
    vle32.v v10, (a0)
    vsetvli zero, t0, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    addi    a1, a1, 4
    addi    a0, a0, 4
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a1)
    vle32.v v10, (a0)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    addi    a1, a1, 4
    addi    a0, a0, 4
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a1)
    vle32.v v10, (a0)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    addi    a1, a1, 4
    addi    a0, a0, 4
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a1)
    vle32.v v10, (a0)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    vse32.v v8, (a3)
    ret
