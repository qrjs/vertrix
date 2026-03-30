// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>

extern void vfdot_vl1_store(float *dst, const float *lhs, const float *rhs, int count);

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

static const union {
    uint32_t u[4];
    float f[4];
} src_a = {.u = {
    0xbed93271u, 0xbed93271u, 0xbed93271u, 0xbed93271u,
}};

static const union {
    uint32_t u[4];
    float f[4];
} src_b = {.u = {
    0xbf20eb63u, 0xbdb1c556u, 0xbf0d61c8u, 0x3ea7597bu,
}};

volatile uint32_t result[1] __attribute__((aligned(4))) = {0};
const uint32_t expected[1] __attribute__((aligned(4))) = {0x3ecc577bu};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

int main(void) {
    vfdot_vl1_store((float *)result, src_a.f, src_b.f, 4);
    spill_cache((uint32_t *)result, (uint32_t *)(result + 1));
    return 0;
}
