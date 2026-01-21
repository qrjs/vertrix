// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

// 测试数据
volatile uint32_t result[8] __attribute__((aligned(4))) = {0};

const uint32_t expected[8] __attribute__((aligned(4))) = {
    0xF0,       // and: 0xFF & 0xF0
    0xFF,       // or:  0xFF | 0xF0
    0x0F,       // xor: 0xFF ^ 0xF0
    0xFFFFFF00, // not: ~0xFF
    1,          // slt: 10 < 20
    0,          // slt: 20 < 10
    1,          // sltu: 10 < 20 (unsigned)
    0xAA        // complex: (0xFF & 0xAA) | 0x00
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 32\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 32\n");

int main(void) {
    uint32_t a = 0xFF;
    uint32_t b = 0xF0;
    uint32_t c = 0xAA;
    int32_t d = 10;
    int32_t e = 20;
    
    // 位运算
    result[0] = a & b;          // AND
    result[1] = a | b;          // OR
    result[2] = a ^ b;          // XOR
    result[3] = ~a;             // NOT
    
    // 比较运算
    result[4] = (d < e) ? 1 : 0;    // SLT (小于)
    result[5] = (e < d) ? 1 : 0;    // SLT (不小于)
    result[6] = ((uint32_t)d < (uint32_t)e) ? 1 : 0; // SLTU
    
    // 复合运算
    result[7] = (a & c) | 0x00;
    
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    return 0;
}
