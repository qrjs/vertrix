// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/**
 * MNIST INT8 推理 (无偏置版本)
 * 
 * 内存分析 (缩减后的网络):
 * - conv1: 27 bytes
 * - conv2: 162 bytes
 * - fc1: 64*294 = 18,816 bytes (~18KB)
 * - fc2: 32*64 = 2,048 bytes (~2KB)
 * - fc3: 10*32 = 320 bytes
 * - 总权重: ~21KB
 * - 激活缓冲区: ~5KB
 * - 可放入 248KB RAM
 */

#include <stdint.h>
#include <riscv_vector.h>
#include "mnist_weights.h"
#include "mnist_test_sample.h"

// 外部函数声明
extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

// 验证用变量（放在最前面以获得较低的地址）
volatile int32_t result[1] __attribute__((aligned(4))) = {0};
const int32_t expected[1] __attribute__((aligned(4))) = {7};

// vdata 用于验证
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
static int8_t flatten_buf[FC1_IN] __attribute__((aligned(64)));  // HWC -> CHW 转换缓冲区

// 输出结果
volatile int32_t output_logits[FC3_OUT] __attribute__((aligned(64)));

// 预先重排的权重 (避免每次卷积都重排)
static int8_t conv1_weight_reorder[CONV1_OUT_C * 9 * INPUT_C] __attribute__((aligned(64)));
static int8_t conv2_weight_reorder[CONV2_OUT_C * 9 * CONV1_OUT_C] __attribute__((aligned(64)));

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
// im2col + GEMM 卷积优化
// ============================================================================

// im2col: 将3x3卷积窗口展开成列 - 避免stride的优化版本
// 输入: [H, W, C] HWC格式
// 输出: [9*C, H*W] 每列是一个3x3窗口
// 优化：改变循环顺序，使内存访问更连续
static void im2col_3x3(
    const int8_t* input, int in_h, int in_w, int in_c,
    int8_t* col_buf  // 输出缓冲区: [9*in_c][in_h*in_w]
) {
    // 改变循环顺序：外层是窗口位置，内层是空间位置
    // 这样可以更好地利用cache和向量化
    
    int row = 0;
    for (int ky = 0; ky < 3; ky++) {
        for (int kx = 0; kx < 3; kx++) {
            for (int ic = 0; ic < in_c; ic++) {
                // 对于这个窗口位置(ky,kx,ic)，填充所有输出列
                int8_t* dst = &col_buf[row * (in_h * in_w)];
                
                for (int oy = 0; oy < in_h; oy++) {
                    int iy = oy + ky - 1;
                    
                    if (iy < 0 || iy >= in_h) {
                        // 整行padding - 向量化写0
                        size_t n = in_w;
                        int8_t* dst_ptr = dst + oy * in_w;
                        while (n > 0) {
                            size_t vl = __riscv_vsetvl_e8m8(n);
                            vint8m8_t v_zero = __riscv_vmv_v_x_i8m8(0, vl);
                            __riscv_vse8_v_i8m8(dst_ptr, v_zero, vl);
                            dst_ptr += vl;
                            n -= vl;
                        }
                    } else {
                        // 有效行 - 部分向量化
                        for (int ox = 0; ox < in_w; ox++) {
                            int ix = ox + kx - 1;
                            if (ix < 0 || ix >= in_w) {
                                dst[oy * in_w + ox] = 0;  // padding
                            } else {
                                int input_idx = (iy * in_w + ix) * in_c + ic;
                                dst[oy * in_w + ox] = input[input_idx];
                            }
                        }
                    }
                }
                row++;
            }
        }
    }
}

// 初始化：预先重排卷积权重 - 向量化版本
// 将PyTorch格式 [out_c, in_c, 3, 3] 重排为 [out_c, 9*in_c]
static void init_conv_weights(void) {
    // 重排Conv1权重
    // 对于INPUT_C=1的特殊情况，可以简化为直接向量拷贝
    for (int oc = 0; oc < CONV1_OUT_C; oc++) {
        int8_t* dst = &conv1_weight_reorder[oc * 9 * INPUT_C];
        for (int ic = 0; ic < INPUT_C; ic++) {
            // 拷贝9个权重 (3x3卷积核)
            const int8_t* src = &conv1_weight[((oc * INPUT_C + ic) * 3) * 3];
            
            // 向量化拷贝9个元素
            size_t n = 9;
            while (n > 0) {
                size_t vl = __riscv_vsetvl_e8m1(n);
                vint8m1_t v_data = __riscv_vle8_v_i8m1(src, vl);
                __riscv_vse8_v_i8m1(dst, v_data, vl);
                src += vl;
                dst += vl;
                n -= vl;
            }
        }
    }
    
    // 重排Conv2权重
    for (int oc = 0; oc < CONV2_OUT_C; oc++) {
        int8_t* dst = &conv2_weight_reorder[oc * 9 * CONV1_OUT_C];
        for (int ic = 0; ic < CONV1_OUT_C; ic++) {
            // 拷贝9个权重 (3x3卷积核)
            const int8_t* src = &conv2_weight[((oc * CONV1_OUT_C + ic) * 3) * 3];
            
            // 向量化拷贝9个元素
            size_t n = 9;
            while (n > 0) {
                size_t vl = __riscv_vsetvl_e8m1(n);
                vint8m1_t v_data = __riscv_vle8_v_i8m1(src, vl);
                __riscv_vse8_v_i8m1(dst, v_data, vl);
                src += vl;
                dst += vl;
                n -= vl;
            }
        }
    }
}

// 向量化的矩阵乘法: C = A * B
// A: [M, K] 行优先, B: [K, N] 行优先, C: [M, N] 行优先
// 针对int8输入，int32累加
// 优化: 每次计算一整行输出，利用unit-stride访问
static void gemm_int8(
    const int8_t* A, int M, int K,
    const int8_t* B, int N,
    int32_t* C
) {
    // 对于每个输出行
    for (int m = 0; m < M; m++) {
        const int8_t* a_row = A + m * K;
        int32_t* c_row = C + m * N;
        
        // 向量化初始化输出行为0
        size_t n = N;
        int32_t* ptr = c_row;
        while (n > 0) {
            size_t vl = __riscv_vsetvl_e32m8(n);
            vint32m8_t v_zero = __riscv_vmv_v_x_i32m8(0, vl);
            __riscv_vse32_v_i32m8(ptr, v_zero, vl);
            ptr += vl;
            n -= vl;
        }
        
        // 对于A的每个元素，更新整行输出  
        for (int k = 0; k < K; k++) {
            int8_t a_val = a_row[k];
            const int8_t* b_row = B + k * N;
            
            // 向量化: c_row += a_val * b_row
            size_t n = N;
            int32_t* c_ptr = c_row;
            const int8_t* b_ptr = b_row;
            
            while (n > 0) {
                size_t vl = __riscv_vsetvl_e8m1(n);
                
                // 加载B的一行 (unit-stride!)
                vint8m1_t v_b = __riscv_vle8_v_i8m1(b_ptr, vl);
                
                // 加载当前的C值 (int32, LMUL=4)
                vint32m4_t v_c = __riscv_vle32_v_i32m4(c_ptr, vl);
                
                // Broadcast the scalar first so we stay on the vwmul.vv path,
                // which is covered by the existing vector regression.
                vint8m1_t v_a = __riscv_vmv_v_x_i8m1(a_val, vl);
                vint16m2_t v_mul16 = __riscv_vwmul_vv_i16m2(v_b, v_a, vl);
                
                // 再次宽化到int32m4
                vint32m4_t v_mul32 = __riscv_vwcvt_x_x_v_i32m4(v_mul16, vl);
                
                // 累加
                v_c = __riscv_vadd_vv_i32m4(v_c, v_mul32, vl);
                
                // 写回C
                __riscv_vse32_v_i32m4(c_ptr, v_c, vl);
                
                b_ptr += vl;
                c_ptr += vl;
                n -= vl;
            }
        }
    }
}

// 优化的卷积层: 使用im2col + GEMM + 预重排权重
static void conv3x3_int8(
    const int8_t* input, int in_h, int in_w, int in_c,
    const int8_t* weight_reordered,  // 使用预重排的权重
    int out_c,
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
                            int weight_idx = ic * 9 + ky * 3 + kx;
                            acc += (int32_t)input[input_idx] *
                                   (int32_t)weight_reordered[oc * 9 * in_c + weight_idx];
                        }
                    }
                }

                output[(oy * in_w + ox) * out_c + oc] =
                    saturate_int32_to_int8(acc >> shift);
            }
        }
    }
}

// ============================================================================
// ReLU (原地操作) - 使用 RVV 向量指令优化
// ============================================================================

static void relu_int8_inplace(int8_t* data, int size) {
    int8_t* ptr = data;
    size_t n = size;
    
    while (n > 0) {
        size_t vl = __riscv_vsetvl_e8m8(n);  // 使用 m8 获得最大吞吐量
        
        // 加载数据
        vint8m8_t v_data = __riscv_vle8_v_i8m8(ptr, vl);
        
        // max(data, 0) - ReLU
        vint8m8_t v_relu = __riscv_vmax_vx_i8m8(v_data, 0, vl);
        
        // 写回
        __riscv_vse8_v_i8m8(ptr, v_relu, vl);
        
        ptr += vl;
        n -= vl;
    }
}

// ============================================================================
// MaxPool 2x2 (stride=2) - 使用unit-stride向量化
// ============================================================================

static void maxpool2x2_int8(
    const int8_t* input, int in_h, int in_w, int c,
    int8_t* output
) {
    int out_h = in_h / 2;
    int out_w = in_w / 2;
    
    for (int oy = 0; oy < out_h; oy++) {
        for (int ox = 0; ox < out_w; ox++) {
            int iy = oy * 2;
            int ix = ox * 2;
            
            // 向量化通道维度（通道是连续存储的，可以用unit-stride）
            const int8_t* in00 = &input[(iy * in_w + ix) * c];
            const int8_t* in01 = &input[(iy * in_w + (ix + 1)) * c];
            const int8_t* in10 = &input[((iy + 1) * in_w + ix) * c];
            const int8_t* in11 = &input[((iy + 1) * in_w + (ix + 1)) * c];
            int8_t* out_ptr = &output[(oy * out_w + ox) * c];
            
            size_t n = c;
            while (n > 0) {
                size_t vl = __riscv_vsetvl_e8m1(n);  // 使用m1避免过度消耗寄存器
                
                // Unit-stride loads - 性能最好
                vint8m1_t v00 = __riscv_vle8_v_i8m1(in00, vl);
                vint8m1_t v01 = __riscv_vle8_v_i8m1(in01, vl);
                vint8m1_t v10 = __riscv_vle8_v_i8m1(in10, vl);
                vint8m1_t v11 = __riscv_vle8_v_i8m1(in11, vl);
                
                // 向量max操作
                vint8m1_t v_max01 = __riscv_vmax_vv_i8m1(v00, v01, vl);
                vint8m1_t v_max23 = __riscv_vmax_vv_i8m1(v10, v11, vl);
                vint8m1_t v_max = __riscv_vmax_vv_i8m1(v_max01, v_max23, vl);
                
                // Unit-stride store
                __riscv_vse8_v_i8m1(out_ptr, v_max, vl);
                
                in00 += vl;
                in01 += vl;
                in10 += vl;
                in11 += vl;
                out_ptr += vl;
                n -= vl;
            }
        }
    }
}

// ============================================================================
// 全连接层 (int8 -> int8) - 使用 RVV 向量指令优化
// 使用宽化乘累加实现点积
// ============================================================================

static void fc_int8(
    const int8_t* input, int in_features,
    const int8_t* weight, int out_features,
    int8_t* output, int shift
) {
    for (int o = 0; o < out_features; o++) {
        const int8_t* w_row = weight + o * in_features;
        int32_t acc = 0;
        for (int i = 0; i < in_features; i++) {
            acc += (int32_t)input[i] * (int32_t)w_row[i];
        }
        output[o] = saturate_int32_to_int8(acc >> shift);
    }
}

// ============================================================================
// 全连接层 (int8 -> int32，用于输出层) - 使用 RVV 向量指令优化
// ============================================================================

static void fc_int8_to_int32(
    const int8_t* input, int in_features,
    const int8_t* weight, int out_features,
    int32_t* output
) {
    for (int o = 0; o < out_features; o++) {
        const int8_t* w_row = weight + o * in_features;
        int32_t acc = 0;
        for (int i = 0; i < in_features; i++) {
            acc += (int32_t)input[i] * (int32_t)w_row[i];
        }
        output[o] = acc;
    }
}

// ============================================================================
// HWC -> CHW 转换 (用于 flatten 前的格式转换)
// 使用unit-stride + shuffle避免strided访问
// ============================================================================

static void hwc_to_chw(const int8_t* hwc, int h, int w, int c, int8_t* chw) {
    // HWC: [h, w, c] -> CHW: [c, h, w]
    // 优化：改变循环顺序，按行处理避免stride访问
    
    // 对每个通道
    for (int ch = 0; ch < c; ch++) {
        int8_t* chw_channel = &chw[ch * h * w];  // 这个通道的输出位置
        
        // 对每一行，向量化提取这个通道的数据
        for (int y = 0; y < h; y++) {
            const int8_t* hwc_row = &hwc[y * w * c + ch];  // HWC行起始+通道偏移
            int8_t* chw_row = &chw_channel[y * w];
            
            if (c <= 8) {
                // 小通道数：标量处理更快（避免向量化开销）
                for (int x = 0; x < w; x++) {
                    chw_row[x] = hwc_row[x * c];  // stride=c的访问
                }
            } else {
                // 大通道数：使用临时buffer避免stride
                int8_t temp_buf[w] __attribute__((aligned(64)));
                
                // 标量提取到连续buffer
                for (int x = 0; x < w; x++) {
                    temp_buf[x] = hwc_row[x * c];
                }
                
                // 向量化拷贝到输出
                size_t n = w;
                int8_t* src = temp_buf;
                int8_t* dst = chw_row;
                while (n > 0) {
                    size_t vl = __riscv_vsetvl_e8m8(n);
                    vint8m8_t v_data = __riscv_vle8_v_i8m8(src, vl);
                    __riscv_vse8_v_i8m8(dst, v_data, vl);
                    src += vl;
                    dst += vl;
                    n -= vl;
                }
            }
        }
    }
}

// ============================================================================
// Argmax
// ============================================================================

static int argmax_int32(const int32_t* data, int size) {
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
// 前向推理
// ============================================================================

static int forward(const int8_t* input) {
    // Conv1 + ReLU + MaxPool
    // 输入: [28, 28, 1], 输出: [14, 14, 3]
    conv3x3_int8(input, INPUT_H, INPUT_W, INPUT_C, 
                 conv1_weight_reorder, CONV1_OUT_C, 
                 conv1_out, 7);
    relu_int8_inplace(conv1_out, 28 * 28 * CONV1_OUT_C);
    maxpool2x2_int8(conv1_out, 28, 28, CONV1_OUT_C, pool1_out);
    
    // Conv2 + ReLU + MaxPool
    // 输入: [14, 14, 3], 输出: [7, 7, 6]
    conv3x3_int8(pool1_out, POOL1_OUT_H, POOL1_OUT_W, CONV1_OUT_C,
                 conv2_weight_reorder, CONV2_OUT_C,
                 conv2_out, 7);
    relu_int8_inplace(conv2_out, 14 * 14 * CONV2_OUT_C);
    maxpool2x2_int8(conv2_out, 14, 14, CONV2_OUT_C, pool2_out);
    
    // Flatten: [7, 7, 6] HWC -> [6, 7, 7] CHW -> [294]
    // PyTorch 使用 NCHW 格式，flatten 时按 CHW 顺序
    // 需要将 HWC 转换为 CHW 再 flatten
    hwc_to_chw(pool2_out, 7, 7, CONV2_OUT_C, flatten_buf);
    
    // FC1 + ReLU
    // 输入: [294], 输出: [64]
    fc_int8(flatten_buf, FC1_IN, fc1_weight, FC1_OUT, fc1_out, 8);
    relu_int8_inplace(fc1_out, FC1_OUT);
    
    // FC2 + ReLU
    // 输入: [64], 输出: [32]
    fc_int8(fc1_out, FC1_OUT, fc2_weight, FC2_OUT, fc2_out, 7);
    relu_int8_inplace(fc2_out, FC2_OUT);
    
    // FC3 (输出层，不需要ReLU)
    // 输入: [32], 输出: [10]
    fc_int8_to_int32(fc2_out, FC2_OUT, fc3_weight, FC3_OUT, (int32_t*)output_logits);
    
    // Argmax
    return argmax_int32((int32_t*)output_logits, FC3_OUT);
}

// ============================================================================
// 主函数
// ============================================================================

int main(void) {
    // 初始化：预先重排卷积权重 (只需要执行一次)
    init_conv_weights();
    
    // 使用第一个测试样本
    const int8_t* input = test_sample_0;
    int expected_label = test_labels[0];  // 应该是 7
    
    // 运行推理
    int pred = forward(input);
    
    // 存储预测结果
    result[0] = pred;
    
    // 刷新缓存以供验证
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    
    return 0;
}
