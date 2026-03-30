// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>
#include <riscv_vector.h>

#include "../../sw/lib/rvv_compat.h"

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

static const uint32_t src_a_bits[4] __attribute__((aligned(16))) = {
    0xbed93271u, 0xbed93271u, 0xbed93271u, 0xbed93271u,
};
static const uint32_t src_b_bits[4] __attribute__((aligned(16))) = {
    0xbf20eb63u, 0xbdb1c556u, 0xbf0d61c8u, 0x3ea7597bu,
};
static const float f_zero_val __attribute__((aligned(4))) = 0.0f;

volatile uint32_t result[1] __attribute__((aligned(4))) = {0};
const uint32_t expected[1] __attribute__((aligned(4))) = {0x3ecc577bu};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

int main(void) {
    size_t vl1 = __riscv_vsetvl_e32m1(1);
    vfloat32m1_t acc = __riscv_vle32_v_f32m1(&f_zero_val, vl1);

    acc = __riscv_vfmacc_vv_f32m1(
        acc,
        __riscv_vle32_v_f32m1((const float *)&src_b_bits[0], vl1),
        __riscv_vle32_v_f32m1((const float *)&src_a_bits[0], vl1),
        vl1);
    acc = __riscv_vfmacc_vv_f32m1(
        acc,
        __riscv_vle32_v_f32m1((const float *)&src_b_bits[1], vl1),
        __riscv_vle32_v_f32m1((const float *)&src_a_bits[1], vl1),
        vl1);
    acc = __riscv_vfmacc_vv_f32m1(
        acc,
        __riscv_vle32_v_f32m1((const float *)&src_b_bits[2], vl1),
        __riscv_vle32_v_f32m1((const float *)&src_a_bits[2], vl1),
        vl1);
    acc = __riscv_vfmacc_vv_f32m1(
        acc,
        __riscv_vle32_v_f32m1((const float *)&src_b_bits[3], vl1),
        __riscv_vle32_v_f32m1((const float *)&src_a_bits[3], vl1),
        vl1);

    __riscv_vse32_v_f32m1((float *)result, acc, vl1);
    spill_cache((uint32_t *)result, (uint32_t *)(result + 1));
    return 0;
}
