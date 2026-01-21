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
    0x78,           // lb: byte load (sign-extended)
    0x5678,         // lh: halfword load (sign-extended)
    0x12345678,     // lw: word load
    0x00000012,     // lbu: unsigned byte load
    0x00001234,     // lhu: unsigned halfword load
    42,             // store then load
    55,             // array access
    100             // pointer arithmetic
};

// 源数据
const int32_t source_data[4] __attribute__((aligned(4))) = {
    0x12345678,     // 字节序: 78 56 34 12 (小端)
    42,
    55,
    100
};

asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 32\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 32\n");

int main(void) {
    volatile int8_t *byte_ptr = (int8_t *)&source_data[0];
    volatile int16_t *half_ptr = (int16_t *)&source_data[0];
    volatile int32_t *word_ptr = (int32_t *)&source_data[0];
    
    // 字节加载 (LB) - 加载最低字节 0x78
    result[0] = byte_ptr[0];
    
    // 半字加载 (LH) - 加载低半字 0x5678
    result[1] = half_ptr[0];
    
    // 字加载 (LW) - 加载完整字 0x12345678
    result[2] = word_ptr[0];
    
    // 无符号字节加载 (LBU) - 加载最高字节 0x12
    volatile uint8_t *ubyte_ptr = (uint8_t *)&source_data[0];
    result[3] = ubyte_ptr[3];
    
    // 无符号半字加载 (LHU) - 加载高半字 0x1234
    volatile uint16_t *uhalf_ptr = (uint16_t *)&source_data[0];
    result[4] = uhalf_ptr[1];
    
    // Store 后 Load
    result[5] = source_data[1];
    
    // 数组访问
    result[6] = source_data[2];
    
    // 指针运算
    result[7] = *(word_ptr + 3);
    
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    return 0;
}
