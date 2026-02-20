#include <stdint.h>
#include <riscv_vector.h>
#include "mnist_weights.h"
#include "mnist_test_sample.h"

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

volatile int32_t result[1] __attribute__((aligned(4))) = {0};
const int32_t expected[1] __attribute__((aligned(4))) = {7};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

static int8_t conv1_out[28 * 28 * CONV1_OUT_C] __attribute__((aligned(64)));
static int8_t pool1_out[14 * 14 * CONV1_OUT_C] __attribute__((aligned(64)));
static int8_t conv2_out[14 * 14 * CONV2_OUT_C] __attribute__((aligned(64)));
static int8_t pool2_out[7 * 7 * CONV2_OUT_C] __attribute__((aligned(64)));
static int8_t fc1_out[FC1_OUT] __attribute__((aligned(64)));
static int8_t fc2_out[FC2_OUT] __attribute__((aligned(64)));
static int8_t flatten_buf[FC1_IN] __attribute__((aligned(64)));

volatile int32_t output_logits[FC3_OUT] __attribute__((aligned(64)));

static int8_t conv1_weight_reorder[CONV1_OUT_C * 9 * INPUT_C] __attribute__((aligned(64)));
static int8_t conv2_weight_reorder[CONV2_OUT_C * 9 * CONV1_OUT_C] __attribute__((aligned(64)));

static inline void mvin_a(const void* addr) {
    register uint32_t a0 asm("x10") = (uint32_t)addr;
    register uint32_t a1 asm("x11") = 0;
    asm volatile(".insn r 0x0b, 0, 0, x1, x10, x11" : : "r"(a0), "r"(a1) : "memory");
}

static inline void mvin_b(const void* addr) {
    register uint32_t a0 asm("x10") = (uint32_t)addr;
    register uint32_t a1 asm("x11") = 0;
    asm volatile(".insn r 0x0b, 0, 0, x2, x10, x11" : : "r"(a0), "r"(a1) : "memory");
}

static inline void mat_mul(void) {
    register uint32_t a0 asm("x10") = 1;
    register uint32_t a1 asm("x11") = 2;
    asm volatile(".insn r 0x0b, 2, 0, x3, x10, x11" : : "r"(a0), "r"(a1) : "memory");
}

static inline void mat_store(void* addr) {
    register uint32_t a0 asm("x10") = (uint32_t)addr;
    register uint32_t a1 asm("x11") = 0;
    asm volatile(".insn r 0x0b, 1, 0, x3, x10, x11" : : "r"(a0), "r"(a1) : "memory");
}

static inline int8_t saturate_int32_to_int8(int32_t x) {
    if (x > 127) return 127;
    if (x < -128) return -128;
    return (int8_t)x;
}

static void gemm_matunit(
    const int8_t* A, int M, int K,
    const int8_t* B, int N,
    int32_t* C
) {
    int8_t a_tile[64] __attribute__((aligned(64)));
    int8_t b_tile[64] __attribute__((aligned(64)));
    int8_t c_tile[64] __attribute__((aligned(64)));

    for (int i = 0; i < M * N; i++) C[i] = 0;

    for (int m = 0; m < M; m += 8) {
        int mr = (m + 8 <= M) ? 8 : (M - m);
        for (int n = 0; n < N; n += 8) {
            int nr = (n + 8 <= N) ? 8 : (N - n);
            for (int k = 0; k < K; k += 8) {
                int kr = (k + 8 <= K) ? 8 : (K - k);

                for (int i = 0; i < 64; i++) a_tile[i] = 0;
                for (int i = 0; i < mr; i++)
                    for (int j = 0; j < kr; j++)
                        a_tile[i * 8 + j] = A[(m + i) * K + k + j];

                for (int i = 0; i < 64; i++) b_tile[i] = 0;
                for (int i = 0; i < kr; i++)
                    for (int j = 0; j < nr; j++)
                        b_tile[i * 8 + j] = B[(k + i) * N + n + j];

                mvin_a(a_tile);
                mvin_b(b_tile);
                mat_mul();
                mat_store(c_tile);

                for (int i = 0; i < mr; i++)
                    for (int j = 0; j < nr; j++)
                        C[(m + i) * N + n + j] += c_tile[i * 8 + j];
            }
        }
    }
}

static void im2col_3x3(
    const int8_t* input, int in_h, int in_w, int in_c,
    int8_t* col_buf
) {
    int row = 0;
    for (int ky = 0; ky < 3; ky++) {
        for (int kx = 0; kx < 3; kx++) {
            for (int ic = 0; ic < in_c; ic++) {
                int8_t* dst = &col_buf[row * (in_h * in_w)];
                for (int oy = 0; oy < in_h; oy++) {
                    int iy = oy + ky - 1;
                    if (iy < 0 || iy >= in_h) {
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
                        for (int ox = 0; ox < in_w; ox++) {
                            int ix = ox + kx - 1;
                            if (ix < 0 || ix >= in_w) {
                                dst[oy * in_w + ox] = 0;
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

static void init_conv_weights(void) {
    for (int oc = 0; oc < CONV1_OUT_C; oc++) {
        int8_t* dst = &conv1_weight_reorder[oc * 9 * INPUT_C];
        for (int ic = 0; ic < INPUT_C; ic++) {
            const int8_t* src = &conv1_weight[((oc * INPUT_C + ic) * 3) * 3];
            for (int i = 0; i < 9; i++)
                *dst++ = src[i];
        }
    }
    for (int oc = 0; oc < CONV2_OUT_C; oc++) {
        int8_t* dst = &conv2_weight_reorder[oc * 9 * CONV1_OUT_C];
        for (int ic = 0; ic < CONV1_OUT_C; ic++) {
            const int8_t* src = &conv2_weight[((oc * CONV1_OUT_C + ic) * 3) * 3];
            for (int i = 0; i < 9; i++)
                *dst++ = src[i];
        }
    }
}

static void conv3x3_matunit(
    const int8_t* input, int in_h, int in_w, int in_c,
    const int8_t* weight_reordered,
    int out_c,
    int8_t* output, int shift
) {
    int col_size = 9 * in_c * in_h * in_w;
    int8_t col_buf[col_size] __attribute__((aligned(64)));

    im2col_3x3(input, in_h, in_w, in_c, col_buf);

    int32_t gemm_result[out_c * in_h * in_w] __attribute__((aligned(64)));

    gemm_matunit(weight_reordered, out_c, 9 * in_c,
                 col_buf, in_h * in_w,
                 gemm_result);

    for (int oy = 0; oy < in_h; oy++) {
        for (int ox = 0; ox < in_w; ox++) {
            int spatial_idx = oy * in_w + ox;
            for (int oc = 0; oc < out_c; oc++) {
                int gemm_idx = oc * (in_h * in_w) + spatial_idx;
                int out_idx = spatial_idx * out_c + oc;
                output[out_idx] = saturate_int32_to_int8(gemm_result[gemm_idx] >> shift);
            }
        }
    }
}

static void relu_int8_inplace(int8_t* data, int size) {
    int8_t* ptr = data;
    size_t n = size;
    while (n > 0) {
        size_t vl = __riscv_vsetvl_e8m8(n);
        vint8m8_t v_data = __riscv_vle8_v_i8m8(ptr, vl);
        vint8m8_t v_relu = __riscv_vmax_vx_i8m8(v_data, 0, vl);
        __riscv_vse8_v_i8m8(ptr, v_relu, vl);
        ptr += vl;
        n -= vl;
    }
}

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
            const int8_t* in00 = &input[(iy * in_w + ix) * c];
            const int8_t* in01 = &input[(iy * in_w + (ix + 1)) * c];
            const int8_t* in10 = &input[((iy + 1) * in_w + ix) * c];
            const int8_t* in11 = &input[((iy + 1) * in_w + (ix + 1)) * c];
            int8_t* out_ptr = &output[(oy * out_w + ox) * c];
            size_t n = c;
            while (n > 0) {
                size_t vl = __riscv_vsetvl_e8m1(n);
                vint8m1_t v00 = __riscv_vle8_v_i8m1(in00, vl);
                vint8m1_t v01 = __riscv_vle8_v_i8m1(in01, vl);
                vint8m1_t v10 = __riscv_vle8_v_i8m1(in10, vl);
                vint8m1_t v11 = __riscv_vle8_v_i8m1(in11, vl);
                vint8m1_t v_max01 = __riscv_vmax_vv_i8m1(v00, v01, vl);
                vint8m1_t v_max23 = __riscv_vmax_vv_i8m1(v10, v11, vl);
                vint8m1_t v_max = __riscv_vmax_vv_i8m1(v_max01, v_max23, vl);
                __riscv_vse8_v_i8m1(out_ptr, v_max, vl);
                in00 += vl; in01 += vl; in10 += vl; in11 += vl;
                out_ptr += vl;
                n -= vl;
            }
        }
    }
}

static void fc_matunit(
    const int8_t* input, int in_features,
    const int8_t* weight, int out_features,
    int8_t* output, int shift
) {
    int32_t gemm_result[out_features] __attribute__((aligned(64)));
    gemm_matunit(weight, out_features, in_features,
                 input, 1,
                 gemm_result);
    for (int o = 0; o < out_features; o++)
        output[o] = saturate_int32_to_int8(gemm_result[o] >> shift);
}

static void fc_matunit_to_int32(
    const int8_t* input, int in_features,
    const int8_t* weight, int out_features,
    int32_t* output
) {
    gemm_matunit(weight, out_features, in_features,
                 input, 1,
                 output);
}

static void hwc_to_chw(const int8_t* hwc, int h, int w, int c, int8_t* chw) {
    for (int ch = 0; ch < c; ch++) {
        int8_t* chw_channel = &chw[ch * h * w];
        for (int y = 0; y < h; y++) {
            const int8_t* hwc_row = &hwc[y * w * c + ch];
            int8_t* chw_row = &chw_channel[y * w];
            for (int x = 0; x < w; x++)
                chw_row[x] = hwc_row[x * c];
        }
    }
}

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

static int forward(const int8_t* input) {
    conv3x3_matunit(input, INPUT_H, INPUT_W, INPUT_C,
                    conv1_weight_reorder, CONV1_OUT_C,
                    conv1_out, 7);
    relu_int8_inplace(conv1_out, 28 * 28 * CONV1_OUT_C);
    maxpool2x2_int8(conv1_out, 28, 28, CONV1_OUT_C, pool1_out);

    conv3x3_matunit(pool1_out, POOL1_OUT_H, POOL1_OUT_W, CONV1_OUT_C,
                    conv2_weight_reorder, CONV2_OUT_C,
                    conv2_out, 7);
    relu_int8_inplace(conv2_out, 14 * 14 * CONV2_OUT_C);
    maxpool2x2_int8(conv2_out, 14, 14, CONV2_OUT_C, pool2_out);

    hwc_to_chw(pool2_out, 7, 7, CONV2_OUT_C, flatten_buf);

    fc_matunit(flatten_buf, FC1_IN, fc1_weight, FC1_OUT, fc1_out, 8);
    relu_int8_inplace(fc1_out, FC1_OUT);

    fc_matunit(fc1_out, FC1_OUT, fc2_weight, FC2_OUT, fc2_out, 7);
    relu_int8_inplace(fc2_out, FC2_OUT);

    fc_matunit_to_int32(fc2_out, FC2_OUT, fc3_weight, FC3_OUT, (int32_t*)output_logits);

    return argmax_int32((int32_t*)output_logits, FC3_OUT);
}

int main(void) {
    init_conv_weights();

    const int8_t* input = test_sample_0;

    int pred = forward(input);

    result[0] = pred;

    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);

    return 0;
}
