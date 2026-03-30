#ifndef RVV_COMPAT_H
#define RVV_COMPAT_H

#include <riscv_vector.h>

/*
 * The checked-in kernel code uses GCC-style RVV intrinsic names. Clang/LLVM
 * ships the standardized intrinsics without the __riscv_ prefix, so provide a
 * small compatibility shim to keep one source base working with both compilers.
 */
#ifdef __clang__
#define __riscv_vadd_vv_i32m4 vadd_vv_i32m4
#define __riscv_vfmacc_vv_f32m1 vfmacc_vv_f32m1
#define __riscv_vfmax_vv_f32m1 vfmax_vv_f32m1
#define __riscv_vfmul_vv_f32m1 vfmul_vv_f32m1
#if defined(__riscv_f)
#define __riscv_vfredusum_vs_f32m1_f32m1(vs2, vs1, vl) \
    vfredusum_vs_f32m1_f32m1((vs1), (vs2), (vs1), (vl))
#endif
#define __riscv_vle32_v_f32m1 vle32_v_f32m1
#define __riscv_vle32_v_i32m1 vle32_v_i32m1
#define __riscv_vle32_v_i32m4 vle32_v_i32m4
#define __riscv_vle8_v_i8m1 vle8_v_i8m1
#define __riscv_vle8_v_i8m2 vle8_v_i8m2
#define __riscv_vle8_v_i8m8 vle8_v_i8m8
#define __riscv_vmacc_vx_i8m1 vmacc_vx_i8m1
#define __riscv_vmax_vv_i8m1 vmax_vv_i8m1
#define __riscv_vmax_vx_i8m8 vmax_vx_i8m8
#define __riscv_vmv_v_x_i32m1 vmv_v_x_i32m1
#define __riscv_vmv_v_x_i32m8 vmv_v_x_i32m8
#define __riscv_vmv_v_x_i8m1 vmv_v_x_i8m1
#define __riscv_vmv_v_x_i8m8 vmv_v_x_i8m8
#define __riscv_vmv_x_s_i32m1_i32 vmv_x_s_i32m1_i32
#define __riscv_vreinterpret_v_i32m1_f32m1 vreinterpret_v_i32m1_f32m1
#define __riscv_vse32_v_f32m1 vse32_v_f32m1
#define __riscv_vse32_v_i32m1 vse32_v_i32m1
#define __riscv_vse32_v_i32m4 vse32_v_i32m4
#define __riscv_vse32_v_i32m8 vse32_v_i32m8
#define __riscv_vse8_v_i8m1 vse8_v_i8m1
#define __riscv_vse8_v_i8m8 vse8_v_i8m8
#define __riscv_vsetvl_e32m1 vsetvl_e32m1
#define __riscv_vsetvl_e32m8 vsetvl_e32m8
#define __riscv_vsetvl_e8m1 vsetvl_e8m1
#define __riscv_vsetvl_e8m2 vsetvl_e8m2
#define __riscv_vsetvl_e8m8 vsetvl_e8m8
#define __riscv_vwcvt_x_x_v_i32m4 vwcvt_x_x_v_i32m4
#define __riscv_vwmul_vv_i16m2 vwmul_vv_i16m2
#define __riscv_vwmul_vv_i16m4 vwmul_vv_i16m4
#define __riscv_vwmul_vx_i16m2 vwmul_vx_i16m2
#define __riscv_vwredsum_vs_i16m4_i32m1(vs2, vs1, vl) \
    vwredsum_vs_i16m4_i32m1((vs1), (vs2), (vs1), (vl))
#endif

#endif
