// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>
#include <riscv_vector.h>

#include "mnist_test_sample_fp32.h"
#include "mnist_weights_fp32.h"

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

volatile uint32_t result[8] __attribute__((aligned(4))) = {
    0, 0, 0, 0, 0, 0, 0, 0,
};
const uint32_t expected[8] __attribute__((aligned(4))) = {
    0xbed93271u, 0xbed93271u, 0xbed93271u, 0xbed93271u,
    0xbf20eb63u, 0xbdb1c556u, 0xbf0d61c8u, 0x3ea7597bu,
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 32\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 32\n");

int main(void) {
    const int sample_idx[4] = {0, 1, 28, 29};
    const int weight_idx[4] = {4, 5, 7, 8};
    size_t vl1 = __riscv_vsetvl_e32m1(1);

    for (int i = 0; i < 4; ++i) {
        vint32m1_t bits = __riscv_vle32_v_i32m1(
            (const int32_t *)&test_sample_0[sample_idx[i]], vl1);
        result[i] = (uint32_t)__riscv_vmv_x_s_i32m1_i32(bits);
    }

    for (int i = 0; i < 4; ++i) {
        vint32m1_t bits = __riscv_vle32_v_i32m1(
            (const int32_t *)&conv1_weight[weight_idx[i]], vl1);
        result[4 + i] = (uint32_t)__riscv_vmv_x_s_i32m1_i32(bits);
    }

    spill_cache((uint32_t *)result, (uint32_t *)(result + 8));
    return 0;
}
