#ifndef BROWSER_LLM_KERNELS_H
#define BROWSER_LLM_KERNELS_H

#include <stddef.h>
#include <stdint.h>

void browser_unpack_weights(const uint8_t *weights, uint32_t type, size_t count, float *output);
void browser_quantize_input(const float *input, size_t columns, int8_t *values, float *scales);
void browser_quantized_matvec(const uint8_t *weights, uint32_t type, size_t columns,
                              size_t rows, const int8_t *input, const float *scales, float *output);

#endif
