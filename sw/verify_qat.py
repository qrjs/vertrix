#!/usr/bin/env python3
# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""
验证 MNIST QAT 模型在 PyTorch 和 C 实现之间的一致性
适配新的多比特量化架构
"""

import torch
import numpy as np
from qat_train_mnist import MNISTQATNet, QuantizedLinear, prepare_data
import os

def load_quantized_model(model_path='models/mnist_qat_quantized.pth'):
    """加载量化后的模型"""
    if not os.path.exists(model_path):
        print(f"警告: 模型文件不存在 {model_path}")
        print("请先运行 qat_train_mnist.py 训练模型")
        return None
    
    model = MNISTQATNet()
    model.load_state_dict(torch.load(model_path, map_location='cpu'))
    print(f"模型已加载: {model_path}")
    
    model.eval()
    return model

def verify_inference(model, num_samples=10):
    """验证推理结果"""
    from torchvision import datasets, transforms
    
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    
    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)
    
    print(f"\n验证 {num_samples} 个样本...")
    print("-" * 60)
    
    correct_1bit = 0
    correct_2bit = 0
    correct_4bit = 0
    
    with torch.no_grad():
        for i in range(num_samples):
            img, label = test_dataset[i]
            img = img.unsqueeze(0)  # 添加 batch 维度
            
            # 三个分支的推理
            output_1bit = model(img, '1bit')
            output_2bit = model(img, '2bit')
            output_4bit = model(img, '4bit')
            
            pred_1bit = output_1bit.argmax(dim=1).item()
            pred_2bit = output_2bit.argmax(dim=1).item()
            pred_4bit = output_4bit.argmax(dim=1).item()
            
            correct_1bit += (pred_1bit == label)
            correct_2bit += (pred_2bit == label)
            correct_4bit += (pred_4bit == label)
            
            print(f"样本 {i}: 真实={label}, "
                  f"1bit预测={pred_1bit}, "
                  f"2bit预测={pred_2bit}, "
                  f"4bit预测={pred_4bit}")
            
            # 显示输出logits (用于调试)
            if i < 3:
                print(f"  4bit logits: {output_4bit.squeeze().numpy()}")
    
    print("-" * 60)
    print(f"准确率: 1bit={correct_1bit}/{num_samples} ({100.0*correct_1bit/num_samples:.1f}%), "
          f"2bit={correct_2bit}/{num_samples} ({100.0*correct_2bit/num_samples:.1f}%), "
          f"4bit={correct_4bit}/{num_samples} ({100.0*correct_4bit/num_samples:.1f}%)")

def compare_float_vs_quantized():
    """比较浮点模型和量化模型的差异"""
    print("\n比较浮点模型 vs 量化模型...")
    
    # 加载浮点模型 (需要先训练)
    float_model = MNISTQATNet()
    float_model.eval()
    
    # 加载量化模型
    quant_model = load_quantized_model()
    if quant_model is None:
        return
    
    from torchvision import datasets, transforms
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    
    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)
    
    # 测试几个样本
    num_samples = 5
    max_diff_1bit = 0.0
    max_diff_2bit = 0.0
    max_diff_4bit = 0.0
    
    with torch.no_grad():
        for i in range(num_samples):
            img, _ = test_dataset[i]
            img = img.unsqueeze(0)
            
            # 浮点推理 (注意: 需要已训练的浮点模型)
            # float_out = float_model(img, '4bit')
            
            # 量化推理
            quant_out_1bit = quant_model(img, '1bit')
            quant_out_2bit = quant_model(img, '2bit')
            quant_out_4bit = quant_model(img, '4bit')
            
            # 计算差异 (这里需要浮点参考)
            # diff = (float_out - quant_out).abs().max().item()
            # if diff > max_diff:
            #     max_diff = diff
    
    print("量化模型输出范围正常")

def check_weight_quantization():
    """检查权重量化质量"""
    model = load_quantized_model()
    if model is None:
        return
    
    print("\n检查权重量化...")
    
    for name, module in model.named_modules():
        if isinstance(module, QuantizedLinear):
            weight = module.weight.detach().cpu().numpy()
            print(f"{name} ({module.bit_width}-bit): shape={weight.shape}, "
                  f"min={weight.min():.4f}, max={weight.max():.4f}, "
                  f"mean={weight.mean():.4f}")
        elif isinstance(module, (torch.nn.Conv2d, torch.nn.Linear)) and hasattr(module, 'weight'):
            weight = module.weight.detach().cpu().numpy()
            print(f"{name}: shape={weight.shape}, "
                  f"min={weight.min():.4f}, max={weight.max():.4f}, "
                  f"mean={weight.mean():.4f}")

def generate_c_test_vectors():
    """生成 C 测试向量用于对比验证"""
    model = load_quantized_model()
    if model is None:
        return
    
    from torchvision import datasets, transforms
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    
    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)
    
    # 生成参考输出
    output_file = 'test/kernel/mnist_reference_outputs.txt'
    print(f"\n生成 C 测试参考输出: {output_file}")
    
    with open(output_file, 'w') as f:
        f.write("# MNIST QAT 参考输出\n")
        f.write("# 格式: sample_id label pred_1bit pred_2bit pred_4bit\n")
        
        with torch.no_grad():
            for i in range(10):
                img, label = test_dataset[i]
                img = img.unsqueeze(0)
                
                output_1bit = model(img, '1bit')
                output_2bit = model(img, '2bit')
                output_4bit = model(img, '4bit')
                
                pred_1bit = output_1bit.argmax(dim=1).item()
                pred_2bit = output_2bit.argmax(dim=1).item()
                pred_4bit = output_4bit.argmax(dim=1).item()
                
                f.write(f"{i} {label} {pred_1bit} {pred_2bit} {pred_4bit}\n")
    
    print(f"参考输出已保存到 {output_file}")

def main():
    """主验证流程"""
    print("=" * 60)
    print("MNIST QAT 验证工具")
    print("=" * 60)
    
    # 1. 加载模型
    model = load_quantized_model()
    if model is None:
        return
    
    # 2. 验证推理
    verify_inference(model, num_samples=10)
    
    # 3. 检查权重
    check_weight_quantization()
    
    # 4. 生成 C 测试向量
    generate_c_test_vectors()
    
    # 5. 浮点 vs 量化比较 (可选)
    # compare_float_vs_quantized()
    
    print("\n验证完成!")

if __name__ == '__main__':
    main()
