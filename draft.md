# 当前进展记录（用于清空上下文后续接）

## 目标
- 让 `kernel/mnist_infer` 完整跑通（不在结尾报错）。
- FP 功能保持常开，不依赖可选开关。
- 优先修复 RTL 根因，不绕过 Verilator。

## 已完成修改

### 1) `sim/Makefile`
- 将 FP 编译路径改为常开：
  - `-DRISCV_ZVE32F` 变为无条件启用。
  - FP 源文件列表改为无条件加入，不再依赖 `RISCV_ZVE32F` 条件。
- FP 源列表收敛为 E906/TH32 相关路径（移除了先前 C910 路径）。
- Verilator 参数从 `--unroll-count 1024` 调整为 `--unroll-count 256`。
- 最新一次变更（尚未完整回归验证）：全局加入 `-DOLD_VICUNA`。

### 2) `rtl/vproc_fpu.sv`
- `fpnew_top` 参数修正：
  - `.DivSqrtSel(fpnew_pkg::THMULTI)`
  - 改为 `.DivSqrtSel(fpnew_pkg::TH32)`

### 3) `test/Makefile`
- 在 `make ... | tee sim.log` 前加入 `set -o pipefail`。
- 目的：避免上游失败时因为 `tee` 返回 0 导致误报 `[PASS]`。

### 4) `rtl/vproc_top.sv`
- 修复了一个明确的 RTL 位宽问题（此前会触发 Verilator Internal Error）：
  - 原写法在参数配置下会形成负复制宽度：
    `{{(64-VMEM_W){1'b0}}, data_rdata}`
- 改为 generate 分支：
  - `if (VMEM_W >= 64)` 与 `else` 分开赋值
  - 让非法宽度分支不被 elaboration
- 结果：此前 `%Error: Internal Error: V3Number.h:194` 已消失。

### 5) `rtl/vproc_pending_wr.sv`
- 将稳定分支逻辑设为默认：
  - `ifndef VPROC_EXPERIMENTAL_PENDING_WR` 下走旧稳定实现
  - 实验性（VL 相关）分支改为显式 opt-in
- 该项目前尚未单独证明可消除当前运行期 SVA 失败。

### 6) `sva/vproc_pipeline_sva.svh`
- 增强断言报错信息（原第 37 行附近）：
  - 现在会打印 `addr`、`pend_wr`、`pend_rd`，便于定位时序/状态不一致。

## 当前测试状态
- 编译/建模阶段：
  - 之前的 Verilator internal crash（`V3Number.h:194`）已通过 `rtl/vproc_top.sv` 修复。
- 运行阶段：
  - 目前失败点转移到 SVA：`sva/vproc_pipeline_sva.svh:37`
  - 典型报错上下文：
    - `addr=1 pend_wr=0x00000000 pend_rd=0x00000000`
  - 指向 pending-write 跟踪与 vreg 写入之间存在时序/状态不一致。

## 关键结论
- 之前之所以看起来“很快就 PASS”，一个重要原因是没有 `pipefail`，失败可能被 `tee` 掩盖。
- 现在是“真实失败被正确暴露”。
- 当前最重要问题已从“工具内部崩溃”转为“RTL 运行期行为不一致（SVA）”。

## 最后进行中的动作（被打断）
- 已在 `sim/Makefile` 加入 `-DOLD_VICUNA` 后，准备/启动：
  - `make clean && make kernel/mnist_infer`
- 由于你打断，**该轮结果尚未确认**。

## 我修改过的文件（仅这些）
- `sim/Makefile`
- `rtl/vproc_fpu.sv`
- `test/Makefile`
- `rtl/vproc_top.sv`
- `rtl/vproc_pending_wr.sv`
- `sva/vproc_pipeline_sva.svh`

## 下一步建议（供下轮直接接）
1. 先完整执行一次：`make clean && make kernel/mnist_infer`（确认 `-DOLD_VICUNA` 的实际影响）。
2. 若 SVA 仍在 `vproc_pipeline_sva.svh:37` 触发，聚焦排查：
   - `vproc_pending_wr.sv` 中 pending 位图更新时序
   - 写回 valid/addr 与 pending set/clear 的同拍关系
   - 与 `vproc_pipeline` 中 vreg 写口握手条件的一致性
3. 以“修 RTL 根因”为准，不通过关闭断言或弱化检查来绕过。

## 本轮续跑结果（最新）
- 已执行：`cd test && make clean && make kernel/mnist_infer`
- 结果：完整通过，最终输出 `[PASS] kernel/mnist_infer/mnist_infer`。
- 关键确认：
  - Verilation/编译阶段无 `MODMISSING`、无 internal error。
  - 运行阶段无此前的 `vproc_pipeline_sva.svh:37` 断言报错。
  - 有性能统计输出后正常退出，非假 PASS。
