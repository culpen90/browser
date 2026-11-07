#include "BrowserLLMKernels.h"
#include <math.h>
#include <string.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

static inline float half_scale(const uint8_t *block) {
    uint16_t bits = (uint16_t)(block[0] | block[1] << 8);
    _Float16 value;
    memcpy(&value, &bits, sizeof(value));
    return (float)value;
}

enum {
    q6_block_values = 256,
    q6_group_values = 16,
    q6_low_bytes = 128,
    q6_scale_offset = 192,
    q6_super_scale_offset = 208,
    q6_block_bytes = 210,
};

typedef struct {
    const uint8_t *low;
    const uint8_t *high;
    unsigned low_shift;
    unsigned high_shift;
} Q6Group;

// Each Q6_K block packs two 128-value halves. Four logical 32-value
// quarters share the high bits of each half, with a scale per 16 values.
static inline Q6Group q6_group(const uint8_t *block, size_t group) {
    size_t half = group / 8;
    size_t quarter = group % 8 / 2;
    size_t lane_offset = (group % 2) * q6_group_values;
    return (Q6Group){
        .low = block + half * 64 + (quarter % 2) * 32 + lane_offset,
        .high = block + q6_low_bytes + half * 32 + lane_offset,
        .low_shift = (unsigned)(quarter / 2) * 4,
        .high_shift = (unsigned)quarter * 2,
    };
}

static inline int32_t q6_value(Q6Group group, size_t lane) {
    int32_t low = (group.low[lane] >> group.low_shift) & 15;
    int32_t high = (group.high[lane] >> group.high_shift) & 3;
    return low + 16 * high - 32;
}

static void unpack_q6_weights(const uint8_t *weights, size_t count, float *output) {
    for (size_t i = 0; i < count; i += q6_block_values, weights += q6_block_bytes) {
        float super_scale = half_scale(weights + q6_super_scale_offset);
        for (size_t index = 0; index < q6_block_values / q6_group_values; ++index) {
            Q6Group group = q6_group(weights, index);
            float scale = super_scale * (int8_t)weights[q6_scale_offset + index];
            for (size_t lane = 0; lane < q6_group_values; ++lane) {
                output[i + index * q6_group_values + lane] = scale * q6_value(group, lane);
            }
        }
    }
}

void browser_unpack_weights(const uint8_t *weights, uint32_t type, size_t count, float *output) {
    if (type == 0) {
        memcpy(output, weights, count * sizeof(float));
    } else if (type == 1) {
        for (size_t i = 0; i < count; ++i) {
            output[i] = half_scale(weights + 2 * i);
        }
    } else if (type == 14) {
        unpack_q6_weights(weights, count, output);
    } else {
        size_t block_bytes = type == 2 ? 18 : 34;
        for (size_t i = 0; i < count; i += 32, weights += block_bytes) {
            float scale = half_scale(weights);
            if (type == 2) {
                for (size_t j = 0; j < 16; ++j) {
                    output[i + j] = scale * ((weights[2 + j] & 15) - 8);
                    output[i + j + 16] = scale * ((weights[2 + j] >> 4) - 8);
                }
            } else {
                for (size_t j = 0; j < 32; ++j) {
                    output[i + j] = scale * (int8_t)weights[2 + j];
                }
            }
        }
    }
}

void browser_quantize_input(const float *input, size_t columns, int8_t *values, float *scales) {
    for (size_t i = 0; i < columns; i += 32) {
        float maximum = 0;
        for (size_t j = 0; j < 32; ++j) {
            maximum = fmaxf(maximum, fabsf(input[i + j]));
        }
        if (!isfinite(maximum) || maximum < 1e-30f) {
            scales[i / 32] = 0;
            memset(values + i, 0, 32);
            continue;
        }
        scales[i / 32] = maximum / 127;
        float multiplier = 127 / maximum;
        for (size_t j = 0; j < 32; ++j) {
            float scaled = input[i + j] * multiplier;
            values[i + j] = isfinite(scaled) ? (int8_t)roundf(scaled) : 0;
        }
    }
}

#if defined(__ARM_NEON)
static inline int32_t dot_pair(int8x16_t a, int8x16_t b, int8x16_t c, int8x16_t d) {
#if defined(__ARM_FEATURE_DOTPROD)
    return vaddvq_s32(vdotq_s32(vdotq_s32(vdupq_n_s32(0), a, b), c, d));
#else
    int32x4_t sum = vpaddlq_s16(vmull_s8(vget_low_s8(a), vget_low_s8(b)));
    sum = vpadalq_s16(sum, vmull_high_s8(a, b));
    sum = vpadalq_s16(sum, vmull_s8(vget_low_s8(c), vget_low_s8(d)));
    return vaddvq_s32(vpadalq_s16(sum, vmull_high_s8(c, d)));
#endif
}
#endif

static inline int32_t quantized_dot(const uint8_t *weights, uint32_t type, const int8_t *input) {
#if defined(__ARM_NEON)
    int8x16_t first, second;
    if (type == 2) {
        uint8x16_t packed = vld1q_u8(weights);
        int8x16_t zero_point = vdupq_n_s8(8);
        first = vsubq_s8(vreinterpretq_s8_u8(vandq_u8(packed, vdupq_n_u8(15))), zero_point);
        second = vsubq_s8(vreinterpretq_s8_u8(vshrq_n_u8(packed, 4)), zero_point);
    } else {
        first = vld1q_s8((const int8_t *)weights);
        second = vld1q_s8((const int8_t *)weights + 16);
    }
    return dot_pair(first, vld1q_s8(input), second, vld1q_s8(input + 16));
#else
    int32_t sum = 0;
    if (type == 2) {
        for (size_t i = 0; i < 16; ++i) {
            sum += ((weights[i] & 15) - 8) * input[i];
            sum += ((weights[i] >> 4) - 8) * input[i + 16];
        }
    } else {
        for (size_t i = 0; i < 32; ++i) {
            sum += (int8_t)weights[i] * input[i];
        }
    }
    return sum;
#endif
}

static inline int32_t q6_dot(Q6Group group, const int8_t *input) {
#if defined(__ARM_NEON)
    uint8x16_t low = vshlq_u8(vld1q_u8(group.low), vdupq_n_s8(-(int8_t)group.low_shift));
    uint8x16_t high = vshlq_u8(vld1q_u8(group.high), vdupq_n_s8(-(int8_t)group.high_shift));
    low = vandq_u8(low, vdupq_n_u8(15));
    high = vshlq_n_u8(vandq_u8(high, vdupq_n_u8(3)), 4);
    int8x16_t values = vsubq_s8(vreinterpretq_s8_u8(vorrq_u8(low, high)), vdupq_n_s8(32));
    int8x16_t activations = vld1q_s8(input);
#if defined(__ARM_FEATURE_DOTPROD)
    return vaddvq_s32(vdotq_s32(vdupq_n_s32(0), values, activations));
#else
    int32x4_t sum = vpaddlq_s16(vmull_s8(vget_low_s8(values), vget_low_s8(activations)));
    return vaddvq_s32(vpadalq_s16(sum, vmull_high_s8(values, activations)));
#endif
#else
    int32_t sum = 0;
    for (size_t lane = 0; lane < q6_group_values; ++lane) {
        sum += q6_value(group, lane) * input[lane];
    }
    return sum;
#endif
}

static void q6_matvec(const uint8_t *weights, size_t columns, size_t rows,
                      const int8_t *input, const float *scales, float *output) {
    for (size_t row = 0; row < rows; ++row) {
        float sum = 0;
        for (size_t i = 0; i < columns; i += q6_block_values, weights += q6_block_bytes) {
            float super_scale = half_scale(weights + q6_super_scale_offset);
            for (size_t index = 0; index < q6_block_values / q6_group_values; ++index) {
                size_t column = i + index * q6_group_values;
                float scale = super_scale * (int8_t)weights[q6_scale_offset + index];
                int32_t dot = q6_dot(q6_group(weights, index), input + column);
                sum += scale * scales[column / 32] * (float)dot;
            }
        }
        output[row] = sum;
    }
}

void browser_quantized_matvec(const uint8_t *weights, uint32_t type, size_t columns,
                              size_t rows, const int8_t *input, const float *scales, float *output) {
    if (type == 14) {
        q6_matvec(weights, columns, rows, input, scales, output);
        return;
    }
    size_t block_bytes = type == 2 ? 18 : 34;
    for (size_t row = 0; row < rows; ++row) {
        float sum = 0;
        for (size_t i = 0; i < columns; i += 32, weights += block_bytes) {
            sum += half_scale(weights) * scales[i / 32] * (float)quantized_dot(weights + 2, type, input + i);
        }
        output[row] = sum;
    }
}
