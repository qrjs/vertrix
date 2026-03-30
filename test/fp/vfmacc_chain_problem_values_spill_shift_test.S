    .section .rodata
    .balign 4
vref_start:
expected:
    .word 0x3ecc577b
vref_end:

f_zero_val:
    .float 0.0

    .balign 16
src_b:
    .word 0xbf20eb63, 0xbdb1c556, 0xbf0d61c8, 0x3ea7597b

src_a:
    .word 0xbed93271, 0xbed93271, 0xbed93271, 0xbed93271

    .section .bss
    .balign 4
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
.Lcall_spill_cache:
    auipc   ra, %pcrel_hi(spill_cache)
    jalr    ra, %pcrel_lo(.Lcall_spill_cache)(ra)
    li      a0, 0

    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

spill_cache:
    lui     t0, 0x10
    add     a0, a0, t0
    add     a1, a1, t0
    mv      t1, a0

.spill_cache_0:
    lw      zero, 0(t1)
    lw      zero, 4(t1)
    lw      zero, 8(t1)
    lw      zero, 12(t1)
    addi    t1, t1, 16
    bge     a1, t1, .spill_cache_0
    add     a0, a0, t0
    add     a1, a1, t0

.spill_cache_1:
    lw      zero, 0(a0)
    lw      zero, 4(a0)
    lw      zero, 8(a0)
    lw      zero, 12(a0)
    addi    a0, a0, 16
    bge     a1, a0, .spill_cache_1
    ret
