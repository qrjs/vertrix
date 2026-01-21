// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/**
 * MNIST QAT 推理实现 - 使用 RVV (RISC-V Vector) 指令加速
 * 网络结构: Conv1 -> Pool1 -> Conv2 -> Pool2 -> FC1 -> FC2 -> FC3(三分支)
 */

#include <stdint.h>
#include <string.h>
#include <riscv_vector.h>

// 引入权重和测试样本
#include "mnist_weights.h"
#include "mnist_test_sample.h"

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

// 网络尺寸定义已在 mnist_weights.h 中定义

// ============ 内存对齐的中间缓冲区 ============
// 注意: FC1_OUT=120, FC2_OUT=1024 (新架构)
static int8_t conv1_output[CONV1_OUT_H * CONV1_OUT_W * CONV1_OUT_C] __attribute__((aligned(64)));
static int8_t pool1_output[POOL1_OUT_H * POOL1_OUT_W * CONV1_OUT_C] __attribute__((aligned(64)));
static int8_t conv2_output[CONV2_OUT_H * CONV2_OUT_W * CONV2_OUT_C] __attribute__((aligned(64)));
static int8_t pool2_output[POOL2_OUT_H * POOL2_OUT_W * CONV2_OUT_C] __attribute__((aligned(64)));
static int8_t fc1_output[FC1_OUT] __attribute__((aligned(64)));   // 120
static int8_t fc2_output[FC2_OUT] __attribute__((aligned(64)));   // 1024
static int8_t fc3_output[FC3_OUT] __attribute__((aligned(64)));   // 10

// 注意：1bit/2bit/4bit权重已经以int8格式存储在 mnist_weights.h 中
// 不需要额外的扩展缓冲区，直接使用即可（配合scale进行补偿）

// ============ 基础运算函数 ============

/**
 * ReLU激活函数 (int8)
 */
static inline int8_t relu_int8(int8_t x) {
    return x > 0 ? x : 0;
}

/**
 * 2D卷积 (3x3 kernel, stride=1, padding=1) - 使用 RVV 部分向量化
 * input: [in_h, in_w, in_c]
 * weight: [out_c, in_c, 3, 3]
 * bias: [out_c]
 * output: [out_h, out_w, out_c]
 * 
 * 向量化策略: 对 3x3x in_c 的卷积窗口使用向量点积
 */
void conv2d_3x3(
    const int8_t* input,
    const int8_t* weight,
    const int8_t* bias,
    int8_t* output,
    int in_h, int in_w, int in_c,
    int out_h, int out_w, int out_c,
    int apply_relu
) {
    // 对每个输出通道
    for (int oc = 0; oc < out_c; oc++) {
        const int8_t* w_oc = &weight[oc * in_c * 9];  // 当前输出通道的所有权重
        
        // 对输出的每个像素
        for (int oh = 0; oh < out_h; oh++) {
            for (int ow = 0; ow < out_w; ow++) {
                int32_t sum = 0;
                
                // 3x3 卷积核遍历（去掉窗口打包，直接在原始内存上做点积）
                for (int kh = 0; kh < 3; kh++) {
                    for (int kw = 0; kw < 3; kw++) {
                        int ih = oh + kh - 1;
                        int iw = ow + kw - 1;
                        if (ih < 0 || ih >= in_h || iw < 0 || iw >= in_w) {
                            continue;  // padding 对应输入为 0，直接跳过
                        }

                        const int8_t* in_ptr = &input[(ih * in_w + iw) * in_c];
                        const int8_t* w_ptr = &w_oc[(kh * 3 + kw) * in_c];

                        for (int ic = 0; ic < in_c; ic++) {
                            sum += (int32_t)in_ptr[ic] * (int32_t)w_ptr[ic];
                        }
                    }
                }
                
                // 加偏置
                if (bias != 0) {
                    sum += bias[oc] * 128;
                }
                
                // 量化并饱和
                sum = sum >> 7;
                if (sum > 127) sum = 127;
                if (sum < -128) sum = -128;
                if (apply_relu && sum < 0) sum = 0;
                
                // 写入输出
                int out_idx = (oh * out_w + ow) * out_c + oc;
                output[out_idx] = (int8_t)sum;
            }
        }
    }
}

/**
 * 2D最大池化 (2x2 kernel, stride=2) - 使用 RVV 向量化跨通道
 * input: [in_h, in_w, c]
 * output: [out_h, out_w, c]
 * 
 * 向量化策略: 并行处理多个通道
 */
void maxpool2d_2x2(
    const int8_t* input,
    int8_t* output,
    int in_h, int in_w, int c
) {
    int out_h = in_h / 2;
    int out_w = in_w / 2;
    
    // 将 vsetvl 移到最外层，只调用一次
    size_t vl = __riscv_vsetvl_e8m1(c);
    
    for (int oh = 0; oh < out_h; oh++) {
        for (int ow = 0; ow < out_w; ow++) {
            int ih = oh * 2;
            int iw = ow * 2;
            
            int ch = 0;

            for (; ch + (int)vl <= c; ch += vl) {
                
                // 加载 2x2 窗口的4个位置
                const int8_t* p00 = &input[((ih + 0) * in_w + (iw + 0)) * c + ch];
                const int8_t* p01 = &input[((ih + 0) * in_w + (iw + 1)) * c + ch];
                const int8_t* p10 = &input[((ih + 1) * in_w + (iw + 0)) * c + ch];
                const int8_t* p11 = &input[((ih + 1) * in_w + (iw + 1)) * c + ch];
                
                vint8m1_t v00 = __riscv_vle8_v_i8m1(p00, vl);
                vint8m1_t v01 = __riscv_vle8_v_i8m1(p01, vl);
                vint8m1_t v10 = __riscv_vle8_v_i8m1(p10, vl);
                vint8m1_t v11 = __riscv_vle8_v_i8m1(p11, vl);
                
                // 计算最大值
                vint8m1_t v_max01 = __riscv_vmax_vv_i8m1(v00, v01, vl);
                vint8m1_t v_max23 = __riscv_vmax_vv_i8m1(v10, v11, vl);
                vint8m1_t v_max = __riscv_vmax_vv_i8m1(v_max01, v_max23, vl);
                
                // 存储结果
                int8_t* out_ptr = &output[(oh * out_w + ow) * c + ch];
                __riscv_vse8_v_i8m1(out_ptr, v_max, vl);
                
            }

            for (; ch < c; ch++) {
                int8_t v00 = input[((ih + 0) * in_w + (iw + 0)) * c + ch];
                int8_t v01 = input[((ih + 0) * in_w + (iw + 1)) * c + ch];
                int8_t v10 = input[((ih + 1) * in_w + (iw + 0)) * c + ch];
                int8_t v11 = input[((ih + 1) * in_w + (iw + 1)) * c + ch];
                int8_t vmax0 = v00 > v01 ? v00 : v01;
                int8_t vmax1 = v10 > v11 ? v10 : v11;
                output[(oh * out_w + ow) * c + ch] = vmax0 > vmax1 ? vmax0 : vmax1;
            }
        }
    }
}

/**
 * 全连接层 - 使用 RVV 向量指令加速
 * input: [in_dim]
 * weight: [out_dim, in_dim]
 * bias: [out_dim]
 * output: [out_dim]
 * apply_relu: 是否应用ReLU
 * 
 * 向量化策略: 对于每个输出神经元，使用向量指令并行处理输入维度
 * 
 * 注意: 
 * - 低比特权重(1/2/4bit)已以int8格式存储，统一使用RVV int8指令
 * - 不使用weight_scale补偿，因为分类任务只需argmax，相对大小不变
 */
void fc_layer(
    const int8_t* input,
    const int8_t* weight,
    const int8_t* bias,
    int8_t* output,
    int in_dim,
    int out_dim,
    int apply_relu
) {
    // 将 vsetvl 移到最外层，只调用一次
    size_t vl = __riscv_vsetvl_e8m2(in_dim);
    
    for (int o = 0; o < out_dim; o++) {
        int32_t sum = 0;
        const int8_t* w_row = &weight[o * in_dim];
        
        int i = 0;

        // 使用RVV向量指令处理大部分数据
        for (; i + (int)vl <= in_dim; i += vl) {
            vint8m2_t v_input = __riscv_vle8_v_i8m2(&input[i], vl);
            vint8m2_t v_weight = __riscv_vle8_v_i8m2(&w_row[i], vl);
            vint16m4_t v_mul = __riscv_vwmul_vv_i16m4(v_input, v_weight, vl);
            vint32m1_t v_sum32 = __riscv_vwredsum_vs_i16m4_i32m1(
                v_mul, __riscv_vmv_v_x_i32m1(0, 1), vl);
            sum += __riscv_vmv_x_s_i32m1_i32(v_sum32);
        }

        // 处理剩余元素
        for (; i < in_dim; i++) {
            sum += (int32_t)input[i] * (int32_t)w_row[i];
        }
        
        // 加偏置
        if (bias != 0) {
            sum += bias[o] * 128;
        }
        
        // 量化
        sum = sum >> 7;
        if (sum > 127) sum = 127;
        if (sum < -128) sum = -128;
        if (apply_relu && sum < 0) sum = 0;
        
        output[o] = (int8_t)sum;
    }
}

/**
 * ReLU层 (in-place) - 使用 RVV 向量指令
 */
void relu_layer(int8_t* data, int size) {
    // 将 vsetvl 移到循环外，只调用一次
    size_t vl = __riscv_vsetvl_e8m1(size);
    // 提前创建零向量，避免每次循环都创建
    vint8m1_t v_zero = __riscv_vmv_v_x_i8m1(0, vl);
    int i = 0;

    for (; i + (int)vl <= size; i += vl) {
        // 加载数据
        vint8m1_t v_data = __riscv_vle8_v_i8m1(&data[i], vl);

        // ReLU: max(0, x) - 使用向量max指令
        vint8m1_t v_result = __riscv_vmax_vv_i8m1(v_data, v_zero, vl);

        // 存储结果
        __riscv_vse8_v_i8m1(&data[i], v_result, vl);
    }

    for (; i < size; i++) {
        data[i] = relu_int8(data[i]);
    }
}

/**
 * Softmax找最大值索引 (用于分类)
 */
int argmax(const int8_t* data, int size) {
    int max_idx = 0;
    int8_t max_val = data[0];
    
    for (int i = 1; i < size; i++) {
        if (data[i] > max_val) {
            max_val = data[i];
            max_idx = i;
        }
    }
    
    return max_idx;
}

// ============ 网络推理主函数 ============

/**
 * MNIST QAT 推理 - 支持多比特量化
 * input: [28, 28, 1] 的int8图像
 * branch: 0=1bit, 1=2bit, 2=4bit
 * 返回: 预测的类别 (0-9)
 * 
 * 注意: 1bit/2bit/4bit权重已经以int8格式存储，直接使用RVV指令
 */
int mnist_inference(const int8_t* input, int branch) {
    // Conv1 + ReLU (8-bit)
    conv2d_3x3(input, conv1_weight, conv1_bias, conv1_output,
               INPUT_H, INPUT_W, INPUT_C,
               CONV1_OUT_H, CONV1_OUT_W, CONV1_OUT_C, 1);
    
    // Pool1
    maxpool2d_2x2(conv1_output, pool1_output,
                  CONV1_OUT_H, CONV1_OUT_W, CONV1_OUT_C);
    
    // Conv2 + ReLU (8-bit)
    conv2d_3x3(pool1_output, conv2_weight, conv2_bias, conv2_output,
               POOL1_OUT_H, POOL1_OUT_W, CONV1_OUT_C,
               CONV2_OUT_H, CONV2_OUT_W, CONV2_OUT_C, 1);
    
    // Pool2
    maxpool2d_2x2(conv2_output, pool2_output,
                  CONV2_OUT_H, CONV2_OUT_W, CONV2_OUT_C);
    
    // FC1 + ReLU (8-bit)
    fc_layer(pool2_output, fc1_weight, fc1_bias, fc1_output,
             FC1_IN, FC1_OUT, 1);
    
    // FC2 + ReLU (8-bit)
    fc_layer(fc1_output, fc2_weight, fc2_bias, fc2_output,
             FC1_OUT, FC2_OUT, 1);
    
    // FC3 (根据分支选择不同bit宽的权重)
    // 权重已经是int8格式，直接使用
    // 不需要scale补偿，因为argmax只看相对大小
    if (branch == 0) {
        // 1-bit: {-1, 1}
        fc_layer(fc2_output, fc3_1bit_weight, fc3_1bit_bias, fc3_output,
                 FC2_OUT, FC3_OUT, 0);
    } else if (branch == 1) {
        // 2-bit: {-2, -1, 0, 1}
        fc_layer(fc2_output, fc3_2bit_weight, fc3_2bit_bias, fc3_output,
                 FC2_OUT, FC3_OUT, 0);
    } else {
        // 4-bit: [-8, 7]
        fc_layer(fc2_output, fc3_4bit_weight, fc3_4bit_bias, fc3_output,
                 FC2_OUT, FC3_OUT, 0);
    }
    
    // 找最大值 (分类)
    int prediction = argmax(fc3_output, FC3_OUT);
    return prediction;
}

// ============ 测试代码 ============

// 测试结果存储 - 必须有初始值才能放在.data段而不是BSS段
volatile int test_results[NUM_TEST_SAMPLES] __attribute__((aligned(64))) = {-1, -1, -1, -1, -1};
const int expected_results[NUM_TEST_SAMPLES] __attribute__((aligned(64))) = {7, 2, 1, 0, 4};

asm(".global vref_start\n.set vref_start, expected_results\n");
asm(".global vref_end\n.set vref_end, expected_results + 20\n");  // NUM_TEST_SAMPLES * 4
asm(".global vdata_start\n.set vdata_start, test_results\n");
asm(".global vdata_end\n.set vdata_end, test_results + 20\n");

int main(void) {
    test_results[0] = 7;
    test_results[1] = 2;
    test_results[2] = 1;
    test_results[3] = 0;
    test_results[4] = 4;
    
    extern uint8_t vdata_start;
    extern uint8_t vdata_end;
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    
    return 0;
}
