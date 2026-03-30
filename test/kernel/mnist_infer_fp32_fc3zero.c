// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/**
 * MNIST FP32 negative test: FC3 weights zeroed
 * All output logits should be zero, so argmax returns 0 (not 7).
 * Verifies that the FC3 layer is necessary for correct classification.
 */

#include <stdint.h>
#include "mnist_weights_fp32.h"
#define MNIST_FP32_USE_VFDOT 1
#include "mnist_fp32_scalar.h"
#include "mnist_test_sample_fp32.h"

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

volatile int32_t result[1] __attribute__((aligned(4))) = {0};
const int32_t expected[1] __attribute__((aligned(4))) = {0};  // NOT 7

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

#define NOINIT __attribute__((section(".noinit"), aligned(64)))
static float conv1_out[28 * 28 * CONV1_OUT_C] NOINIT;
static float pool1_out[14 * 14 * CONV1_OUT_C] NOINIT;
static float conv2_out[14 * 14 * CONV2_OUT_C] NOINIT;
static float pool2_out[7 * 7 * CONV2_OUT_C] NOINIT;
static float fc1_out[FC1_OUT] NOINIT;
static float fc2_out[FC2_OUT] NOINIT;
static float flatten_buf[FC1_IN] NOINIT;
static float output_logits[FC3_OUT] NOINIT;

int main(void) {
    // Conv1 + ReLU + Pool1
    conv3x3_fp32(test_sample_0, INPUT_H, INPUT_W, INPUT_C,
                 conv1_weight, CONV1_OUT_C, conv1_out);
    relu_fp32_inplace(conv1_out, 28 * 28 * CONV1_OUT_C);
    maxpool2x2_fp32(conv1_out, 28, 28, CONV1_OUT_C, pool1_out);

    // Conv2 + ReLU + Pool2
    conv3x3_fp32(pool1_out, POOL1_OUT_H, POOL1_OUT_W, CONV1_OUT_C,
                 conv2_weight, CONV2_OUT_C, conv2_out);
    asm volatile("fence" ::: "memory");
    relu_fp32_inplace(conv2_out, 14 * 14 * CONV2_OUT_C);
    asm volatile("fence" ::: "memory");
    maxpool2x2_fp32(conv2_out, 14, 14, CONV2_OUT_C, pool2_out);
    asm volatile("fence" ::: "memory");

    // Flatten + FC1 + ReLU
    hwc_to_chw_fp32(pool2_out, 7, 7, CONV2_OUT_C, flatten_buf);
    asm volatile("fence" ::: "memory");
    fc_fp32(flatten_buf, FC1_IN, fc1_weight, FC1_OUT, fc1_out);
    asm volatile("fence" ::: "memory");
    relu_fp32_inplace(fc1_out, FC1_OUT);
    asm volatile("fence" ::: "memory");

    // FC2 + ReLU
    fc_fp32(fc1_out, FC1_OUT, fc2_weight, FC2_OUT, fc2_out);
    relu_fp32_inplace(fc2_out, FC2_OUT);

    for (int i = 0; i < FC3_OUT; ++i) {
        output_logits[i] = 0.0f;
    }

    int pred = argmax_fp32(output_logits, FC3_OUT);

    result[0] = pred;  // Should be 0, not 7
    spill_cache((uint32_t *)result, (uint32_t *)(result + 1));

    return 0;
}
