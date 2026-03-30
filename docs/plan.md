# Vicuna FP32 浮点支持完善与 MNIST 推理实现

## Goal Description

完善 Vicuna RISC-V Zve32x 向量协处理器的浮点支持，包括：修复现有浮点指令中的 bug、补全解码器中缺失的浮点指令映射（FUNARY1 操作、宽化操作等）、通过 Python 脚本导出 FP32 权重文件，以及编写完整的 FP32 MNIST 推理实现 (`mnist_infer_fp32.c`)。最终目标是在仿真环境中用 FP32 浮点运算正确完成 MNIST 手写数字识别推理，测试样本的预期输出为数字 7。

## Acceptance Criteria

Following TDD philosophy, each criterion includes positive and negative tests for deterministic verification.

- AC-1: 现有浮点 bug 已修复
  - Positive Tests (expected to PASS):
    - 所有 `test/fp/` 目录下的 8 个已有 FP 测试（vfadd_test, vfsub_test, vfmul_test, vfp_ops_test, vfp_chain_test, vfadd16_test, vfmacc16_test 等）在仿真中全部通过
    - 连续运行两次测试结果一致（排除非确定性问题）
  - Negative Tests (expected to FAIL):
    - 将 vfadd_test 中的期望结果改为错误值（如将 11.0 改为 12.0），测试应报告 FAIL
    - 对浮点加法输入 NaN 值，结果应为 NaN（非有限数）

- AC-2: 缺失的浮点指令已在解码器中正确映射
  - AC-2.1: FUNARY1 操作完善（vfsqrt.v、vfrsqrt7.v、vfrec7.v 根据 vs1 字段正确解码）
    - Positive Tests:
      - 编写 vfsqrt 汇编测试：对向量 [4.0, 9.0, 16.0, 25.0] 执行 vfsqrt.v，结果为 [2.0, 3.0, 4.0, 5.0]
      - vfclass.v 测试在 FUNARY1 改造后仍然正确工作
    - Negative Tests:
      - 对负数执行 vfsqrt.v，结果应为 NaN
      - 对 0.0 执行 vfrsqrt7.v，结果应为 +Inf
  - AC-2.2: 宽化浮点操作的 op 字段已正确赋值（当前多处被注释为 `//mode_o.fpu.op = ;`）
    - Positive Tests:
      - vfwmul 测试：两个 FP16 向量相乘，结果以 FP32 格式正确输出
      - vfwmacc 测试：FP16 宽化乘累加运算结果正确
    - Negative Tests:
      - 使用非法 SEW 配置（如 SEW=8 下执行宽化 FP 操作）应触发非法指令异常

- AC-3: FP32 权重文件正确导出
  - Positive Tests:
    - `sw/export_weights.py` 新增 FP32 导出模式，生成 `test/kernel/mnist_weights_fp32.h`
    - 头文件包含与 INT8 版本相同的网络维度宏定义（INPUT_H=28, CONV1_OUT_C=3 等）
    - 权重数组类型为 `const float`，值域合理（无 NaN、无 Inf）
  - Negative Tests:
    - 若训练模型文件不存在，脚本应报错并退出而非生成空文件
    - 导出的 FP32 权重与原始 PyTorch 浮点权重之间的误差为零（不进行量化，直接导出原始浮点值）

- AC-4: FP32 MNIST 推理正确运行
  - Positive Tests:
    - `mnist_infer_fp32.c` 使用 RVV 浮点向量指令完成完整推理流程（Conv1 → ReLU → Pool → Conv2 → ReLU → Pool → Flatten → FC1 → ReLU → FC2 → ReLU → FC3 → Argmax）
    - 仿真输出的预测结果为 7（与 INT8 版本和标量版本一致）
    - 内存对齐和缓冲区大小正确，无越界访问
  - Negative Tests:
    - 若将 FC3 权重全部置零，输出应为全零 logits（非分类为 7）
    - 若跳过 ReLU 层，最终分类结果可能改变（验证 ReLU 对结果的必要性）

- AC-5: 测试基础设施正确配置
  - Positive Tests:
    - `test/kernel/test_configs.conf` 中包含启用 `RISCV_ZVE32F=1` 的 FP32 测试配置行
    - `make kernel/mnist_infer_fp32` 能成功编译并运行仿真
    - 仿真结果比较通过（dump.vmem 与 ref.vmem 内容一致）
  - Negative Tests:
    - 在未启用 `RISCV_ZVE32F` 的配置下编译 FP32 MNIST，应因浮点指令未定义而编译失败或仿真报错

## Path Boundaries

Path boundaries define the acceptable range of implementation quality and choices.

### Upper Bound (Maximum Acceptable Scope)

完整实现所有缺失的 FP 解码器映射（包括 FUNARY1 全部操作、所有宽化操作的 op 字段修正），修复所有已知 FP bug，导出 FP32 权重并为 FP32 测试样本创建独立的浮点头文件，编写使用 im2col+GEMM 优化策略的 `mnist_infer_fp32.c`（与 INT8 版本的优化程度相当），并为新增的每个 FP 指令编写独立的汇编测试用例。kernel 测试配置中同时保留 INT8 和 FP32 两套配置。

### Lower Bound (Minimum Acceptable Scope)

仅修复影响 FP32 MNIST 推理所需操作（vfadd, vfmul, vfmacc, vfmax, vfredusum, vle32/vse32）的 bug，补全 MNIST 直接依赖的缺失指令（如有），导出 FP32 权重头文件，编写功能正确但未深度优化的 `mnist_infer_fp32.c`（可使用简单标量循环+向量内积的方式），仿真中正确输出数字 7。

### Allowed Choices

- Can use:
  - RVV C 内联函数 (`<riscv_vector.h>`) 编写推理代码
  - 参考现有 `mnist_infer.c`（INT8 版本）的算法结构进行 FP32 适配
  - fpnew 库中已有的 SQRT、F2I、I2F 等操作用于解码器映射
  - 纯 FP32 数据路径（输入、权重、中间结果均为 float）
  - 在 Python 脚本中直接导出 PyTorch 原始浮点权重（不做量化）
- Cannot use:
  - 自定义非标准指令（必须遵循 RISC-V V 扩展规范）
  - 修改 fpnew 核心 RTL（仅修改 decoder 和 FPU wrapper 层）
  - 硬编码测试结果（必须通过实际推理计算得出）

## Feasibility Hints and Suggestions

> **Note**: This section is for reference and understanding only. These are conceptual suggestions, not prescriptive requirements.

### Conceptual Approach

**FP32 MNIST 推理的核心计算流程（伪代码）：**

```
// 所有数据均为 float (FP32)
float input[28*28];   // 从 test_sample 转换而来
float weights_fp32;   // 从 Python 直接导出

// Conv + ReLU + MaxPool（使用 vfmacc 实现卷积核心）
for each output_channel:
    for each spatial_position:
        vfloat32m4_t acc = vfmv_v_f(0.0f, vl);
        for each kernel_element:
            acc = vfmacc(acc, weight, input_patch, vl);  // FP32 乘累加

    // ReLU: vfmax.vf(data, 0.0f)
    // MaxPool: vfmax.vv on 2x2 windows

// FC 层（使用 vfmacc 实现向量点积）
for each output_neuron:
    vfloat32m1_t sum = vfmv_v_f(0.0f, 1);
    for each input_chunk:
        vfloat32m4_t v_in = vle32(input, vl);
        vfloat32m4_t v_w  = vle32(weight, vl);
        vfloat32m4_t v_mul = vfmul(v_in, v_w, vl);
        sum = vfredusum(v_mul, sum, vl);  // 归约求和

// Argmax: 标量循环遍历 10 个 logits 找最大值
```

**解码器修复方法（FUNARY1 示例）：**

```systemverilog
// 当前: 无条件设置 op = CLASSIFY
// 修改: 按 vs1 字段区分不同 FUNARY1 操作
{6'b010011, 3'b001}: begin  // FUNARY1
    unique case (instr_vs1)
        5'b00000: op = SQRT;      // vfsqrt.v
        5'b00100: op = CLASSIFY;  // vfrsqrt7.v → 需映射
        5'b00101: op = CLASSIFY;  // vfrec7.v → 需映射
        5'b10000: op = CLASSIFY;  // vfclass.v
        default:  instr_illegal = 1'b1;
    endcase
end
```

### Relevant References

- `rtl/vproc_decoder.sv` - 指令解码器，FP 解码从第 1415 行开始；FUNARY0（类型转换）在第 1728 行；FUNARY1（vfclass/vfsqrt）在第 1794 行；宽化操作在第 1894 行（`ifdef RISCV_ZVFH` 块内）
- `rtl/vproc_fpu.sv` - FPU 执行单元，324 行，控制 fpnew 库的操作分发
- `rtl/vproc_pkg.sv` - 包定义，`op_mode_fpu` 结构体定义了 FPU 模式字段
- `rtl/cvfpu/src/fpnew_top.sv` - fpnew 顶层，支持 SQRT、F2I、I2F 等所有操作
- `test/kernel/mnist_infer.c` - INT8 版本参考实现，im2col+GEMM 优化架构
- `test/kernel/mnist_infer_scalar.c` - 标量参考实现，算法结构简单清晰
- `sw/export_weights.py` - 权重导出脚本，需新增 FP32 导出函数
- `sw/qat_train_mnist.py` - 训练脚本，包含 MNISTQATNet 模型定义
- `test/fp/vfadd_test.S` - FP 汇编测试模板，展示测试编写规范
- `test/fp/test_configs.conf` - FP 测试配置，使用 `RISCV_ZVE32F=1`
- `test/kernel/test_configs.conf` - kernel 测试配置，当前已包含 `RISCV_ZVE32F=1`

## Dependencies and Sequence

### Milestones

1. **Bug 诊断与修复**：运行并排查现有 FP 测试的失败项
   - Phase A: 在当前代码基础上运行全部 `test/fp/` 测试，记录通过/失败状态
   - Phase B: 分析失败测试的根因（解码器映射错误、FPU 数据通路问题、或测试本身问题）
   - Phase C: 修复 bug 并验证所有 FP 测试通过

2. **解码器补全**：完善缺失的 FP 指令映射
   - Phase A: 修复 FUNARY1 解码 — 按 vs1 字段区分 vfsqrt.v、vfrsqrt7.v、vfrec7.v、vfclass.v
   - Phase B: 修复宽化操作 — 填充 vfwmul、vfwmacc、vfwnmacc 等被注释的 `mode_o.fpu.op` 字段
   - Phase C: 修复宽化归约操作（vfwredusum、vfwredosum）的 op 字段
   - Phase D: 为新增指令编写汇编测试，验证解码和执行正确性

3. **FP32 权重导出**：生成浮点权重头文件
   - Phase A: 在 `sw/export_weights.py` 中新增 FP32 导出函数（不做量化，直接导出原始浮点值）
   - Phase B: 运行脚本生成 `test/kernel/mnist_weights_fp32.h`
   - Phase C: 验证权重值域合理性（无 NaN/Inf，数值范围与训练时一致）

4. **FP32 推理实现**：编写 `test/kernel/mnist_infer_fp32.c`
   - Phase A: 搭建基本框架（包含头文件、定义缓冲区、main 函数和验证结构）
   - Phase B: 实现卷积层（参考 INT8 版本的 im2col+GEMM 结构，替换为 FP32 运算）
   - Phase C: 实现 ReLU（vfmax.vf 与 0.0f）和 MaxPool（vfmax.vv）
   - Phase D: 实现全连接层（使用 vfmacc 或 vfmul+vfredusum）
   - Phase E: 实现 Argmax 和前向推理主流程

5. **集成测试**：端到端验证
   - Phase A: 更新 `test/kernel/test_configs.conf`，添加带 `RISCV_ZVE32F=1` 的 FP32 配置行
   - Phase B: 编译并运行 FP32 MNIST 仿真，验证输出为 7
   - Phase C: 对比 FP32 与 INT8 版本的推理结果一致性

**依赖关系：**
- Milestone 1（bug 修复）是所有后续工作的前提
- Milestone 2（解码器补全）和 Milestone 3（权重导出）相互独立，可并行
- Milestone 4（推理实现）依赖 Milestone 1（FP 操作正确性）和 Milestone 3（权重文件）
- Milestone 5（集成测试）依赖所有前序 Milestone

## Implementation Notes

### Code Style Requirements
- Implementation code and comments must NOT contain plan-specific terminology such as "AC-", "Milestone", "Step", "Phase", or similar workflow markers
- These terms are for plan documentation only, not for the resulting codebase
- Use descriptive, domain-appropriate naming in code instead
- 代码注释使用中文或英文均可（保持与现有代码风格一致，现有代码使用中文注释）
- SystemVerilog 修改应遵循现有 decoder 的编码风格（case 语句、信号赋值格式）
- C 代码应使用 RVV 内联函数（`__riscv_v*` 命名风格），与 `mnist_infer.c` 保持一致

### Key Technical Notes
- 当前 FP 测试配置 (`test/fp/test_configs.conf`) 与 kernel 测试配置都使用 `VREG_W=128 VMEM_W=32`，并且 kernel 配置已启用 `RISCV_ZVE32F=1`
- fpnew 库已支持 SQRT、F2I、I2F 操作，但需要确认 vproc_fpu.sv 中的数据通路是否正确处理这些操作类型（特别是 CONV 操作组可能需要额外的格式/类型控制信号）
- 宽化操作位于 `ifdef RISCV_ZVFH` 保护下，仅在启用 FP16 半精度时可用。纯 FP32 MNIST 推理不依赖宽化操作
- FP32 测试样本输入：当前 `mnist_test_sample.h` 中的测试数据为 INT8 格式，FP32 推理可以选择在 C 代码中运行时转换（使用标量浮点转换），或在 Python 脚本中导出 FP32 格式的测试样本

--- Original Design Draft Start ---

帮我完成现在这个处理器对浮点的支持，最终目标是用fp32完成对mnist_infer的支持
--- Original Design Draft End ---
