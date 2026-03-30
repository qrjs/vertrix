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

volatile uint32_t result[4] __attribute__((aligned(4))) = {
    0x3ecc577bu,
    0x00000000u,
    0x00000000u,
    0x00000000u,
};
const uint32_t expected[4] __attribute__((aligned(4))) = {
    0x3ecc577bu,
    0x3d648c95u,
    0x3e41aa69u,
    0x3e83ba4bu,
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 16\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 16\n");

static const float f_zero_val __attribute__((aligned(4))) = 0.0f;

#define NOINIT __attribute__((section(".noinit"), aligned(64)))
static float conv1_out[28 * 28 * CONV1_OUT_C] NOINIT;

static void conv3x3_fp32(
    const float *input, int in_h, int in_w, int in_c,
    const float *weight, int out_c,
    float *output
) {
    size_t vl1 = __riscv_vsetvl_e32m1(1);

    for (int oy = 0; oy < in_h; oy++) {
        for (int ox = 0; ox < in_w; ox++) {
            for (int oc = 0; oc < out_c; oc++) {
                vfloat32m1_t v_acc = __riscv_vle32_v_f32m1(&f_zero_val, vl1);

                for (int ky = 0; ky < 3; ky++) {
                    int iy = oy + ky - 1;
                    if (iy < 0 || iy >= in_h) continue;

                    for (int kx = 0; kx < 3; kx++) {
                        int ix = ox + kx - 1;
                        if (ix < 0 || ix >= in_w) continue;

                        for (int ic = 0; ic < in_c; ic++) {
                            int input_idx = (iy * in_w + ix) * in_c + ic;
                            int weight_idx = ((oc * in_c + ic) * 3 + ky) * 3 + kx;
                            vfloat32m1_t v_in = __riscv_vle32_v_f32m1(&input[input_idx], vl1);
                            vfloat32m1_t v_w  = __riscv_vle32_v_f32m1(&weight[weight_idx], vl1);
                            v_acc = __riscv_vfmacc_vv_f32m1(v_acc, v_w, v_in, vl1);
                        }
                    }
                }

                int out_idx = (oy * in_w + ox) * out_c + oc;
                __riscv_vse32_v_f32m1(&output[out_idx], v_acc, vl1);
            }
        }
    }
}

int main(void) {
    conv3x3_fp32(test_sample_0, INPUT_H, INPUT_W, INPUT_C,
                 conv1_weight, CONV1_OUT_C, conv1_out);

    size_t vl1 = __riscv_vsetvl_e32m1(1);
    for (int i = 0; i < 4; ++i) {
        vint32m1_t bits = __riscv_vle32_v_i32m1((const int32_t *)&conv1_out[i], vl1);
        result[i] = (uint32_t)__riscv_vmv_x_s_i32m1_i32(bits);
    }

    spill_cache((uint32_t *)result, (uint32_t *)(result + 4));
    return 0;
}
