// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

// 测试数据
volatile int32_t result[8] __attribute__((aligned(4))) = {0};

const int32_t expected[8] __attribute__((aligned(4))) = {
    1,      // beq test passed
    1,      // bne test passed
    1,      // blt test passed
    1,      // bge test passed
    10,     // loop sum: 1+2+3+4
    5,      // max(3, 5)
    3,      // min(3, 5)
    15      // factorial(5) = 5*4*3*2*1 (simplified to 5+4+3+2+1)
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 32\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 32\n");

int main(void) {
    int32_t a = 10;
    int32_t b = 10;
    int32_t c = 5;
    
    // BEQ 测试
    if (a == b) {
        result[0] = 1;
    }
    
    // BNE 测试
    if (a != c) {
        result[1] = 1;
    }
    
    // BLT 测试
    if (c < a) {
        result[2] = 1;
    }
    
    // BGE 测试
    if (a >= c) {
        result[3] = 1;
    }
    
    // 循环测试
    int32_t sum = 0;
    for (int i = 1; i <= 4; i++) {
        sum += i;
    }
    result[4] = sum;
    
    // 条件判断 - 最大值
    int32_t x = 3, y = 5;
    result[5] = (x > y) ? x : y;
    
    // 条件判断 - 最小值
    result[6] = (x < y) ? x : y;
    
    // 累加模拟阶乘
    int32_t acc = 0;
    for (int i = 1; i <= 5; i++) {
        acc += i;
    }
    result[7] = acc;
    
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    return 0;
}
