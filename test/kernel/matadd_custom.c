// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>

#define N 8

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

// 定义8x8矩阵A
const int8_t A[N][N] __attribute__((aligned(64))) = {
    {1, 2, 3, 4, 5, 6, 7, 8},
    {8, 7, 6, 5, 4, 3, 2, 1},
    {1, 1, 2, 2, 3, 3, 4, 4},
    {4, 4, 3, 3, 2, 2, 1, 1},
    {1, 0, 1, 0, 1, 0, 1, 0},
    {0, 1, 0, 1, 0, 1, 0, 1},
    {2, 2, 2, 2, 2, 2, 2, 2},
    {3, 3, 3, 3, 3, 3, 3, 3},
};

// 定义8x8矩阵B
const int8_t B[N][N] __attribute__((aligned(64))) = {
    {10, 20, 30, 40, 50, 60, 70, 80},
    {11, 12, 13, 14, 15, 16, 17, 18},
    { 5,  5,  5,  5,  5,  5,  5,  5},
    { 1,  2,  3,  4,  5,  6,  7,  8},
    { 9,  8,  7,  6,  5,  4,  3,  2},
    {10, 11, 12, 13, 14, 15, 16, 17},
    { 8,  8,  8,  8,  8,  8,  8,  8},
    { 7,  7,  7,  7,  7,  7,  7,  7},
};

// 输出矩阵C
volatile int8_t C[N][N] __attribute__((aligned(64)));

// 参考结果：C = A + B（逐元素相加）
const int8_t C_ref[N][N] __attribute__((aligned(64))) = {
    {11, 22, 33, 44, 55, 66, 77, 88},
    {19, 19, 19, 19, 19, 19, 19, 19},
    { 6,  6,  7,  7,  8,  8,  9,  9},
    { 5,  6,  6,  7,  7,  8,  8,  9},
    {10,  8,  8,  6,  6,  4,  4,  2},
    {10, 12, 12, 14, 14, 16, 16, 18},
    {10, 10, 10, 10, 10, 10, 10, 10},
    {10, 10, 10, 10, 10, 10, 10, 10},
};

asm(".global vref_start\n.set vref_start, C_ref\n");
asm(".global vref_end\n.set vref_end, C_ref + 64\n");
asm(".global vdata_start\n.set vdata_start, C\n");
asm(".global vdata_end\n.set vdata_end, C + 64\n");

// 内联汇编函数：使用自定义矩阵指令
// MVIN: 从内存加载矩阵到矩阵寄存器
static inline void mvin(int mat_reg, const void* addr) {
    register uint32_t a0 asm("x10") = (uint32_t)addr;
    register uint32_t a1 asm("x11") = 0;
    
    if (mat_reg == 1) {
        asm volatile(".insn r 0x0b, 0, 0, x1, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    } else if (mat_reg == 2) {
        asm volatile(".insn r 0x0b, 0, 0, x2, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    } else if (mat_reg == 3) {
        asm volatile(".insn r 0x0b, 0, 0, x3, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    }
}

// MVOUT: 从矩阵寄存器写回内存
static inline void mvout(int mat_reg, void* addr) {
    register uint32_t a0 asm("x10") = (uint32_t)addr;
    register uint32_t a1 asm("x11") = 0;
    
    if (mat_reg == 1) {
        asm volatile(".insn r 0x0b, 1, 0, x1, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    } else if (mat_reg == 2) {
        asm volatile(".insn r 0x0b, 1, 0, x2, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    } else if (mat_reg == 3) {
        asm volatile(".insn r 0x0b, 1, 0, x3, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    }
}

// MATADD: 矩阵加法 rd = rs1 + rs2 (逐元素相加)
static inline void matadd(int mat_rd, int mat_rs1, int mat_rs2) {
    register uint32_t a0 asm("x10") = mat_rs1;
    register uint32_t a1 asm("x11") = mat_rs2;
    
    if (mat_rd == 1) {
        asm volatile(".insn r 0x0b, 4, 0, x1, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    } else if (mat_rd == 2) {
        asm volatile(".insn r 0x0b, 4, 0, x2, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    } else if (mat_rd == 3) {
        asm volatile(".insn r 0x0b, 4, 0, x3, x10, x11" : : "r"(a0), "r"(a1) : "memory");
    }
}

int main(void) {
    // 使用自定义矩阵指令进行矩阵加法
    // 步骤：
    // 1. 将矩阵A加载到矩阵寄存器m1 (rd=1)
    // 2. 将矩阵B加载到矩阵寄存器m2 (rd=2)
    // 3. 执行矩阵加法 m3 = m1 + m2 (rd=3)
    // 4. 将结果m3写回到内存C
    
    mvin(1, A);           // m1 = A
    mvin(2, B);           // m2 = B
    matadd(3, 1, 2);      // m3 = m1 + m2
    mvout(3, (void*)C);   // C = m3
    
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    return 0;
}
