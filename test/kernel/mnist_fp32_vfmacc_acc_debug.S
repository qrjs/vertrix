    .section .rodata
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

acc_init:
    .word 0x3e88873c

src_a:
    .word 0xbed93271

src_b:
    .word 0xbdb1c556

vref_start:
expected:
    .word 0x3e9b61a6
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
    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, mu

    la      a0, acc_init
    vle32.v v8, (a0)
    la      a0, src_a
    vle32.v v9, (a0)
    la      a0, src_b
    vle32.v v10, (a0)

    vsetvli zero, t0, e32, m1, tu, mu
    vfmacc.vv v8, v9, v10

    la      a0, dst
    vse32.v v8, (a0)
    ret
