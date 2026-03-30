// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>

extern void spill_cache(uint32_t *start, uint32_t *end);

#define VOCAB_SIZE  6
#define DIM         8
#define HIDDEN_DIM  12
#define N_LAYERS    1
#define N_HEADS     2
#define HEAD_SIZE   (DIM / N_HEADS)
#define PROMPT_LEN  3

typedef struct {
    float token_embedding[VOCAB_SIZE][DIM];
    float rms_att_weight[N_LAYERS][DIM];
    float rms_ffn_weight[N_LAYERS][DIM];
    float rms_final_weight[DIM];
    float wq[N_LAYERS][DIM][DIM];
    float wk[N_LAYERS][DIM][DIM];
    float wv[N_LAYERS][DIM][DIM];
    float wo[N_LAYERS][DIM][DIM];
    float w1[N_LAYERS][HIDDEN_DIM][DIM];
    float w2[N_LAYERS][DIM][HIDDEN_DIM];
    float w3[N_LAYERS][HIDDEN_DIM][DIM];
    float wcls[VOCAB_SIZE][DIM];
} TinyWeights;

static const int32_t prompt_tokens[PROMPT_LEN] __attribute__((used, aligned(4))) = {1, 4, 2};
static const int32_t expected[4] __attribute__((used, aligned(4))) = {
    5, 1085218953, 1529, 15889
};
volatile int32_t result[4] __attribute__((aligned(16))) = {0, 0, 0, 0};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 16\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 16\n");

static float maxf(float a, float b) {
    return a > b ? a : b;
}

static float inv_sqrt_approx(float x) {
    union {
        float f;
        uint32_t u;
    } v;
    float half = 0.5f * x;

    v.f = x;
    v.u = 0x5f3759dfu - (v.u >> 1);
    v.f = v.f * (1.5f - half * v.f * v.f);
    v.f = v.f * (1.5f - half * v.f * v.f);
    return v.f;
}

static float exp_approx(float x) {
    float y = x;
    float y2;
    float y3;
    float y4;

    if (y < -3.0f) y = -3.0f;
    if (y > 3.0f) y = 3.0f;
    y2 = y * y;
    y3 = y2 * y;
    y4 = y2 * y2;
    return 1.0f + y + 0.5f * y2 + (1.0f / 6.0f) * y3 + (1.0f / 24.0f) * y4;
}

static float sigmoid_approx(float x) {
    return 1.0f / (1.0f + exp_approx(-x));
}

static float silu_approx(float x) {
    return x * sigmoid_approx(x);
}

static int32_t round_to_i32(float x) {
    return (int32_t)(x >= 0.0f ? x + 0.5f : x - 0.5f);
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

static void matmul(float *out, const float *x, const float *w, int rows, int cols) {
    for (int i = 0; i < rows; ++i) {
        float sum = 0.0f;
        for (int j = 0; j < cols; ++j) {
            sum += w[i * cols + j] * x[j];
        }
        out[i] = sum;
    }
}

static void rmsnorm(float *out, const float *x, const float *weight, int n) {
    float ss = 0.0f;
    float scale;

    for (int i = 0; i < n; ++i) {
        ss += x[i] * x[i];
    }
    ss = ss / (float)n + 1.0e-5f;
    scale = inv_sqrt_approx(ss);

    for (int i = 0; i < n; ++i) {
        out[i] = weight[i] * (x[i] * scale);
    }
}

static void softmax_inplace(float *x, int n) {
    float max_val = x[0];
    float sum = 0.0f;

    for (int i = 1; i < n; ++i) {
        max_val = maxf(max_val, x[i]);
    }
    for (int i = 0; i < n; ++i) {
        x[i] = exp_approx(x[i] - max_val);
        sum += x[i];
    }
    for (int i = 0; i < n; ++i) {
        x[i] = x[i] / sum;
    }
}

static void apply_rope(float *q, float *k, int pos) {
    static const float rope_cos[PROMPT_LEN][HEAD_SIZE / 2] = {
        {1.0000000f, 1.0000000f},
        {0.8750000f, 0.9921875f},
        {0.5312500f, 0.9687500f},
    };
    static const float rope_sin[PROMPT_LEN][HEAD_SIZE / 2] = {
        {0.0000000f, 0.0000000f},
        {0.4843750f, 0.1250000f},
        {0.8359375f, 0.2500000f},
    };

    for (int h = 0; h < N_HEADS; ++h) {
        float *q_head = q + h * HEAD_SIZE;
        float *k_head = k + h * HEAD_SIZE;

        for (int i = 0; i < HEAD_SIZE; i += 2) {
            float qc = q_head[i];
            float qd = q_head[i + 1];
            float kc = k_head[i];
            float kd = k_head[i + 1];
            float c = rope_cos[pos][i / 2];
            float s = rope_sin[pos][i / 2];

            q_head[i]     = qc * c - qd * s;
            q_head[i + 1] = qc * s + qd * c;
            k_head[i]     = kc * c - kd * s;
            k_head[i + 1] = kc * s + kd * c;
        }
    }
}

static float embed_value(int token, int i) {
    return 0.12f * (float)(token - 2) + 0.035f * (float)(i - 3);
}

static float norm_weight_value(int layer, int i, int bias) {
    return 1.0f + 0.02f * (float)(layer + bias) - 0.005f * (float)(i & 3);
}

static float square_weight_value(int row, int col, int salt) {
    int mix = (row + 1) * (salt + 3) - (col + 2) * (salt + 1);
    int skew = ((row ^ col ^ salt) & 3) - 1;
    return 0.018f * (float)mix + 0.0075f * (float)skew;
}

static float hidden_weight_value(int row, int col, int salt) {
    int mix = (row + 2) * (salt + 5) - (col + 1) * (salt + 2);
    int skew = ((row + 2 * col + salt) & 7) - 3;
    return 0.013f * (float)mix + 0.0045f * (float)skew;
}

static void init_weights(TinyWeights *w) {
    for (int tok = 0; tok < VOCAB_SIZE; ++tok) {
        for (int i = 0; i < DIM; ++i) {
            w->token_embedding[tok][i] = embed_value(tok, i);
            w->rms_final_weight[i] = norm_weight_value(0, i, 2);
            w->wcls[tok][i] = 0.021f * (float)((tok + 1) * 2 - i) +
                              0.008f * (float)(((tok + i) & 3) - 1);
        }
    }

    for (int l = 0; l < N_LAYERS; ++l) {
        for (int i = 0; i < DIM; ++i) {
            w->rms_att_weight[l][i] = norm_weight_value(l, i, 0);
            w->rms_ffn_weight[l][i] = norm_weight_value(l, i, 1);
        }

        for (int row = 0; row < DIM; ++row) {
            for (int col = 0; col < DIM; ++col) {
                w->wq[l][row][col] = square_weight_value(row, col, 1);
                w->wk[l][row][col] = square_weight_value(row, col, 2);
                w->wv[l][row][col] = square_weight_value(row, col, 3);
                w->wo[l][row][col] = square_weight_value(row, col, 4);
            }
        }

        for (int row = 0; row < HIDDEN_DIM; ++row) {
            for (int col = 0; col < DIM; ++col) {
                w->w1[l][row][col] = hidden_weight_value(row, col, 5);
                w->w3[l][row][col] = hidden_weight_value(row, col, 6);
            }
        }

        for (int row = 0; row < DIM; ++row) {
            for (int col = 0; col < HIDDEN_DIM; ++col) {
                w->w2[l][row][col] = hidden_weight_value(row, col, 7);
            }
        }
    }
}

static void forward_next_token(const TinyWeights *w, int *pred_token, int32_t *scaled_logits) {
    float x[DIM];
    float xb[DIM];
    float q[DIM];
    float k[DIM];
    float v[DIM];
    float att[DIM];
    float scores[PROMPT_LEN];
    float probs[PROMPT_LEN];
    float hb[HIDDEN_DIM];
    float hb2[HIDDEN_DIM];
    float logits[VOCAB_SIZE];
    float key_cache[N_LAYERS][PROMPT_LEN][DIM];
    float value_cache[N_LAYERS][PROMPT_LEN][DIM];

    for (int pos = 0; pos < PROMPT_LEN; ++pos) {
        for (int i = 0; i < DIM; ++i) {
            x[i] = w->token_embedding[prompt_tokens[pos]][i];
        }

        for (int l = 0; l < N_LAYERS; ++l) {
            rmsnorm(xb, x, w->rms_att_weight[l], DIM);
            matmul(q, xb, &w->wq[l][0][0], DIM, DIM);
            matmul(k, xb, &w->wk[l][0][0], DIM, DIM);
            matmul(v, xb, &w->wv[l][0][0], DIM, DIM);
            apply_rope(q, k, pos);

            for (int i = 0; i < DIM; ++i) {
                key_cache[l][pos][i] = k[i];
                value_cache[l][pos][i] = v[i];
                att[i] = 0.0f;
            }

            for (int h = 0; h < N_HEADS; ++h) {
                const float *q_head = &q[h * HEAD_SIZE];

                for (int t = 0; t <= pos; ++t) {
                    const float *k_head = &key_cache[l][t][h * HEAD_SIZE];
                    float score = 0.0f;
                    for (int i = 0; i < HEAD_SIZE; ++i) {
                        score += q_head[i] * k_head[i];
                    }
                    scores[t] = score * 0.5f;
                    probs[t] = scores[t];
                }

                softmax_inplace(probs, pos + 1);

                for (int i = 0; i < HEAD_SIZE; ++i) {
                    float sum = 0.0f;
                    for (int t = 0; t <= pos; ++t) {
                        const float *v_head = &value_cache[l][t][h * HEAD_SIZE];
                        sum += probs[t] * v_head[i];
                    }
                    att[h * HEAD_SIZE + i] = sum;
                }
            }

            matmul(xb, att, &w->wo[l][0][0], DIM, DIM);
            for (int i = 0; i < DIM; ++i) {
                x[i] += xb[i];
            }

            rmsnorm(xb, x, w->rms_ffn_weight[l], DIM);
            matmul(hb, xb, &w->w1[l][0][0], HIDDEN_DIM, DIM);
            matmul(hb2, xb, &w->w3[l][0][0], HIDDEN_DIM, DIM);
            for (int i = 0; i < HIDDEN_DIM; ++i) {
                hb[i] = silu_approx(hb[i]) * hb2[i];
            }
            matmul(xb, hb, &w->w2[l][0][0], DIM, HIDDEN_DIM);
            for (int i = 0; i < DIM; ++i) {
                x[i] += xb[i];
            }
        }
    }

    rmsnorm(xb, x, w->rms_final_weight, DIM);
    matmul(logits, xb, &w->wcls[0][0], VOCAB_SIZE, DIM);

    for (int i = 0; i < VOCAB_SIZE; ++i) {
        scaled_logits[i] = round_to_i32(logits[i] * 4096.0f);
    }
    *pred_token = argmax_i32(scaled_logits, VOCAB_SIZE);
}

#ifdef HOST_TEST
#include <stdio.h>
int main(void) {
    TinyWeights weights;
    int32_t logits[VOCAB_SIZE];
    int pred;
    int32_t checksum = 0;

    init_weights(&weights);
    forward_next_token(&weights, &pred, logits);
    for (int i = 0; i < VOCAB_SIZE; ++i) {
        checksum = checksum * 131 + logits[i];
    }

    printf("pred=%d\n", pred);
    printf("logits:");
    for (int i = 0; i < VOCAB_SIZE; ++i) {
        printf(" %d", logits[i]);
    }
    printf("\nchecksum=%d\n", checksum);
    return 0;
}
#else
int main(void) {
    TinyWeights weights;
    int32_t logits[VOCAB_SIZE];
    int pred;
    int32_t checksum = 0;
    int32_t l1_norm = 0;

    init_weights(&weights);
    forward_next_token(&weights, &pred, logits);

    for (int i = 0; i < VOCAB_SIZE; ++i) {
        checksum = checksum * 131 + logits[i];
        l1_norm += logits[i] < 0 ? -logits[i] : logits[i];
    }

    result[0] = pred;
    result[1] = checksum;
    result[2] = logits[2];
    result[3] = l1_norm;

    spill_cache((uint32_t *)result, (uint32_t *)(result + 4));
    return 0;
}
#endif
