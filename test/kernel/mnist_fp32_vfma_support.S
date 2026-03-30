// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

    .section .text
    .balign 4
    .global vfdot_vl1_store
    .type vfdot_vl1_store, @function

// Soft-float ABI helper:
// a0=dst pointer, a1=lhs pointer, a2=rhs pointer, a3=count
vfdot_vl1_store:
    addi    sp, sp, -16
    sw      ra, 12(sp)

    li      t0, 1
    vsetvli t0, t0, e32, m1, ta, mu
    la      t1, .Lzero_acc
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
    vsetvli zero, t0, e32, m1, ta, mu
    j       .Ldot_loop

.Ldot_done:
    vse32.v v8, (a0)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

    .size vfdot_vl1_store, .-vfdot_vl1_store

    .section .rodata
    .balign 4
.Lzero_acc:
    .float 0.0
