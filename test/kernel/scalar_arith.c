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
    15,     // add: 10 + 5
    5,      // sub: 10 - 5
    50,     // mul: 10 * 5
    -25,    // neg: -25
    100,    // sll: 25 << 2
    6,      // srl: 25 >> 2
    -7,     // sra: -25 >> 2
    42      // complex: (10 + 5) * 2 + 12
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 32\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 32\n");

int main(void) {
    int32_t a = 10;
    int32_t b = 5;
    int32_t c = 25;
    int32_t d = -25;
    
    // 基本算术运算
    result[0] = a + b;          // 加法
    result[1] = a - b;          // 减法
    result[2] = a * b;          // 乘法
    result[3] = -c;             // 取负
    
    // 位移操作
    result[4] = c << 2;         // 逻辑左移
    result[5] = c >> 2;         // 逻辑右移
    result[6] = d >> 2;         // 算术右移
    
    // 复合运算
    result[7] = (a + b) * 2 + 12;
    
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    return 0;
}
