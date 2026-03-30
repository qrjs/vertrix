// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/**
 * MNIST FP32 negative test: ReLU layers skipped
 * Without ReLU, negative values propagate through FC layers.
 * This test verifies that FC1 output contains negative values,
 * proving that removing ReLU has an observable behavioral effect.
 * With ReLU, FC1 outputs are all non-negative (>= 0).
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
// Expected: 1 = FC1 output has negative values (proves ReLU absence matters)
const int32_t expected[1] __attribute__((aligned(4))) = {1};

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
static float flatten_buf[FC1_IN] NOINIT;

int main(void) {
    // Conv1 + Pool1 (NO ReLU)
    conv3x3_fp32(test_sample_0, INPUT_H, INPUT_W, INPUT_C,
                 conv1_weight, CONV1_OUT_C, conv1_out);
    // relu_fp32_inplace SKIPPED
    maxpool2x2_fp32(conv1_out, 28, 28, CONV1_OUT_C, pool1_out);

    // Conv2 + Pool2 (NO ReLU)
    conv3x3_fp32(pool1_out, POOL1_OUT_H, POOL1_OUT_W, CONV1_OUT_C,
                 conv2_weight, CONV2_OUT_C, conv2_out);
    asm volatile("fence" ::: "memory");
    // relu_fp32_inplace SKIPPED
    maxpool2x2_fp32(conv2_out, 14, 14, CONV2_OUT_C, pool2_out);
    asm volatile("fence" ::: "memory");

    // Flatten + FC1 (NO ReLU)
    hwc_to_chw_fp32(pool2_out, 7, 7, CONV2_OUT_C, flatten_buf);
    asm volatile("fence" ::: "memory");
    fc_fp32(flatten_buf, FC1_IN, fc1_weight, FC1_OUT, fc1_out);
    asm volatile("fence" ::: "memory");
    // relu_fp32_inplace SKIPPED

    int has_negative = 0;
    for (int i = 0; i < FC1_OUT; ++i) {
        if (fc1_out[i] < 0.0f) {
            has_negative = 1;
            break;
        }
    }

    result[0] = has_negative;
    spill_cache((uint32_t *)result, (uint32_t *)(result + 1));

    return 0;
}
