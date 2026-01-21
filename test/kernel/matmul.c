// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#include <stdint.h>
#include <riscv_vector.h>

#define N 4

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

const int8_t A[N][N] = {
    {1, 2, 3, 4},
    {5, 6, 7, 8},
    {1, 0, 1, 0},
    {2, 1, 0, 1},
};

const int8_t B[N][N] = {
    {1, 0, 2, 1},
    {0, 1, 1, 0},
    {1, 1, 0, 2},
    {2, 0, 1, 1},
};

const int8_t B_T[N][N] = {
    {1, 0, 1, 2},
    {0, 1, 1, 0},
    {2, 1, 0, 1},
    {1, 0, 2, 1},
};

volatile int8_t C[N][N] __attribute__((aligned(4)));

const int8_t C_ref[N][N] __attribute__((aligned(4))) = {
    {12, 5, 8, 11},
    {28, 13, 24, 27},
    {2, 1, 2, 3},
    {4, 1, 6, 3},
};

asm(".global vref_start\n.set vref_start, C_ref\n");
asm(".global vref_end\n.set vref_end, C_ref + 16\n");
asm(".global vdata_start\n.set vdata_start, C\n");
asm(".global vdata_end\n.set vdata_end, C + 16\n");

int main(void) {
    // 使用 RVV intrinsics 进行矩阵乘法计算
    // 思路：对 C 的每一行，用向量并行处理该行的所有列
    // C[i][j] = sum_k(A[i][k] * B[k][j]) 
    // 向量化为：C[i][:] += A[i][k] * B[k][:]
    
    size_t vl = __riscv_vsetvl_e8m1(N);  // 设置向量长度为 N (4)

    for (int i = 0; i < N; ++i) {
        // 初始化 C[i][:] = 0
        vint8m1_t vc = __riscv_vmv_v_x_i8m1(0, vl);
        
        // 对于 A[i] 的每个元素
            for (int k = 0; k < N; ++k) {
            int8_t a_elem = A[i][k];  // 标量
            // 加载 B[k][:] 到向量
            vint8m1_t vb = __riscv_vle8_v_i8m1(&B[k][0], vl);
            // 向量乘累加：vc += a_elem * vb
            vc = __riscv_vmacc_vx_i8m1(vc, a_elem, vb, vl);
            }
        
        // 将结果向量写回 C[i][:]
        __riscv_vse8_v_i8m1((int8_t *)&C[i][0], vc, vl);
        }
    
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    return 0;
}
