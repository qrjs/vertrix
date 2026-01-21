#!/bin/bash
# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# MNIST QAT 完整流程脚本
# 用法: ./run_mnist_qat_pipeline.sh [--skip-train] [--skip-export] [--skip-verify] [--skip-test]

set -e  # 遇到错误立即退出

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}MNIST QAT 完整流程${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# 解析命令行参数
SKIP_TRAIN=0
SKIP_EXPORT=0
SKIP_VERIFY=0
SKIP_TEST=0

for arg in "$@"; do
    case $arg in
        --skip-train)
            SKIP_TRAIN=1
            ;;
        --skip-export)
            SKIP_EXPORT=1
            ;;
        --skip-verify)
            SKIP_VERIFY=1
            ;;
        --skip-test)
            SKIP_TEST=1
            ;;
        --help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --skip-train   跳过模型训练"
            echo "  --skip-export  跳过权重导出"
            echo "  --skip-verify  跳过验证步骤"
            echo "  --skip-test    跳过硬件测试"
            echo "  --help         显示帮助信息"
            exit 0
            ;;
    esac
done

# 步骤 1: 训练模型
if [ $SKIP_TRAIN -eq 0 ]; then
    echo -e "${GREEN}[步骤 1/4] 训练 MNIST QAT 模型...${NC}"
    cd "$SCRIPT_DIR"
    python3 qat_train_mnist.py
    echo -e "${GREEN}✓ 模型训练完成${NC}\n"
else
    echo -e "${YELLOW}[跳过] 模型训练${NC}\n"
fi

# 步骤 2: 导出权重
if [ $SKIP_EXPORT -eq 0 ]; then
    echo -e "${GREEN}[步骤 2/4] 导出权重到 C 头文件...${NC}"
    cd "$SCRIPT_DIR"
    
    # 检查模型是否存在
    if [ ! -f "models/mnist_qat_quantized.pth" ]; then
        echo -e "${RED}错误: 找不到训练好的模型${NC}"
        echo -e "${YELLOW}请先运行训练步骤或使用 --skip-train 0${NC}"
        exit 1
    fi
    
    python3 export_weights.py
    echo -e "${GREEN}✓ 权重导出完成${NC}\n"
else
    echo -e "${YELLOW}[跳过] 权重导出${NC}\n"
fi

# 步骤 3: 验证模型
if [ $SKIP_VERIFY -eq 0 ]; then
    echo -e "${GREEN}[步骤 3/4] 验证推理一致性...${NC}"
    cd "$SCRIPT_DIR"
    python3 verify_qat.py
    echo -e "${GREEN}✓ 验证完成${NC}\n"
else
    echo -e "${YELLOW}[跳过] 验证步骤${NC}\n"
fi

# 步骤 4: 硬件测试
if [ $SKIP_TEST -eq 0 ]; then
    echo -e "${GREEN}[步骤 4/4] 在 vproc 上运行测试...${NC}"
    cd "$PROJECT_DIR/test"
    
    # 检查是否有 C 头文件
    if [ ! -f "kernel/mnist_weights.h" ]; then
        echo -e "${YELLOW}警告: mnist_weights.h 不存在${NC}"
        echo -e "${YELLOW}当前 C 代码使用占位符，无法得到正确结果${NC}"
        echo -e "${YELLOW}请先运行导出步骤生成权重文件${NC}"
        echo ""
    fi
    
    # 使用 Verilator 运行测试
    echo -e "${BLUE}使用 Verilator 仿真器...${NC}"
    make kernel/mnist_qat_infer SIMULATOR=verilator || {
        echo -e "${YELLOW}注意: 测试可能失败，因为 C 代码中使用了占位符${NC}"
        echo -e "${YELLOW}请确保已运行权重导出步骤并取消注释推理代码${NC}"
    }
    
    echo -e "${GREEN}✓ 硬件测试完成${NC}\n"
else
    echo -e "${YELLOW}[跳过] 硬件测试${NC}\n"
fi

# 总结
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}所有步骤完成!${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "生成的文件:"
echo "  - sw/models/mnist_qat_quantized.pth    (量化模型)"
echo "  - test/kernel/mnist_weights.h          (权重头文件)"
echo "  - test/kernel/mnist_test_sample.h      (测试样本)"
echo "  - test/kernel/mnist_reference_outputs.txt (参考输出)"
echo ""
echo "下一步:"
echo "  1. 查看 sw/README_MNIST_QAT.md 了解详细说明"
echo "  2. 编辑 test/kernel/mnist_qat_infer.c 取消注释推理代码"
echo "  3. 运行 'make kernel/mnist_qat_infer' 测试推理"
echo ""
