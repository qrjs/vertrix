#!/usr/bin/env python3
# Copyright TU Wien
# Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""
将量化后的MNIST模型权重导出为C头文件
全部使用int8量化，无偏置
"""

import torch
import numpy as np
from qat_train_mnist import MNISTQATNet
import os
import struct
import sys

def quantize_to_int8(tensor):
    """将浮点张量量化为int8"""
    tensor_max = np.max(np.abs(tensor))
    if tensor_max == 0:
        return np.zeros_like(tensor, dtype=np.int8), 1.0
    scale = tensor_max / 127.0
    quantized = np.clip(np.round(tensor / scale), -128, 127).astype(np.int8)
    return quantized, scale

def export_weights_to_c_header(model, output_path='mnist_weights.h'):
    """导出量化权重到C头文件"""
    
    print("开始导出权重...")
    
    model.eval()
    state_dict = model.state_dict()
    
    with open(output_path, 'w') as f:
        f.write("// Auto-generated MNIST QAT weights (int8, no bias)\n")
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
        f.write("#define CONV1_K 3\n")
        f.write("#define POOL1_OUT_H 14\n")
        f.write("#define POOL1_OUT_W 14\n\n")
        
        f.write("#define CONV2_OUT_C 6\n")
        f.write("#define CONV2_K 3\n")
        f.write("#define POOL2_OUT_H 7\n")
        f.write("#define POOL2_OUT_W 7\n\n")
        
        f.write("#define FC1_IN 294  // 7*7*6\n")
        f.write("#define FC1_OUT 64\n")
        f.write("#define FC2_OUT 32\n")
        f.write("#define FC3_OUT 10\n\n")
        
        # Conv1: weight [3, 1, 3, 3]
        weight = state_dict['conv1.weight'].detach().cpu().numpy()
        weight_q, scale = quantize_to_int8(weight)
        export_weight_array(f, 'conv1', weight_q, (3, 1, 3, 3), scale)
        
        # Conv2: weight [6, 3, 3, 3]
        weight = state_dict['conv2.weight'].detach().cpu().numpy()
        weight_q, scale = quantize_to_int8(weight)
        export_weight_array(f, 'conv2', weight_q, (6, 3, 3, 3), scale)
        
        # FC1: weight [64, 294]
        weight = state_dict['fc1.weight'].detach().cpu().numpy()
        weight_q, scale = quantize_to_int8(weight)
        export_weight_array(f, 'fc1', weight_q, (64, 294), scale)
        
        # FC2: weight [32, 64]
        weight = state_dict['fc2.weight'].detach().cpu().numpy()
        weight_q, scale = quantize_to_int8(weight)
        export_weight_array(f, 'fc2', weight_q, (32, 64), scale)
        
        # FC3: weight [10, 32]
        weight = state_dict['fc3.weight'].detach().cpu().numpy()
        weight_q, scale = quantize_to_int8(weight)
        export_weight_array(f, 'fc3', weight_q, (10, 32), scale)
        
        f.write("#endif // MNIST_WEIGHTS_H\n")
    
    print(f"权重导出完成: {output_path}")

def export_weight_array(f, name, weight_q, shape, scale):
    """导出单个权重数组"""
    f.write(f"// {name} weights: shape {shape}, scale={scale:.8e}\n")
    f.write(f"const int8_t {name}_weight[{np.prod(shape)}] __attribute__((aligned(64))) = {{\n")
    write_array_data(f, weight_q.flatten())
    f.write("};\n\n")
    
    # 打印统计信息
    print(f"  {name}: shape={shape}, range=[{weight_q.min()}, {weight_q.max()}]")

def write_array_data(f, data, items_per_line=16):
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
        f.write("// Auto-generated MNIST test samples (int8)\n")
        f.write("// Copyright TU Wien\n\n")
        f.write("#ifndef MNIST_TEST_SAMPLE_H\n")
        f.write("#define MNIST_TEST_SAMPLE_H\n\n")
        f.write("#include <stdint.h>\n\n")
        
        f.write(f"#define NUM_TEST_SAMPLES {num_samples}\n\n")
        
        # 导出样本
        for i in range(num_samples):
            img, label = test_dataset[i]
            img_np = img.squeeze().numpy()
            
            # 量化到int8
            img_q, scale = quantize_to_int8(img_np)
            
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

def export_fp32_weights_to_c_header(model, output_path='mnist_weights_fp32.h'):
    """导出FP32原始浮点权重到C头文件（不做量化）"""

    print("开始导出FP32权重...")

    model.eval()
    state_dict = model.state_dict()

    with open(output_path, 'w') as f:
        f.write("// Auto-generated MNIST weights (fp32, no bias)\n")
        f.write("// Copyright TU Wien\n")
        f.write("// Licensed under the Solderpad Hardware License v2.1\n\n")
        f.write("#ifndef MNIST_WEIGHTS_FP32_H\n")
        f.write("#define MNIST_WEIGHTS_FP32_H\n\n")

        # 网络尺寸参数
        f.write("// Network dimensions\n")
        f.write("#define INPUT_H 28\n")
        f.write("#define INPUT_W 28\n")
        f.write("#define INPUT_C 1\n\n")

        f.write("#define CONV1_OUT_C 3\n")
        f.write("#define CONV1_K 3\n")
        f.write("#define POOL1_OUT_H 14\n")
        f.write("#define POOL1_OUT_W 14\n\n")

        f.write("#define CONV2_OUT_C 6\n")
        f.write("#define CONV2_K 3\n")
        f.write("#define POOL2_OUT_H 7\n")
        f.write("#define POOL2_OUT_W 7\n\n")

        f.write("#define FC1_IN 294  // 7*7*6\n")
        f.write("#define FC1_OUT 64\n")
        f.write("#define FC2_OUT 32\n")
        f.write("#define FC3_OUT 10\n\n")

        # 导出各层权重
        layers = [
            ('conv1', 'conv1.weight', (3, 1, 3, 3)),
            ('conv2', 'conv2.weight', (6, 3, 3, 3)),
            ('fc1', 'fc1.weight', (64, 294)),
            ('fc2', 'fc2.weight', (32, 64)),
            ('fc3', 'fc3.weight', (10, 32)),
        ]

        all_ok = True
        for name, key, shape in layers:
            weight = state_dict[key].detach().cpu().numpy().flatten()
            f.write(f"// {name} weights: shape {shape}\n")
            f.write(f"const float {name}_weight[{len(weight)}] __attribute__((aligned(64))) = {{\n")
            write_float_array_data(f, weight)
            f.write("};\n\n")
            print(f"  {name}: shape={shape}, range=[{weight.min():.6f}, {weight.max():.6f}]")
            if not verify_fp32_export(weight, name):
                all_ok = False

        f.write("#endif // MNIST_WEIGHTS_FP32_H\n")

    if not all_ok:
        print("ERROR: FP32 export verification FAILED")
        sys.exit(1)

    print(f"FP32权重导出完成: {output_path}")

def write_float_array_data(f, data, items_per_line=12):
    """写入浮点数组数据"""
    f.write("    ")
    for i, val in enumerate(data):
        if i > 0 and i % items_per_line == 0:
            f.write("\n    ")
        suffix = ", " if i < len(data) - 1 else ""
        f.write(f"{val:.8e}f{suffix}")
    f.write("\n")

def verify_fp32_export(weight_np, name):
    """Verify FP32 weight array has no NaN/Inf and string format roundtrips exactly."""
    flat = weight_np.flatten().astype(np.float32)

    nan_count = int(np.sum(np.isnan(flat)))
    inf_count = int(np.sum(np.isinf(flat)))
    if nan_count > 0 or inf_count > 0:
        print(f"  ERROR: {name} has {nan_count} NaN, {inf_count} Inf values")
        return False

    mismatches = 0
    for val in flat:
        original_u32 = struct.unpack('<I', struct.pack('<f', float(val)))[0]
        parsed = np.float32(float(f"{val:.8e}"))
        parsed_u32 = struct.unpack('<I', struct.pack('<f', float(parsed)))[0]
        if original_u32 != parsed_u32:
            mismatches += 1

    if mismatches > 0:
        print(f"  ERROR: {name} has {mismatches}/{len(flat)} bit-exact roundtrip failures")
        return False

    print(f"  VERIFY: {name} OK — {len(flat)} values, no NaN/Inf, bit-exact roundtrip")
    return True

def export_fp32_test_sample(output_path='mnist_test_sample_fp32.h', num_samples=5):
    """导出FP32格式的测试样本"""
    from torchvision import datasets, transforms

    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])

    test_dataset = datasets.MNIST('./data', train=False, download=True, transform=transform)

    with open(output_path, 'w') as f:
        f.write("// Auto-generated MNIST test samples (fp32)\n")
        f.write("// Copyright TU Wien\n\n")
        f.write("#ifndef MNIST_TEST_SAMPLE_FP32_H\n")
        f.write("#define MNIST_TEST_SAMPLE_FP32_H\n\n")

        f.write(f"#define NUM_TEST_SAMPLES {num_samples}\n\n")

        for i in range(num_samples):
            img, label = test_dataset[i]
            img_np = img.squeeze().numpy()

            f.write(f"// Test sample {i}, label: {label}\n")
            f.write(f"const float test_sample_{i}[784] __attribute__((aligned(64))) = {{\n")
            write_float_array_data(f, img_np.flatten())
            f.write("};\n\n")

        # 标签
        f.write(f"const int test_labels[{num_samples}] = {{")
        for i in range(num_samples):
            _, label = test_dataset[i]
            f.write(f"{label}" if i == num_samples - 1 else f"{label}, ")
        f.write("};\n\n")

        # 样本指针数组
        f.write(f"const float* test_samples[{num_samples}] = {{\n")
        for i in range(num_samples):
            f.write(f"    test_sample_{i}" if i == num_samples - 1 else f"    test_sample_{i},\n")
        f.write("\n};\n\n")

        f.write("#endif // MNIST_TEST_SAMPLE_FP32_H\n")

    print(f"FP32测试样本导出完成: {output_path}")

def main():
    """主导出流程"""

    model_path = 'models/mnist_qat_quantized.pth'

    if not os.path.exists(model_path):
        print(f"错误: 找不到模型文件 {model_path}")
        print("请先运行 qat_train_mnist.py 训练模型")
        sys.exit(1)

    # 创建模型并加载权重
    print(f"从模型加载: {model_path}")
    model = MNISTQATNet()
    model.load_state_dict(torch.load(model_path, map_location='cpu'))
    model.eval()

    test_kernel_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'test', 'kernel')
    os.makedirs(test_kernel_dir, exist_ok=True)

    # 判断导出格式
    fmt = sys.argv[1] if len(sys.argv) > 1 else 'int8'

    if fmt == 'fp32':
        export_fp32_weights_to_c_header(model, os.path.join(test_kernel_dir, 'mnist_weights_fp32.h'))
        export_fp32_test_sample(os.path.join(test_kernel_dir, 'mnist_test_sample_fp32.h'), num_samples=5)
        print("\nFP32导出完成!")
    elif fmt == 'all':
        export_weights_to_c_header(model, os.path.join(test_kernel_dir, 'mnist_weights.h'))
        export_test_sample(os.path.join(test_kernel_dir, 'mnist_test_sample.h'), num_samples=5)
        export_fp32_weights_to_c_header(model, os.path.join(test_kernel_dir, 'mnist_weights_fp32.h'))
        export_fp32_test_sample(os.path.join(test_kernel_dir, 'mnist_test_sample_fp32.h'), num_samples=5)
        print("\n全格式导出完成!")
    else:
        export_weights_to_c_header(model, os.path.join(test_kernel_dir, 'mnist_weights.h'))
        export_test_sample(os.path.join(test_kernel_dir, 'mnist_test_sample.h'), num_samples=5)
        print("\nINT8导出完成!")

if __name__ == '__main__':
    main()
