// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

static volatile float input_a[4] __attribute__((aligned(16))) = {
    1.5f, -2.25f, 3.75f, 0.5f
};
static volatile float input_b[4] __attribute__((aligned(16))) = {
    0.5f, 4.0f, -1.5f, 8.0f
};

volatile uint32_t result[4] __attribute__((used, aligned(16))) = {0, 0, 0, 0};
const uint32_t expected[4] __attribute__((used, aligned(16))) = {
    0x3f800000u, 0xbe800000u, 0x40280000u, 0xbf000000u
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 16\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 16\n");

static uint32_t as_u32(float value) {
    union {
        float f;
        uint32_t u;
    } bits;

    bits.f = value;
    return bits.u;
}

int main(void) {
    float tmp0 = input_a[0] * input_b[0] + 0.25f;
    float tmp1 = input_a[1] + input_b[1] * 0.5f;
    float tmp2 = (input_a[2] - input_b[2]) * 0.5f;
    float tmp3 = input_a[3] * 3.0f - input_b[3] * 0.25f;

    result[0] = as_u32(tmp0);
    result[1] = as_u32(tmp1);
    result[2] = as_u32(tmp2);
    result[3] = as_u32(tmp3);

    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    return 0;
}
