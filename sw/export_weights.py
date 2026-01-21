#!/usr/bin/env python3
# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""
将量化后的MNIST模型权重导出为C头文件
适配新的多比特量化架构
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np
from qat_train_mnist import MNISTQATNet, QuantizedLinear
import os

def quantize_to_int8(tensor, scale, zero_point=0):
    """将浮点张量量化为int8"""
    quantized = np.round(tensor / scale + zero_point).astype(np.int8)
    return quantized

def export_weights_to_c_header(model, output_path='mnist_weights.h'):
    """导出量化权重到C头文件"""
    
    print("开始导出权重...")
    
    # 设置模型为评估模式
    model.eval()
    
    with open(output_path, 'w') as f:
        f.write("// Auto-generated MNIST QAT weights\n")
        f.write("// Copyright TU Wien\n")
        f.write("// Licensed under the Solderpad Hardware License v2.1\n\n")
        f.write("#ifndef MNIST_WEIGHTS_H\n")
        f.write("#define MNIST_WEIGHTS_H\n\n")
        f.write("#include <stdint.h>\n\n")
        
        # 导出网络尺寸参数
        f.write("// Network dimensions\n")
        f.write("#define INPUT_H 28\n")
        f.write("#define INPUT_W 28\n")
        f.write("#define INPUT_C 1\n\n")
        
        f.write("#define CONV1_OUT_C 3\n")
        f.write("#define CONV1_OUT_H 28\n")
        f.write("#define CONV1_OUT_W 28\n")
        f.write("#define POOL1_OUT_H 14\n")
        f.write("#define POOL1_OUT_W 14\n\n")
        
        f.write("#define CONV2_OUT_C 6\n")
        f.write("#define CONV2_OUT_H 14\n")
        f.write("#define CONV2_OUT_W 14\n")
        f.write("#define POOL2_OUT_H 7\n")
        f.write("#define POOL2_OUT_W 7\n\n")
        
        f.write("#define FC1_IN 294  // 7*7*6\n")
        f.write("#define FC1_OUT 120\n")
        f.write("#define FC2_OUT 1024\n")
        f.write("#define FC3_OUT 10\n\n")
        
        # 遍历模型的所有层并导出
        state_dict = model.state_dict()
        
        # Conv1: weight [3, 1, 3, 3], bias [3]
        export_conv_layer(f, state_dict, 'conv1', (3, 1, 3, 3))
        
        # Conv2: weight [6, 3, 3, 3], bias [6]
        export_conv_layer(f, state_dict, 'conv2', (6, 3, 3, 3))
        
        # FC1: weight [120, 294], bias [120]
        export_fc_layer(f, state_dict, 'fc1', (120, 294), model=model)
        
        # FC2: weight [1024, 120], bias [1024]
        export_fc_layer(f, state_dict, 'fc2', (1024, 120), model=model)
        
        # FC3 三个分支 - 不同bit宽
        export_fc_layer(f, state_dict, 'fc3_1bit', (10, 1024), suffix='_1bit', model=model, bit_width=1)
        export_fc_layer(f, state_dict, 'fc3_2bit', (10, 1024), suffix='_2bit', model=model, bit_width=2)
        export_fc_layer(f, state_dict, 'fc3_4bit', (10, 1024), suffix='_4bit', model=model, bit_width=4)
        
        f.write("#endif // MNIST_WEIGHTS_H\n")
    
    print(f"权重导出完成: {output_path}")

def export_conv_layer(f, state_dict, layer_name, shape):
    """导出卷积层权重"""
    weight_key = f'{layer_name}.weight'
    bias_key = f'{layer_name}.bias'
    
    if weight_key not in state_dict:
        print(f"Warning: {weight_key} not found in state_dict")
        return
    
    weight_tensor = state_dict[weight_key]
    
    # 检查是否为量化张量
    if hasattr(weight_tensor, 'int_repr') and weight_tensor.is_quantized:
        try:
            # 量化后的权重，直接获取int8表示
            weight_q = weight_tensor.int_repr().cpu().numpy()
            weight_scale = weight_tensor.q_scale()
            print(f"  {layer_name} weight: quantized, scale={weight_scale:.6e}")
        except Exception as e:
            print(f"  {layer_name} weight: quantized but failed to get scale ({e}), using dequantize method")
            # 如果获取 scale 失败，反量化再重新量化
            weight = weight_tensor.dequantize().detach().cpu().numpy()
            weight_scale = np.max(np.abs(weight)) / 127.0 if np.max(np.abs(weight)) > 0 else 1e-6
            weight_q = quantize_to_int8(weight, weight_scale)
    else:
        # 浮点权重，手动量化
        weight = weight_tensor.detach().cpu().numpy()
        weight_scale = np.max(np.abs(weight)) / 127.0 if np.max(np.abs(weight)) > 0 else 1e-6
        weight_q = quantize_to_int8(weight, weight_scale)
        print(f"  {layer_name} weight: float, computed scale={weight_scale:.6e}")
    
    # 处理偏置
    bias_q = None
    bias_scale = 1.0
    if bias_key in state_dict:
        bias_tensor = state_dict[bias_key]
        if hasattr(bias_tensor, 'int_repr') and bias_tensor.is_quantized:
            try:
                bias_q = bias_tensor.int_repr().cpu().numpy()
                bias_scale = bias_tensor.q_scale()
            except Exception:
                bias = bias_tensor.dequantize().detach().cpu().numpy()
                bias_scale = np.max(np.abs(bias)) / 127.0 if np.max(np.abs(bias)) > 0 else 1e-6
                bias_q = quantize_to_int8(bias, bias_scale)
        else:
            bias = bias_tensor.detach().cpu().numpy()
            bias_scale = np.max(np.abs(bias)) / 127.0 if np.max(np.abs(bias)) > 0 else 1e-6
            bias_q = quantize_to_int8(bias, bias_scale)
    
    # 写入C数组
    f.write(f"// {layer_name} weights: shape {shape}\n")
    f.write(f"const int8_t {layer_name}_weight[{np.prod(shape)}] __attribute__((aligned(64))) = {{\n")
    write_array_data(f, weight_q.flatten())
    f.write("};\n\n")
    
    if bias_q is not None:
        f.write(f"const int8_t {layer_name}_bias[{len(bias_q)}] __attribute__((aligned(64))) = {{\n")
        write_array_data(f, bias_q)
        f.write("};\n\n")
    
    # 写入scale
    f.write(f"const float {layer_name}_weight_scale = {weight_scale:.8e}f;\n")
    if bias_q is not None:
        f.write(f"const float {layer_name}_bias_scale = {bias_scale:.8e}f;\n")
    f.write("\n")

def export_fc_layer(f, state_dict, layer_name, shape, suffix='', model=None, bit_width=8):
    """导出全连接层权重，支持多比特量化"""
    weight_key = f'{layer_name}.weight'
    bias_key = f'{layer_name}.bias'
    
    if weight_key not in state_dict:
        print(f"Warning: {weight_key} not found in state_dict")
        return
    
    weight_tensor = state_dict[weight_key]
    bias_tensor = state_dict[bias_key] if bias_key in state_dict else None
    
    if weight_tensor is None:
        print(f"Warning: failed to get weight for {layer_name}")
        return
    
    # 手动量化权重 - 根据 bit_width
    weight = weight_tensor.detach().cpu().numpy()
    
    if bit_width == 1:
        # 1-bit: {-1, 1}
        qmin, qmax = -1, 1
        weight_q = np.where(weight >= 0, 1, -1).astype(np.int8)
        weight_scale = np.max(np.abs(weight))
        print(f"  {layer_name} weight: 1-bit quantization")
    elif bit_width == 2:
        # 2-bit: {-2, -1, 0, 1}
        qmin, qmax = -2, 1
        weight_max = np.max(np.abs(weight))
        weight_scale = weight_max / qmax if weight_max > 0 else 1e-6
        weight_q = np.clip(np.round(weight / weight_scale), qmin, qmax).astype(np.int8)
        print(f"  {layer_name} weight: 2-bit quantization, scale={weight_scale:.6e}")
    elif bit_width == 4:
        # 4-bit: [-8, 7]
        qmin, qmax = -8, 7
        weight_max = np.max(np.abs(weight))
        weight_scale = weight_max / qmax if weight_max > 0 else 1e-6
        weight_q = np.clip(np.round(weight / weight_scale), qmin, qmax).astype(np.int8)
        print(f"  {layer_name} weight: 4-bit quantization, scale={weight_scale:.6e}")
    else:
        # 8-bit: [-128, 127]
        qmin, qmax = -128, 127
        weight_max = np.max(np.abs(weight))
        weight_scale = weight_max / qmax if weight_max > 0 else 1e-6
        weight_q = np.clip(np.round(weight / weight_scale), qmin, qmax).astype(np.int8)
        print(f"  {layer_name} weight: 8-bit quantization, scale={weight_scale:.6e}")
    
    # 处理偏置 - 统一用int8
    bias_q = None
    bias_scale = 1.0
    if bias_tensor is not None:
        bias = bias_tensor.detach().cpu().numpy()
        bias_max = np.max(np.abs(bias))
        bias_scale = bias_max / 127.0 if bias_max > 0 else 1e-6
        bias_q = np.clip(np.round(bias / bias_scale), -128, 127).astype(np.int8)
    
    # 写入C数组
    var_name = layer_name.replace('.', '_')
    f.write(f"// {layer_name} weights: shape {shape}\n")
    f.write(f"const int8_t {var_name}_weight[{np.prod(shape)}] __attribute__((aligned(64))) = {{\n")
    write_array_data(f, weight_q.flatten())
    f.write("};\n\n")
    
    if bias_q is not None:
        f.write(f"const int8_t {var_name}_bias[{len(bias_q)}] __attribute__((aligned(64))) = {{\n")
        write_array_data(f, bias_q)
        f.write("};\n\n")
    
    # 写入scale
    f.write(f"const float {var_name}_weight_scale = {weight_scale:.8e}f;\n")
    if bias_q is not None:
        f.write(f"const float {var_name}_bias_scale = {bias_scale:.8e}f;\n")
    f.write("\n")

def write_array_data(f, data, items_per_line=12):
    """写入数组数据，格式化输出"""
    f.write("    ")
    for i, val in enumerate(data):
        if i > 0 and i % items_per_line == 0:
            f.write("\n    ")
        f.write(f"{int(val):4d}, " if i < len(data) - 1 else f"{int(val):4d}")
    f.write("\n")

def export_test_sample(output_path='mnist_test_sample.h', num_samples=5):
    """导出测试样本"""
    from torchvision import datasets, transforms
    
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    
    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)
    
    with open(output_path, 'w') as f:
        f.write("// Auto-generated MNIST test samples\n")
        f.write("// Copyright TU Wien\n\n")
        f.write("#ifndef MNIST_TEST_SAMPLE_H\n")
        f.write("#define MNIST_TEST_SAMPLE_H\n\n")
        f.write("#include <stdint.h>\n\n")
        
        f.write(f"#define NUM_TEST_SAMPLES {num_samples}\n\n")
        
        # 导出样本
        for i in range(num_samples):
            img, label = test_dataset[i]
            img_np = img.squeeze().numpy()
            
            # 量化到int8 (使用相同的归一化参数)
            img_scale = 0.3081 / 127.0
            img_q = quantize_to_int8(img_np * 0.3081, img_scale, zero_point=int(0.1307/img_scale))
            
            f.write(f"// Test sample {i}, label: {label}\n")
            f.write(f"const int8_t test_sample_{i}[784] __attribute__((aligned(64))) = {{\n")
            write_array_data(f, img_q.flatten())
            f.write("};\n\n")
        
        # 导出标签
        f.write(f"const int test_labels[{num_samples}] = {{")
        for i in range(num_samples):
            _, label = test_dataset[i]
            f.write(f"{label}" if i == num_samples - 1 else f"{label}, ")
        f.write("};\n\n")
        
        # 导出样本数组指针
        f.write(f"const int8_t* test_samples[{num_samples}] = {{\n")
        for i in range(num_samples):
            f.write(f"    test_sample_{i}" if i == num_samples - 1 else f"    test_sample_{i},\n")
        f.write("\n};\n\n")
        
        f.write("#endif // MNIST_TEST_SAMPLE_H\n")
    
    print(f"测试样本导出完成: {output_path}")

def main():
    """主导出流程"""
    model_path = 'models/mnist_qat_quantized.pth'
    
    if not os.path.exists(model_path):
        print(f"错误: 找不到模型文件 {model_path}")
        print("请先运行 qat_train_mnist.py 训练模型")
        return
    
    # 创建模型并加载权重
    print(f"从模型加载: {model_path}")
    model = MNISTQATNet()
    model.load_state_dict(torch.load(model_path, map_location='cpu'))
    model.eval()
    
    # 导出到C头文件（使用项目根目录的 test/kernel）
    test_kernel_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'test', 'kernel')
    os.makedirs(test_kernel_dir, exist_ok=True)
    export_weights_to_c_header(model, os.path.join(test_kernel_dir, 'mnist_weights.h'))
    export_test_sample(os.path.join(test_kernel_dir, 'mnist_test_sample.h'), num_samples=5)
    
    print("\n导出完成!")
    print("生成的文件:")
    print(f"  - {os.path.join(test_kernel_dir, 'mnist_weights.h')}")
    print(f"  - {os.path.join(test_kernel_dir, 'mnist_test_sample.h')}")

if __name__ == '__main__':
    main()
