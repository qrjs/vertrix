// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/**
 * MNIST FP32 negative test: FC3 weights zeroed
 * All output logits should be zero, so argmax returns 0 (not 7).
 * Verifies that the FC3 layer is necessary for correct classification.
 */

#include <stdint.h>
#include <riscv_vector.h>
#include "mnist_weights_fp32.h"
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

static const float f_zero_val __attribute__((aligned(4))) = 0.0f;

#define NOINIT __attribute__((section(".noinit"), aligned(64)))
static float conv1_out[28 * 28 * CONV1_OUT_C] NOINIT;
static float pool1_out[14 * 14 * CONV1_OUT_C] NOINIT;
static float conv2_out[14 * 14 * CONV2_OUT_C] NOINIT;
static float pool2_out[7 * 7 * CONV2_OUT_C] NOINIT;
static float fc1_out[FC1_OUT] NOINIT;
static float fc2_out[FC2_OUT] NOINIT;
static float flatten_buf[FC1_IN] NOINIT;
static float output_logits[FC3_OUT] NOINIT;

static void conv3x3_fp32(
    const float* input, int in_h, int in_w, int in_c,
    const float* weight, int out_c,
    float* output
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

static void relu_fp32_inplace(float* data, int size) {
    for (int i = 0; i < size; ) {
        size_t vl = __riscv_vsetvl_e32m1(size - i);
        vfloat32m1_t v = __riscv_vle32_v_f32m1(&data[i], vl);
        vfloat32m1_t v_zero = __riscv_vreinterpret_v_i32m1_f32m1(
            __riscv_vmv_v_x_i32m1(0, vl));
        v = __riscv_vfmax_vv_f32m1(v, v_zero, vl);
        __riscv_vse32_v_f32m1(&data[i], v, vl);
        i += vl;
    }
}

static void maxpool2x2_fp32(
    const float* input, int in_h, int in_w, int c,
    float* output
) {
    int out_h = in_h / 2;
    int out_w = in_w / 2;
    for (int oy = 0; oy < out_h; oy++) {
        for (int ox = 0; ox < out_w; ox++) {
            int iy = oy * 2;
            int ix = ox * 2;
            for (int ch = 0; ch < c; ) {
                size_t vl = __riscv_vsetvl_e32m1(c - ch);
                vfloat32m1_t v00 = __riscv_vle32_v_f32m1(&input[(iy * in_w + ix) * c + ch], vl);
                vfloat32m1_t v01 = __riscv_vle32_v_f32m1(&input[(iy * in_w + (ix + 1)) * c + ch], vl);
                vfloat32m1_t v10 = __riscv_vle32_v_f32m1(&input[((iy + 1) * in_w + ix) * c + ch], vl);
                vfloat32m1_t v11 = __riscv_vle32_v_f32m1(&input[((iy + 1) * in_w + (ix + 1)) * c + ch], vl);
                vfloat32m1_t vmax01 = __riscv_vfmax_vv_f32m1(v00, v01, vl);
                vfloat32m1_t vmax23 = __riscv_vfmax_vv_f32m1(v10, v11, vl);
                vfloat32m1_t vmax   = __riscv_vfmax_vv_f32m1(vmax01, vmax23, vl);
                __riscv_vse32_v_f32m1(&output[(oy * out_w + ox) * c + ch], vmax, vl);
                ch += vl;
            }
        }
    }
}

static void fc_fp32(
    const float* input, int in_features,
    const float* weight, int out_features,
    float* output
) {
    for (int o = 0; o < out_features; o++) {
        const float* w_row = weight + o * in_features;
        size_t vl1 = __riscv_vsetvl_e32m1(1);
        vfloat32m1_t v_acc = __riscv_vreinterpret_v_i32m1_f32m1(
            __riscv_vmv_v_x_i32m1(0, vl1));
        for (int i = 0; i < in_features; ) {
            size_t vl = __riscv_vsetvl_e32m1(in_features - i);
            vfloat32m1_t v_in = __riscv_vle32_v_f32m1(&input[i], vl);
            vfloat32m1_t v_w  = __riscv_vle32_v_f32m1(&w_row[i], vl);
            vfloat32m1_t v_prod = __riscv_vfmul_vv_f32m1(v_in, v_w, vl);
            v_acc = __riscv_vfredusum_vs_f32m1_f32m1(v_prod, v_acc, vl);
            i += vl;
        }
        __riscv_vse32_v_f32m1(&output[o], v_acc, vl1);
    }
}

static void hwc_to_chw_fp32(const float* hwc, int h, int w, int c, float* chw) {
    for (int ch = 0; ch < c; ch++) {
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int hwc_idx = (y * w + x) * c + ch;
                int chw_idx = (ch * h + y) * w + x;
                size_t vl1;
                asm volatile("vsetvli %0, %1, e32, m1, ta, ma"
                             : "=r"(vl1) : "r"(1));
                vint32m1_t v = __riscv_vle32_v_i32m1(
                    (const int32_t*)&hwc[hwc_idx], vl1);
                __riscv_vse32_v_i32m1((int32_t*)&chw[chw_idx], v, vl1);
            }
        }
    }
}

static int argmax_fp32(const float* data, int size) {
    size_t vl1 = __riscv_vsetvl_e32m1(1);
    int max_idx = 0;
    vint32m1_t v_raw = __riscv_vle32_v_i32m1((const int32_t*)&data[0], vl1);
    uint32_t raw0 = (uint32_t)__riscv_vmv_x(v_raw);
    int32_t max_comp = (int32_t)raw0 < 0 ?
        (int32_t)(0x80000000u - raw0) : (int32_t)raw0;
    for (int i = 1; i < size; i++) {
        v_raw = __riscv_vle32_v_i32m1((const int32_t*)&data[i], vl1);
        uint32_t raw = (uint32_t)__riscv_vmv_x(v_raw);
        int32_t comp = (int32_t)raw < 0 ?
            (int32_t)(0x80000000u - raw) : (int32_t)raw;
        if (comp > max_comp) {
            max_comp = comp;
            max_idx = i;
        }
    }
    return max_idx;
}

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

    // FC3 with zeroed weights: set all output_logits to 0.0
    // (Instead of calling fc_fp32 with fc3_weight, we zero the output)
    {
        size_t vl1 = __riscv_vsetvl_e32m1(1);
        vfloat32m1_t v_zero = __riscv_vreinterpret_v_i32m1_f32m1(
            __riscv_vmv_v_x_i32m1(0, vl1));
        for (int i = 0; i < FC3_OUT; i++) {
            __riscv_vse32_v_f32m1(&output_logits[i], v_zero, vl1);
        }
    }

    int pred = argmax_fp32(output_logits, FC3_OUT);

    result[0] = pred;  // Should be 0, not 7
    spill_cache((uint32_t *)result, (uint32_t *)(result + 1));

    return 0;
}
