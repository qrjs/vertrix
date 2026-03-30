#ifndef MNIST_FP32_SCALAR_H
#define MNIST_FP32_SCALAR_H

static inline float mnist_fp32_mul_add(float acc, float lhs, float rhs) {
    return acc + lhs * rhs;
}

static inline void conv3x3_fp32(
    const float *input, int in_h, int in_w, int in_c,
    const float *weight, int out_c,
    float *output
) {
    for (int oy = 0; oy < in_h; ++oy) {
        for (int ox = 0; ox < in_w; ++ox) {
            for (int oc = 0; oc < out_c; ++oc) {
                float acc = 0.0f;
                for (int ky = 0; ky < 3; ++ky) {
                    int iy = oy + ky - 1;
                    if (iy < 0 || iy >= in_h) {
                        continue;
                    }
                    for (int kx = 0; kx < 3; ++kx) {
                        int ix = ox + kx - 1;
                        if (ix < 0 || ix >= in_w) {
                            continue;
                        }
                        for (int ic = 0; ic < in_c; ++ic) {
                            int input_idx = (iy * in_w + ix) * in_c + ic;
                            int weight_idx = ((oc * in_c + ic) * 3 + ky) * 3 + kx;
                            acc = mnist_fp32_mul_add(acc, input[input_idx], weight[weight_idx]);
                        }
                    }
                }
                output[(oy * in_w + ox) * out_c + oc] = acc;
            }
        }
    }
}

static inline void relu_fp32_inplace(float *data, int size) {
    for (int i = 0; i < size; ++i) {
        if (data[i] < 0.0f) {
            data[i] = 0.0f;
        }
    }
}

static inline void maxpool2x2_fp32(
    const float *input, int in_h, int in_w, int c,
    float *output
) {
    int out_h = in_h / 2;
    int out_w = in_w / 2;

    for (int oy = 0; oy < out_h; ++oy) {
        for (int ox = 0; ox < out_w; ++ox) {
            int iy = oy * 2;
            int ix = ox * 2;
            for (int ch = 0; ch < c; ++ch) {
                float vmax = input[(iy * in_w + ix) * c + ch];
                float v01 = input[(iy * in_w + (ix + 1)) * c + ch];
                float v10 = input[((iy + 1) * in_w + ix) * c + ch];
                float v11 = input[((iy + 1) * in_w + (ix + 1)) * c + ch];
                if (v01 > vmax) vmax = v01;
                if (v10 > vmax) vmax = v10;
                if (v11 > vmax) vmax = v11;
                output[(oy * out_w + ox) * c + ch] = vmax;
            }
        }
    }
}

static inline void hwc_to_chw_fp32(const float *hwc, int h, int w, int c, float *chw) {
    for (int ch = 0; ch < c; ++ch) {
        for (int y = 0; y < h; ++y) {
            for (int x = 0; x < w; ++x) {
                int hwc_idx = (y * w + x) * c + ch;
                int chw_idx = (ch * h + y) * w + x;
                chw[chw_idx] = hwc[hwc_idx];
            }
        }
    }
}

static inline void fc_fp32(
    const float *input, int in_features,
    const float *weight, int out_features,
    float *output
) {
    for (int o = 0; o < out_features; ++o) {
        const float *w_row = weight + o * in_features;
#ifdef MNIST_FP32_USE_VFDOT
        extern void vfdot_vl1_store(float *dst, const float *lhs, const float *rhs, int count);
        vfdot_vl1_store(&output[o], input, w_row, in_features);
#else
        float acc = 0.0f;
        for (int i = 0; i < in_features; ++i) {
            acc = mnist_fp32_mul_add(acc, input[i], w_row[i]);
        }
        output[o] = acc;
#endif
    }
}

static inline int argmax_fp32(const float *data, int size) {
    int max_idx = 0;
    for (int i = 1; i < size; ++i) {
        if (data[i] > data[max_idx]) {
            max_idx = i;
        }
    }
    return max_idx;
}

#endif
