    .section .rodata
    .balign 16
src_b:
    .word 0xbf20eb63, 0xbdb1c556, 0xbf0d61c8, 0x3ea7597b

src_a:
    .word 0xbed93271, 0xbed93271, 0xbed93271, 0xbed93271

vref_start:
expected:
    .word 0x3ecc577b
vref_end:

f_zero_val:
    .float 0.0

    .section .bss
    .balign 4
    .skip 8
    .global vdata_start
    .global vdata_end
vdata_start:
result:
    .skip 4
vdata_end:

    .section .text
    .global vref_start
    .global vref_end
    .global main
main:
    addi    sp, sp, -16
    sw      ra, 12(sp)

    vsetivli a0, 1, e32, m1, ta, mu

    la      a1, f_zero_val
    vle32.v v8, (a1)

    la      a1, src_b
    vle32.v v9, (a1)

    la      a2, src_a
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

    la      a0, result
    vse32.v v8, (a0)
    addi    a1, a0, 4
    call    spill_cache

    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
