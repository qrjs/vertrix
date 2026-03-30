// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>
#include <riscv_vector.h>

extern void spill_cache(uint32_t *start, uint32_t *end);

#define VOCAB_SIZE 5
#define DIM        8
#define HIDDEN_DIM 12
#define PROMPT_LEN 2

typedef int8_t (*weight_fn_t)(int o, int i);

static const int32_t prompt_tokens[PROMPT_LEN] __attribute__((used, aligned(8))) = {1, 3};
static const int32_t expected[1] __attribute__((used, aligned(4))) = {1};
volatile int32_t result[4] __attribute__((aligned(16))) = {0, 0, 0, 0};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

static inline int8_t sat_i8(int32_t x) {
    if (x > 127) return 127;
    if (x < -128) return -128;
    return (int8_t)x;
}

static void copy_i8(int8_t *dst, const int8_t *src, int n) {
    for (int i = 0; i < n; ++i) {
        dst[i] = src[i];
    }
}

static int8_t token_embedding_value(int token, int d) {
    return (int8_t)((token + 1) * 5 - d * 2 - 6);
}

static int8_t wq_value(int o, int i) {
    return (int8_t)((o == i ? 6 : 0) + o - i - 1);
}

static int8_t wk_value(int o, int i) {
    return (int8_t)((o == i ? 5 : 0) + i - o);
}

static int8_t wv_value(int o, int i) {
    return (int8_t)((o == i ? 4 : 0) + ((o + i) & 3) - 1);
}

static int8_t wo_value(int o, int i) {
    return (int8_t)((o == i ? 5 : 0) + 1 - ((o + 2 * i) & 3));
}

static int8_t w1_value(int o, int i) {
    return (int8_t)((o + 1) - (i >> 1) - 2);
}

static int8_t w2_value(int o, int i) {
    return (int8_t)(((i + 1) >> 1) - o);
}

static int8_t wcls_value(int o, int i) {
    int8_t bonus = (o == 2) ? 3 : 0;
    return (int8_t)(2 * (o + 1) - i + bonus);
}

static void load_token_embedding(int8_t *dst, int token) {
    for (int i = 0; i < DIM; ++i) {
        dst[i] = token_embedding_value(token, i);
    }
}

static int32_t dot_scalar_i8(const int8_t *a, const int8_t *b, int n) {
    int32_t sum = 0;
    for (int i = 0; i < n; ++i) {
        sum += (int32_t)a[i] * (int32_t)b[i];
    }
    return sum;
}

static int32_t dot_vector_i8(const int8_t *a, const int8_t *b, int n) {
    size_t vl1 = __riscv_vsetvl_e32m1(1);
    vint32m1_t acc = __riscv_vmv_v_x_i32m1(0, vl1);

    for (int i = 0; i < n; ) {
        size_t vl = __riscv_vsetvl_e8m2(n - i);
        vint8m2_t va = __riscv_vle8_v_i8m2(&a[i], vl);
        vint8m2_t vb = __riscv_vle8_v_i8m2(&b[i], vl);
        vint16m4_t vprod = __riscv_vwmul_vv_i16m4(va, vb, vl);
        acc = __riscv_vwredsum_vs_i16m4_i32m1(vprod, acc, vl);
        i += vl;
    }

    return __riscv_vmv_x_s_i32m1_i32(acc);
}

static void linear_i8_scalar(int8_t *out, int out_dim, const int8_t *in, int in_dim,
                             weight_fn_t weight_fn, int shift) {
    int8_t row[HIDDEN_DIM];

    for (int o = 0; o < out_dim; ++o) {
        for (int i = 0; i < in_dim; ++i) {
            row[i] = weight_fn(o, i);
        }
        out[o] = sat_i8(dot_scalar_i8(row, in, in_dim) >> shift);
    }
}

static void linear_i8_vector(int8_t *out, int out_dim, const int8_t *in, int in_dim,
                             weight_fn_t weight_fn, int shift) {
    int8_t row[HIDDEN_DIM];

    for (int o = 0; o < out_dim; ++o) {
        for (int i = 0; i < in_dim; ++i) {
            row[i] = weight_fn(o, i);
        }
        out[o] = sat_i8(dot_vector_i8(row, in, in_dim) >> shift);
    }
}

static void linear_i32_scalar(int32_t *out, int out_dim, const int8_t *in, int in_dim,
                              weight_fn_t weight_fn) {
    int8_t row[HIDDEN_DIM];

    for (int o = 0; o < out_dim; ++o) {
        for (int i = 0; i < in_dim; ++i) {
            row[i] = weight_fn(o, i);
        }
        out[o] = dot_scalar_i8(row, in, in_dim);
    }
}

static void linear_i32_vector(int32_t *out, int out_dim, const int8_t *in, int in_dim,
                              weight_fn_t weight_fn) {
    int8_t row[HIDDEN_DIM];

    for (int o = 0; o < out_dim; ++o) {
        for (int i = 0; i < in_dim; ++i) {
            row[i] = weight_fn(o, i);
        }
        out[o] = dot_vector_i8(row, in, in_dim);
    }
}

static int argmax_i32(const int32_t *x, int n) {
    int best_idx = 0;
    int32_t best_val = x[0];

    for (int i = 1; i < n; ++i) {
        if (x[i] > best_val) {
            best_val = x[i];
            best_idx = i;
        }
    }
    return best_idx;
}

static void relu_i8_inplace(int8_t *x, int n) {
    for (int i = 0; i < n; ++i) {
        if (x[i] < 0) x[i] = 0;
    }
}

static void tiny_transformer_scalar(int *pred_token, int32_t *logits_out) {
    int8_t k_cache[PROMPT_LEN][DIM];
    int8_t v_cache[PROMPT_LEN][DIM];
    int8_t x[DIM];
    int8_t q[DIM];
    int8_t k[DIM];
    int8_t v[DIM];
    int8_t context[DIM];
    int8_t attn_out[DIM];
    int8_t hidden[HIDDEN_DIM];
    int8_t ff_out[DIM];
    int32_t scores[PROMPT_LEN];

    for (int t = 0; t < PROMPT_LEN; ++t) {
        load_token_embedding(x, prompt_tokens[t]);

        linear_i8_scalar(q, DIM, x, DIM, wq_value, 3);
        linear_i8_scalar(k, DIM, x, DIM, wk_value, 3);
        linear_i8_scalar(v, DIM, x, DIM, wv_value, 3);

        copy_i8(k_cache[t], k, DIM);
        copy_i8(v_cache[t], v, DIM);

        int best_idx = 0;
        scores[0] = dot_scalar_i8(q, k_cache[0], DIM);
        for (int j = 1; j <= t; ++j) {
            scores[j] = dot_scalar_i8(q, k_cache[j], DIM);
            if (scores[j] > scores[best_idx]) {
                best_idx = j;
            }
        }

        copy_i8(context, v_cache[best_idx], DIM);
        linear_i8_scalar(attn_out, DIM, context, DIM, wo_value, 2);

        for (int i = 0; i < DIM; ++i) {
            x[i] = sat_i8((int32_t)x[i] + (int32_t)attn_out[i]);
        }

        linear_i8_scalar(hidden, HIDDEN_DIM, x, DIM, w1_value, 3);
        relu_i8_inplace(hidden, HIDDEN_DIM);
        linear_i8_scalar(ff_out, DIM, hidden, HIDDEN_DIM, w2_value, 3);

        for (int i = 0; i < DIM; ++i) {
            x[i] = sat_i8((int32_t)x[i] + (int32_t)ff_out[i]);
        }
    }

    linear_i32_scalar(logits_out, VOCAB_SIZE, x, DIM, wcls_value);
    *pred_token = argmax_i32(logits_out, VOCAB_SIZE);
}

static void tiny_transformer_vector(int *pred_token, int32_t *logits_out) {
    int8_t k_cache[PROMPT_LEN][DIM];
    int8_t v_cache[PROMPT_LEN][DIM];
    int8_t x[DIM];
    int8_t q[DIM];
    int8_t k[DIM];
    int8_t v[DIM];
    int8_t context[DIM];
    int8_t attn_out[DIM];
    int8_t hidden[HIDDEN_DIM];
    int8_t ff_out[DIM];
    int32_t scores[PROMPT_LEN];

    for (int t = 0; t < PROMPT_LEN; ++t) {
        load_token_embedding(x, prompt_tokens[t]);

        linear_i8_vector(q, DIM, x, DIM, wq_value, 3);
        linear_i8_vector(k, DIM, x, DIM, wk_value, 3);
        linear_i8_vector(v, DIM, x, DIM, wv_value, 3);

        copy_i8(k_cache[t], k, DIM);
        copy_i8(v_cache[t], v, DIM);

        int best_idx = 0;
        scores[0] = dot_vector_i8(q, k_cache[0], DIM);
        for (int j = 1; j <= t; ++j) {
            scores[j] = dot_vector_i8(q, k_cache[j], DIM);
            if (scores[j] > scores[best_idx]) {
                best_idx = j;
            }
        }

        copy_i8(context, v_cache[best_idx], DIM);
        linear_i8_vector(attn_out, DIM, context, DIM, wo_value, 2);

        for (int i = 0; i < DIM; ++i) {
            x[i] = sat_i8((int32_t)x[i] + (int32_t)attn_out[i]);
        }

        linear_i8_vector(hidden, HIDDEN_DIM, x, DIM, w1_value, 3);
        relu_i8_inplace(hidden, HIDDEN_DIM);
        linear_i8_vector(ff_out, DIM, hidden, HIDDEN_DIM, w2_value, 3);

        for (int i = 0; i < DIM; ++i) {
            x[i] = sat_i8((int32_t)x[i] + (int32_t)ff_out[i]);
        }
    }

    linear_i32_vector(logits_out, VOCAB_SIZE, x, DIM, wcls_value);
    *pred_token = argmax_i32(logits_out, VOCAB_SIZE);
}

int main(void) {
    int32_t logits_scalar[VOCAB_SIZE];
    int32_t logits_vector[VOCAB_SIZE];
    int pred_scalar;
    int pred_vector;
    int ok = 1;
    int32_t checksum = 0;

    tiny_transformer_scalar(&pred_scalar, logits_scalar);
    tiny_transformer_vector(&pred_vector, logits_vector);

    if (pred_scalar != pred_vector) {
        ok = 0;
    }

    for (int i = 0; i < VOCAB_SIZE; ++i) {
        if (logits_scalar[i] != logits_vector[i]) {
            ok = 0;
        }
        checksum = checksum * 131 + logits_vector[i];
    }

    result[0] = ok;
    result[1] = pred_vector;
    result[2] = pred_scalar;
    result[3] = checksum;

    spill_cache((uint32_t *)result, (uint32_t *)(result + 4));
    return 0;
}
