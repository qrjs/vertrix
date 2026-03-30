    .section .rodata
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

vref_start:
expected:
    .word 0x3ecc577b
vref_end:

    .section .bss
    .balign 4
vdata_start:
dst:
    .skip 4
vdata_end:

    .section .text
    .global main
main:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    fence   rw, rw

    la      a0, dst
    la      a1, src_a
    la      a2, src_b
    li      a3, 4

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, mu
    la      t1, zero_acc
    vle32.v v8, (t1)

.Ldot_loop:
    beqz    a3, .Ldot_done
    vle32.v v9, (a1)
    vle32.v v10, (a2)
    vsetvli zero, t0, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10
    addi    a1, a1, 4
    addi    a2, a2, 4
    addi    a3, a3, -1
    vsetvli zero, zero, e32, m1, ta, mu
    j       .Ldot_loop

.Ldot_done:
    vse32.v v8, (a0)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
