// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/**
 * MNIST INT8 推理 - 纯标量版本（无向量指令）
 * 用于性能对比测试
 */

#include <stdint.h>
#include "mnist_weights.h"
#include "mnist_test_sample.h"

// 外部函数声明
extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

// 验证用变量
volatile int32_t result[1] __attribute__((aligned(4))) = {0};
const int32_t expected[1] __attribute__((aligned(4))) = {7};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

// 中间激活缓冲区
static int8_t conv1_out[28 * 28 * CONV1_OUT_C] __attribute__((aligned(64)));
static int8_t pool1_out[14 * 14 * CONV1_OUT_C] __attribute__((aligned(64)));
static int8_t conv2_out[14 * 14 * CONV2_OUT_C] __attribute__((aligned(64)));
static int8_t pool2_out[7 * 7 * CONV2_OUT_C] __attribute__((aligned(64)));
static int8_t fc1_out[FC1_OUT] __attribute__((aligned(64)));
static int8_t fc2_out[FC2_OUT] __attribute__((aligned(64)));
static int8_t flatten_buf[FC1_IN] __attribute__((aligned(64)));

// 输出结果
volatile int32_t output_logits[FC3_OUT] __attribute__((aligned(64)));

// ============================================================================
// 辅助函数
// ============================================================================

static inline int8_t saturate_int32_to_int8(int32_t x) {
    if (x > 127) return 127;
    if (x < -128) return -128;
    return (int8_t)x;
}

static inline int8_t max_int8(int8_t a, int8_t b) {
    return (a > b) ? a : b;
}

// ============================================================================
// 卷积层 (3x3, padding=1, stride=1) - 纯标量版本
// ============================================================================

static void conv3x3_int8_scalar(
    const int8_t* input, int in_h, int in_w, int in_c,
    const int8_t* weight, int out_c,
    int8_t* output, int shift
) {
    for (int oy = 0; oy < in_h; oy++) {
        for (int ox = 0; ox < in_w; ox++) {
            for (int oc = 0; oc < out_c; oc++) {
                int32_t acc = 0;
                
                for (int ky = 0; ky < 3; ky++) {
                    int iy = oy + ky - 1;
                    if (iy < 0 || iy >= in_h) continue;
                    
                    for (int kx = 0; kx < 3; kx++) {
                        int ix = ox + kx - 1;
                        if (ix < 0 || ix >= in_w) continue;
                        
                        for (int ic = 0; ic < in_c; ic++) {
                            int input_idx = (iy * in_w + ix) * in_c + ic;
                            int weight_idx = ((oc * in_c + ic) * 3 + ky) * 3 + kx;
                            acc += (int32_t)input[input_idx] * (int32_t)weight[weight_idx];
                        }
                    }
                }
                
                output[(oy * in_w + ox) * out_c + oc] = saturate_int32_to_int8(acc >> shift);
            }
        }
    }
}

// ============================================================================
// ReLU - 纯标量版本
// ============================================================================

static void relu_int8_inplace_scalar(int8_t* data, int size) {
    for (int i = 0; i < size; i++) {
        if (data[i] < 0) {
            data[i] = 0;
        }
    }
}

// ============================================================================
// MaxPool 2x2 - 纯标量版本
// ============================================================================

static void maxpool2x2_int8_scalar(
    const int8_t* input, int in_h, int in_w, int c,
    int8_t* output
) {
    int out_h = in_h / 2;
    int out_w = in_w / 2;
    
    for (int oy = 0; oy < out_h; oy++) {
        for (int ox = 0; ox < out_w; ox++) {
            int iy = oy * 2;
            int ix = ox * 2;
            
            for (int ch = 0; ch < c; ch++) {
                int8_t v00 = input[(iy * in_w + ix) * c + ch];
                int8_t v01 = input[(iy * in_w + ix + 1) * c + ch];
                int8_t v10 = input[((iy + 1) * in_w + ix) * c + ch];
                int8_t v11 = input[((iy + 1) * in_w + ix + 1) * c + ch];
                
                int8_t max_val = max_int8(max_int8(v00, v01), max_int8(v10, v11));
                output[(oy * out_w + ox) * c + ch] = max_val;
            }
        }
    }
}

// ============================================================================
// 全连接层 - 纯标量版本
// ============================================================================

static void fc_int8_scalar(
    const int8_t* input, int in_features,
    const int8_t* weight, int out_features,
    int8_t* output, int shift
) {
    for (int o = 0; o < out_features; o++) {
        int32_t acc = 0;
        
        for (int i = 0; i < in_features; i++) {
            acc += (int32_t)input[i] * (int32_t)weight[o * in_features + i];
        }
        
        output[o] = saturate_int32_to_int8(acc >> shift);
    }
}

static void fc_int8_to_int32_scalar(
    const int8_t* input, int in_features,
    const int8_t* weight, int out_features,
    int32_t* output
) {
    for (int o = 0; o < out_features; o++) {
        int32_t acc = 0;
        
        for (int i = 0; i < in_features; i++) {
            acc += (int32_t)input[i] * (int32_t)weight[o * in_features + i];
        }
        
        output[o] = acc;
    }
}

// ============================================================================
// HWC -> CHW 转换 - 纯标量版本
// ============================================================================

static void hwc_to_chw_scalar(const int8_t* hwc, int h, int w, int c, int8_t* chw) {
    for (int ch = 0; ch < c; ch++) {
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int hwc_idx = (y * w + x) * c + ch;
                int chw_idx = (ch * h + y) * w + x;
                chw[chw_idx] = hwc[hwc_idx];
            }
        }
    }
}

// ============================================================================
// Argmax - 纯标量版本
// ============================================================================

static int argmax_int32_scalar(const int32_t* data, int size) {
    int max_idx = 0;
    int32_t max_val = data[0];
    
    for (int i = 1; i < size; i++) {
        if (data[i] > max_val) {
            max_val = data[i];
            max_idx = i;
        }
    }
    
    return max_idx;
}

// ============================================================================
// 前向推理 - 纯标量版本
// ============================================================================

static int forward_scalar(const int8_t* input) {
    // Conv1 + ReLU + MaxPool
    conv3x3_int8_scalar(input, INPUT_H, INPUT_W, INPUT_C, 
                        conv1_weight, CONV1_OUT_C, 
                        conv1_out, 7);
    relu_int8_inplace_scalar(conv1_out, 28 * 28 * CONV1_OUT_C);
    maxpool2x2_int8_scalar(conv1_out, 28, 28, CONV1_OUT_C, pool1_out);
    
    // Conv2 + ReLU + MaxPool
    conv3x3_int8_scalar(pool1_out, POOL1_OUT_H, POOL1_OUT_W, CONV1_OUT_C,
                        conv2_weight, CONV2_OUT_C,
                        conv2_out, 7);
    relu_int8_inplace_scalar(conv2_out, 14 * 14 * CONV2_OUT_C);
    maxpool2x2_int8_scalar(conv2_out, 14, 14, CONV2_OUT_C, pool2_out);
    
    // Flatten: HWC -> CHW
    hwc_to_chw_scalar(pool2_out, 7, 7, CONV2_OUT_C, flatten_buf);
    
    // FC1 + ReLU
    fc_int8_scalar(flatten_buf, FC1_IN, fc1_weight, FC1_OUT, fc1_out, 8);
    relu_int8_inplace_scalar(fc1_out, FC1_OUT);
    
    // FC2 + ReLU
    fc_int8_scalar(fc1_out, FC1_OUT, fc2_weight, FC2_OUT, fc2_out, 7);
    relu_int8_inplace_scalar(fc2_out, FC2_OUT);
    
    // FC3
    fc_int8_to_int32_scalar(fc2_out, FC2_OUT, fc3_weight, FC3_OUT, (int32_t*)output_logits);
    
    // Argmax
    return argmax_int32_scalar((int32_t*)output_logits, FC3_OUT);
}

// ============================================================================
// 主函数
// ============================================================================

int main(void) {
    const int8_t* input = test_sample_0;
    
    // 运行纯标量推理
    int pred = forward_scalar(input);
    
    // 存储预测结果
    result[0] = pred;
    
    // 刷新缓存以供验证
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    
    return 0;
}
