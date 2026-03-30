# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


    .text
    .global main
main:
    li              t0, 4
    vsetvli         t0, t0, e8,m1,tu,mu

    la              a1, mask_data
    vle8.v          v0, (a1)

    li              t0, 4
    vsetvli         t0, t0, e32,m1,tu,mu

    la              a0, vdata_start
    li              t1, 40
    vmv.v.x         v4, t1

    vle32.v         v2, (a0)
    vredmin.vs      v4, v2, v4, v0.t
    vse32.v         v4, (a0)

    la              a0, vdata_start
    la              a1, vdata_end
    j               spill_cache


    .data
    .align 2
mask_data:
    .byte           0x0a
    .byte           0x00
    .byte           0x00
    .byte           0x00

    .align 4
    .global vdata_start
    .global vdata_end
vdata_start:
    .word           5
    .word           50
    .word           3
    .word           70
vdata_end:

    .align 4
    .global vref_start
    .global vref_end
vref_start:
    .word           40
    .word           40
    .word           40
    .word           40
vref_end:
