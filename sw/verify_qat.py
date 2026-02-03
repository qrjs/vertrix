#!/usr/bin/env python3
# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""
验证 MNIST QAT 模型（int8，无偏置）
1. 验证浮点推理的正确性
2. 验证纯整数推理（不需要scale）
"""

import torch
import torch.nn.functional as F
import numpy as np
from qat_train_mnist import MNISTQATNet
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

def quantize_to_int8(tensor):
    """将浮点张量量化为int8"""
    tensor_max = torch.max(torch.abs(tensor))
    if tensor_max == 0:
        return torch.zeros_like(tensor, dtype=torch.int32), 1.0
    scale = (tensor_max / 127.0).item()
    tensor_q = torch.clamp(torch.round(tensor / scale), -128, 127).to(torch.int32)
    return tensor_q, scale

def get_int8_weights(model):
    """从模型提取所有int8量化权重"""
    state_dict = model.state_dict()
    weights = {}
    
    for name in ['conv1', 'conv2', 'fc1', 'fc2', 'fc3']:
        w = state_dict[f'{name}.weight'].detach()
        w_q, _ = quantize_to_int8(w)
        weights[name] = w_q
    
    return weights

def verify_float_inference(model, num_samples=10):
    """验证浮点推理结果"""
    from torchvision import datasets, transforms
    
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    
    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)
    
    print(f"\n验证浮点推理 {num_samples} 个样本...")
    print("-" * 60)
    
    correct = 0
    
    with torch.no_grad():
        for i in range(num_samples):
            img, label = test_dataset[i]
            img = img.unsqueeze(0)
            
            output = model(img)
            pred = output.argmax(dim=1).item()
            correct += (pred == label)
            
            print(f"样本 {i}: 真实={label}, 预测={pred}, {'✓' if pred == label else '✗'}")
    
    print("-" * 60)
    print(f"浮点推理准确率: {correct}/{num_samples} ({100.0*correct/num_samples:.1f}%)")
    return correct

def verify_pure_int_inference(model, num_samples=10):
    """
    验证纯整数推理（不使用scale，无偏置）
    
    数学原理：
    - y = W*x，scale只是常数因子
    - argmax(y * scale) == argmax(y)
    - ReLU和MaxPool只比较大小
    
    实现：
    - 输入/权重都是 int8
    - 中间累加用 int32
    - 每层输出右移后截断到 int8
    """
    from torchvision import datasets, transforms
    
    transform = transforms.Compose([
        transforms.ToTensor(),
    ])
    
    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)
    
    print(f"\n验证纯整数推理（无scale，无bias）{num_samples} 个样本...")
    print("-" * 60)
    
    # 获取int8权重
    weights = get_int8_weights(model)
    
    mean = 0.1307
    std = 0.3081
    
    correct_int = 0
    correct_float = 0
    
    with torch.no_grad():
        for i in range(num_samples):
            img, label = test_dataset[i]
            
            # === 浮点参考 ===
            img_normalized = (img - mean) / std
            output_float = model(img_normalized.unsqueeze(0))
            pred_float = output_float.argmax(dim=1).item()
            correct_float += (pred_float == label)
            
            # === 纯整数推理 ===
            # 输入量化到 int8
            img_normalized = (img - mean) / std
            x, _ = quantize_to_int8(img_normalized)
            x = x.unsqueeze(0)  # [1, 1, 28, 28]
            
            # Conv1: int8 * int8 -> int32，右移到 int8
            acc = F.conv2d(x.float(), weights['conv1'].float(), bias=None, stride=1, padding=1).to(torch.int32)
            x = torch.clamp(acc >> 7, -128, 127)  # 右移7位
            x = torch.clamp(x, 0, 127)  # ReLU
            x = F.max_pool2d(x.float(), 2).to(torch.int32)
            
            # Conv2
            acc = F.conv2d(x.float(), weights['conv2'].float(), bias=None, stride=1, padding=1).to(torch.int32)
            x = torch.clamp(acc >> 7, -128, 127)
            x = torch.clamp(x, 0, 127)  # ReLU
            x = F.max_pool2d(x.float(), 2).to(torch.int32)
            
            # Flatten
            x = x.reshape(1, -1)
            
            # FC1
            acc = F.linear(x.float(), weights['fc1'].float(), bias=None).to(torch.int32)
            x = torch.clamp(acc >> 8, -128, 127)
            x = torch.clamp(x, 0, 127)  # ReLU
            
            # FC2
            acc = F.linear(x.float(), weights['fc2'].float(), bias=None).to(torch.int32)
            x = torch.clamp(acc >> 7, -128, 127)
            x = torch.clamp(x, 0, 127)  # ReLU
            
            # FC3 (output) - 不需要截断，直接用 int32 做 argmax
            output_int = F.linear(x.float(), weights['fc3'].float(), bias=None).to(torch.int32)
            
            pred_int = output_int.argmax(dim=1).item()
            correct_int += (pred_int == label)
            
            match_str = '✓' if pred_int == label else '✗'
            same_str = '(同)' if pred_int == pred_float else '(异)'
            print(f"样本 {i}: 真实={label}, float预测={pred_float}, int预测={pred_int} {match_str} {same_str}")
            
            if i < 3:
                print(f"  float logits: {output_float.squeeze().numpy()}")
                print(f"  int32 logits: {output_int.squeeze().numpy()}")
    
    print("-" * 60)
    print(f"浮点推理准确率: {correct_float}/{num_samples} ({100.0*correct_float/num_samples:.1f}%)")
    print(f"纯整数推理准确率: {correct_int}/{num_samples} ({100.0*correct_int/num_samples:.1f}%)")
    
    return correct_int, correct_float

def check_weight_quantization(model):
    """检查权重量化后的int8值"""
    print("\n检查int8量化权重...")
    
    weights = get_int8_weights(model)
    
    for name, w_q in weights.items():
        w_np = w_q.numpy()
        print(f"{name}: shape={w_np.shape}, range=[{w_np.min()}, {w_np.max()}]")

def generate_c_test_vectors(model):
    """生成 C 测试向量用于对比验证"""
    from torchvision import datasets, transforms
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    
    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)
    
    output_file = 'test/kernel/mnist_reference_outputs.txt'
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    print(f"\n生成 C 测试参考输出: {output_file}")
    
    with open(output_file, 'w') as f:
        f.write("# MNIST QAT 参考输出\n")
        f.write("# 格式: sample_id label prediction\n")
        
        with torch.no_grad():
            for i in range(10):
                img, label = test_dataset[i]
                img = img.unsqueeze(0)
                
                output = model(img)
                pred = output.argmax(dim=1).item()
                
                f.write(f"{i} {label} {pred}\n")
    
    print(f"参考输出已保存到 {output_file}")

def main():
    """主验证流程"""
    print("=" * 60)
    print("MNIST QAT 验证工具 (int8, 无偏置)")
    print("=" * 60)
    
    # 1. 加载模型
    model = load_quantized_model()
    if model is None:
        return
    
    # 2. 验证浮点推理
    verify_float_inference(model, num_samples=10)
    
    # 3. 验证纯整数推理
    verify_pure_int_inference(model, num_samples=10)
    
    # 4. 检查int8权重
    check_weight_quantization(model)
    
    # 5. 生成 C 测试向量
    generate_c_test_vectors(model)
    
    print("\n验证完成!")

if __name__ == '__main__':
    main()
