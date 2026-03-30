// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>
#include <riscv_vector.h>

#include "../../sw/lib/rvv_compat.h"
#include "mnist_test_sample_fp32.h"
#include "mnist_weights_fp32.h"

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

volatile uint32_t result[4] __attribute__((aligned(4))) = {
    0, 0, 0, 0,
};
const uint32_t expected[4] __attribute__((aligned(4))) = {
    0x3e88873cu,
    0x3e9b61a6u,
    0x3f09aab2u,
    0x3ecc577bu,
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 16\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 16\n");

static const float f_zero_val __attribute__((aligned(4))) = 0.0f;

static inline uint32_t vbits(vfloat32m1_t v, size_t vl1) {
    volatile float tmp[1] __attribute__((aligned(4)));
    __riscv_vse32_v_f32m1((float *)tmp, v, vl1);
    return (uint32_t)__riscv_vmv_x_s_i32m1_i32(
        __riscv_vle32_v_i32m1((const int32_t *)tmp, vl1));
}

int main(void) {
    size_t vl1 = __riscv_vsetvl_e32m1(1);
    vfloat32m1_t acc = __riscv_vle32_v_f32m1(&f_zero_val, vl1);

    vfloat32m1_t in0 = __riscv_vle32_v_f32m1(&test_sample_0[0], vl1);
    vfloat32m1_t w0 = __riscv_vle32_v_f32m1(&conv1_weight[4], vl1);
    acc = __riscv_vfmacc_vv_f32m1(acc, w0, in0, vl1);
    result[0] = vbits(acc, vl1);

    vfloat32m1_t in1 = __riscv_vle32_v_f32m1(&test_sample_0[1], vl1);
    vfloat32m1_t w1 = __riscv_vle32_v_f32m1(&conv1_weight[5], vl1);
    acc = __riscv_vfmacc_vv_f32m1(acc, w1, in1, vl1);
    result[1] = vbits(acc, vl1);

    vfloat32m1_t in2 = __riscv_vle32_v_f32m1(&test_sample_0[28], vl1);
    vfloat32m1_t w2 = __riscv_vle32_v_f32m1(&conv1_weight[7], vl1);
    acc = __riscv_vfmacc_vv_f32m1(acc, w2, in2, vl1);
    result[2] = vbits(acc, vl1);

    vfloat32m1_t in3 = __riscv_vle32_v_f32m1(&test_sample_0[29], vl1);
    vfloat32m1_t w3 = __riscv_vle32_v_f32m1(&conv1_weight[8], vl1);
    acc = __riscv_vfmacc_vv_f32m1(acc, w3, in3, vl1);
    result[3] = vbits(acc, vl1);

    spill_cache((uint32_t *)result, (uint32_t *)(result + 4));
    return 0;
}
