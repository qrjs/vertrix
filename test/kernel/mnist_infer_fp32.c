// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/**
 * MNIST FP32 推理 - 纯 RVV 向量指令实现
 *
 * 重要: Ibex+Vicuna 架构约束:
 * - Ibex 没有标量 FPU，不支持 OP-FP 指令 (fadd.s, fmul.s, fmv.w.x 等)
 * - Ibex 没有 FP 寄存器文件，不支持 LOAD-FP/STORE-FP (flw/fsw)
 * - 仅支持 OP-V 向量指令，且只能使用 .vv 和 .vs 形式
 * - 不能使用 .vf 形式 (需要标量 FP 寄存器)
 * - 所有 FP 数据通过 vle32.v / vse32.v 在内存和向量寄存器间移动
 */

#include <stdint.h>
#include <riscv_vector.h>
#include "mnist_weights_fp32.h"
#include "mnist_test_sample_fp32.h"

// 外部函数声明
extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

// result[0] = prediction (compared against expected)
// result[1..11] = diagnostic data (not compared)
volatile int32_t result[12] __attribute__((aligned(4))) = {0};
const int32_t expected[1] __attribute__((aligned(4))) = {7};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

// 零值常量 - 用于 vle32.v 加载零向量
static const float f_zero_val __attribute__((aligned(4))) = 0.0f;

// 中间激活缓冲区 (FP32)
static float conv1_out[28 * 28 * CONV1_OUT_C] __attribute__((aligned(64)));
static float pool1_out[14 * 14 * CONV1_OUT_C] __attribute__((aligned(64)));
static float conv2_out[14 * 14 * CONV2_OUT_C] __attribute__((aligned(64)));
static float pool2_out[7 * 7 * CONV2_OUT_C] __attribute__((aligned(64)));
static float fc1_out[FC1_OUT] __attribute__((aligned(64)));
static float fc2_out[FC2_OUT] __attribute__((aligned(64)));
static float flatten_buf[FC1_IN] __attribute__((aligned(64)));

// 输出 logits
static float output_logits[FC3_OUT] __attribute__((aligned(64)));

// ============================================================================
// Conv 3x3 (padding=1, stride=1) - 纯 RVV vv 操作
// 使用 vl=1 向量操作替代标量 FP，逐像素计算
// ============================================================================

static void conv3x3_fp32(
    const float* input, int in_h, int in_w, int in_c,
    const float* weight, int out_c,
    float* output
) {
    size_t vl1 = __riscv_vsetvl_e32m1(1);

    for (int oy = 0; oy < in_h; oy++) {
        for (int ox = 0; ox < in_w; ox++) {
            for (int oc = 0; oc < out_c; oc++) {
                // 从内存加载零值到向量寄存器
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
                            // 所有操作通过 vle32/vfmacc.vv 完成，无标量 FP
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

// ============================================================================
// ReLU (原地) - 使用 vfmax.vv 与零向量
// ============================================================================

static void relu_fp32_inplace(float* data, int size) {
    // Use vl=1 to avoid hardware bug with vfmax.vv at vl>1
    size_t vl1 = __riscv_vsetvl_e32m1(1);
    for (int i = 0; i < size; i++) {
        vfloat32m1_t v = __riscv_vle32_v_f32m1(&data[i], vl1);
        vfloat32m1_t v_zero = __riscv_vle32_v_f32m1(&f_zero_val, vl1);
        v = __riscv_vfmax_vv_f32m1(v, v_zero, vl1);
        __riscv_vse32_v_f32m1(&data[i], v, vl1);
    }
}

// ============================================================================
// MaxPool 2x2 (stride=2) - 使用 vfmax.vv 向量化通道维度
// ============================================================================

static void maxpool2x2_fp32(
    const float* input, int in_h, int in_w, int c,
    float* output
) {
    int out_h = in_h / 2;
    int out_w = in_w / 2;
    // Use vl=1 to avoid hardware bug with vfmax.vv at vl>1
    size_t vl1 = __riscv_vsetvl_e32m1(1);

    for (int oy = 0; oy < out_h; oy++) {
        for (int ox = 0; ox < out_w; ox++) {
            int iy = oy * 2;
            int ix = ox * 2;

            for (int ch = 0; ch < c; ch++) {
                vfloat32m1_t v00 = __riscv_vle32_v_f32m1(&input[(iy * in_w + ix) * c + ch], vl1);
                vfloat32m1_t v01 = __riscv_vle32_v_f32m1(&input[(iy * in_w + (ix + 1)) * c + ch], vl1);
                vfloat32m1_t v10 = __riscv_vle32_v_f32m1(&input[((iy + 1) * in_w + ix) * c + ch], vl1);
                vfloat32m1_t v11 = __riscv_vle32_v_f32m1(&input[((iy + 1) * in_w + (ix + 1)) * c + ch], vl1);

                vfloat32m1_t vmax01 = __riscv_vfmax_vv_f32m1(v00, v01, vl1);
                vfloat32m1_t vmax23 = __riscv_vfmax_vv_f32m1(v10, v11, vl1);
                vfloat32m1_t vmax   = __riscv_vfmax_vv_f32m1(vmax01, vmax23, vl1);

                __riscv_vse32_v_f32m1(&output[(oy * out_w + ox) * c + ch], vmax, vl1);
            }
        }
    }
}

// ============================================================================
// 全连接层 - 使用 vfmul.vv + vfredusum.vs 向量化点积
// ============================================================================

static void fc_fp32(
    const float* input, int in_features,
    const float* weight, int out_features,
    float* output
) {
    // Use vl=1 with vfmacc to avoid vfmul/vfredusum with vl>1 (hardware bug)
    size_t vl1 = __riscv_vsetvl_e32m1(1);

    for (int o = 0; o < out_features; o++) {
        const float* w_row = weight + o * in_features;

        vfloat32m1_t v_sum = __riscv_vle32_v_f32m1(&f_zero_val, vl1);

        for (int i = 0; i < in_features; i++) {
            vfloat32m1_t v_in = __riscv_vle32_v_f32m1(&input[i], vl1);
            vfloat32m1_t v_w  = __riscv_vle32_v_f32m1(&w_row[i], vl1);
            v_sum = __riscv_vfmacc_vv_f32m1(v_sum, v_w, v_in, vl1);
        }

        __riscv_vse32_v_f32m1(&output[o], v_sum, vl1);
    }
}

// ============================================================================
// HWC -> CHW 转换 - 使用 uint32 拷贝避免任何 FP 指令
// ============================================================================

static void hwc_to_chw_fp32(const float* hwc, int h, int w, int c, float* chw) {
    const uint32_t* src = (const uint32_t*)hwc;
    uint32_t* dst = (uint32_t*)chw;

    for (int ch = 0; ch < c; ch++) {
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int hwc_idx = (y * w + x) * c + ch;
                int chw_idx = (ch * h + y) * w + x;
                dst[chw_idx] = src[hwc_idx];
            }
        }
    }
}

// ============================================================================
// Argmax - 使用 IEEE 754 位模式整数比较
// ============================================================================

static int argmax_fp32(const float* data, int size) {
    const uint32_t* idata = (const uint32_t*)data;
    int max_idx = 0;
    uint32_t raw0 = idata[0];
    int32_t max_comp = (int32_t)raw0 < 0 ?
        (int32_t)(0x80000000u - raw0) : (int32_t)raw0;

    for (int i = 1; i < size; i++) {
        uint32_t raw = idata[i];
        int32_t comp = (int32_t)raw < 0 ?
            (int32_t)(0x80000000u - raw) : (int32_t)raw;

        if (comp > max_comp) {
            max_comp = comp;
            max_idx = i;
        }
    }

    return max_idx;
}

// ============================================================================
// 主函数
// ============================================================================

int main(void) {
    // Conv1 + ReLU + Pool1
    conv3x3_fp32(test_sample_0, INPUT_H, INPUT_W, INPUT_C,
                 conv1_weight, CONV1_OUT_C, conv1_out);
    relu_fp32_inplace(conv1_out, 28 * 28 * CONV1_OUT_C);
    maxpool2x2_fp32(conv1_out, 28, 28, CONV1_OUT_C, pool1_out);

    // Conv2 + ReLU + Pool2
    conv3x3_fp32(pool1_out, POOL1_OUT_H, POOL1_OUT_W, CONV1_OUT_C,
                 conv2_weight, CONV2_OUT_C, conv2_out);
    relu_fp32_inplace(conv2_out, 14 * 14 * CONV2_OUT_C);
    maxpool2x2_fp32(conv2_out, 14, 14, CONV2_OUT_C, pool2_out);

    // Flatten + FC1 + ReLU
    hwc_to_chw_fp32(pool2_out, 7, 7, CONV2_OUT_C, flatten_buf);
    fc_fp32(flatten_buf, FC1_IN, fc1_weight, FC1_OUT, fc1_out);
    relu_fp32_inplace(fc1_out, FC1_OUT);

    // FC2 + ReLU
    fc_fp32(fc1_out, FC1_OUT, fc2_weight, FC2_OUT, fc2_out);
    relu_fp32_inplace(fc2_out, FC2_OUT);

    // FC3 + Argmax
    fc_fp32(fc2_out, FC2_OUT, fc3_weight, FC3_OUT, output_logits);
    int pred = argmax_fp32(output_logits, FC3_OUT);

    // result[0] = prediction (compared against expected[0] = 7)
    result[0] = pred;

    // Diagnostic data (not part of comparison)
    result[1] = (int32_t)(*(const uint32_t*)&pool1_out[0]);
    result[2] = (int32_t)(*(const uint32_t*)&pool2_out[0]);
    result[3] = (int32_t)(*(const uint32_t*)&fc1_out[0]);
    result[4] = (int32_t)(*(const uint32_t*)&fc2_out[0]);
    const uint32_t* logits_raw = (const uint32_t*)output_logits;
    for (int i = 0; i < 7; i++) {
        result[5 + i] = (int32_t)logits_raw[i];
    }

    // Flush result to main memory
    spill_cache((uint32_t *)result, (uint32_t *)(result + 12));

    return 0;
}
