    .text
    .attribute 4, 16

    .globl vref_start
    .set vref_start, expected
    .globl vref_end
    .set vref_end, expected + 4
    .globl vdata_start
    .set vdata_start, result
    .globl vdata_end
    .set vdata_end, result + 4

    .hidden main
    .globl main
    .p2align 2
    .type main,@function
main:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    vsetivli a0, 1, e32, m1, ta, mu

.Lmain_zero:
    auipc   a1, %pcrel_hi(f_zero_val)
    addi    a1, a1, %pcrel_lo(.Lmain_zero)
    vle32.v v8, (a1)

.Lmain_srcb:
    auipc   a1, %pcrel_hi(src_b_bits)
    addi    a1, a1, %pcrel_lo(.Lmain_srcb)
    vle32.v v9, (a1)

.Lmain_srca:
    auipc   a2, %pcrel_hi(src_a_bits)
    addi    a2, a2, %pcrel_lo(.Lmain_srca)
    vle32.v v10, (a2)
    vsetvli zero, a0, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    addi    a0, a1, 4
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a0)
    addi    a0, a2, 4
    vle32.v v10, (a0)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    addi    a0, a1, 8
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a0)
    addi    a0, a2, 8
    vle32.v v10, (a0)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    addi    a0, a1, 12
    vsetvli zero, zero, e32, m1, ta, mu
    vle32.v v9, (a0)
    addi    a0, a2, 12
    vle32.v v10, (a0)
    vsetvli zero, zero, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

.Lmain_store:
    auipc   a0, %pcrel_hi(result)
    addi    a0, a0, %pcrel_lo(.Lmain_store)
    vse32.v v8, (a0)
    addi    a1, a0, 4
    call    spill_cache
    li      a0, 0
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.Lfunc_end0:
    .size main, .Lfunc_end0-main

    .hidden result
    .type result,@object
    .section .sbss,"aw",@nobits
    .globl result
    .p2align 2
result:
    .zero 4
    .size result, 4

    .hidden expected
    .type expected,@object
    .section .rodata,"a",@progbits
    .globl expected
    .p2align 2
expected:
    .word 0x3ecc577b
    .size expected, 4

    .type f_zero_val,@object
    .p2align 2
f_zero_val:
    .word 0x00000000
    .size f_zero_val, 4

    .type src_b_bits,@object
    .p2align 4
src_b_bits:
    .word 0xbf20eb63
    .word 0xbdb1c556
    .word 0xbf0d61c8
    .word 0x3ea7597b
    .size src_b_bits, 16

    .type src_a_bits,@object
    .p2align 4
src_a_bits:
    .word 0xbed93271
    .word 0xbed93271
    .word 0xbed93271
    .word 0xbed93271
    .size src_a_bits, 16
