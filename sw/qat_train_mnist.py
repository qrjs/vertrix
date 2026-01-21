import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import os

# 网络参数定义
INPUT_SIZE = 28
CONV1_OUT_CHANNELS = 3
CONV2_OUT_CHANNELS = 6
FC1_IN = 294  # 7*7*6
FC1_OUT = 120
FC2_OUT = 1024
FC3_OUT = 10


class QuantizedLinear(nn.Module):
    def __init__(self, in_features, out_features, bit_width=8, bias=True):
        super(QuantizedLinear, self).__init__()
        self.in_features = in_features
        self.out_features = out_features
        self.bit_width = bit_width
        
        self.weight = nn.Parameter(torch.Tensor(out_features, in_features))
        if bias:
            self.bias = nn.Parameter(torch.Tensor(out_features))
        else:
            self.register_parameter('bias', None)
        
        nn.init.kaiming_uniform_(self.weight, a=torch.nn.init.calculate_gain('relu'))
        if self.bias is not None:
            nn.init.zeros_(self.bias)
        
        if bit_width == 1:
            self.qmin, self.qmax = -1, 1
        elif bit_width == 2:
            self.qmin, self.qmax = -2, 1
        elif bit_width == 4:
            self.qmin, self.qmax = -8, 7
        else:
            self.qmin, self.qmax = -128, 127
    
    def quantize_weight(self, weight):
        # 计算scale：将权重范围映射到[qmin, qmax]
        weight_max = torch.max(torch.abs(weight))
        if weight_max == 0:
            scale = 1.0
        else:
            scale = weight_max / self.qmax
        
        if self.bit_width == 1:
            weight_q = torch.where(
                weight >= 0,
                torch.tensor(1.0, device=weight.device),
                torch.tensor(-1.0, device=weight.device),
            )
        else:
            weight_q = torch.clamp(torch.round(weight / scale), self.qmin, self.qmax)
        
        weight_dq = weight_q * scale
        
        return weight + (weight_dq - weight).detach()
    
    def forward(self, x):
        # 对权重进行量化感知训练
        weight_q = self.quantize_weight(self.weight)
        return F.linear(x, weight_q, self.bias)
    
    def extra_repr(self):
        return f'in_features={self.in_features}, out_features={self.out_features}, bit_width={self.bit_width}'


class MNISTQATNet(nn.Module):
    """MNIST QAT网络，包含真正的多比特量化分支"""
    def __init__(self):
        super(MNISTQATNet, self).__init__()
        
        # Conv layers - 使用标准层，后面会用int8量化
        self.conv1 = nn.Conv2d(1, CONV1_OUT_CHANNELS, kernel_size=3, stride=1, padding=1)
        self.relu1 = nn.ReLU()
        self.pool1 = nn.MaxPool2d(kernel_size=2, stride=2)
        
        self.conv2 = nn.Conv2d(CONV1_OUT_CHANNELS, CONV2_OUT_CHANNELS, kernel_size=3, stride=1, padding=1)
        self.relu2 = nn.ReLU()
        self.pool2 = nn.MaxPool2d(kernel_size=2, stride=2)
        
        # FC layers - 使用标准层
        self.fc1 = nn.Linear(FC1_IN, FC1_OUT)
        self.relu3 = nn.ReLU()
        
        self.fc2 = nn.Linear(FC1_OUT, FC2_OUT)
        self.relu4 = nn.ReLU()
        
        # FC3 三路分支 - 使用自定义量化层，不同bit宽
        self.fc3_1bit = QuantizedLinear(FC2_OUT, FC3_OUT, bit_width=1)
        self.fc3_2bit = QuantizedLinear(FC2_OUT, FC3_OUT, bit_width=2)
        self.fc3_4bit = QuantizedLinear(FC2_OUT, FC3_OUT, bit_width=4)
        
        # 用于量化前面层的fake quantize
        self.register_buffer('conv1_weight_scale', torch.tensor(1.0))
        self.register_buffer('conv2_weight_scale', torch.tensor(1.0))
        self.register_buffer('fc1_weight_scale', torch.tensor(1.0))
        self.register_buffer('fc2_weight_scale', torch.tensor(1.0))
        
    def quantize_conv_weight(self, weight, scale_name):
        """对卷积层权重进行int8量化感知"""
        weight_max = torch.max(torch.abs(weight))
        if weight_max == 0:
            scale = torch.tensor(1.0, device=weight.device)
        else:
            scale = weight_max / 127.0
        
        # 更新scale
        setattr(self, scale_name, scale)
        
        # 量化和反量化
        weight_q = torch.clamp(torch.round(weight / scale), -128, 127)
        weight_dq = weight_q * scale
        
        # Straight-through estimator
        return weight_dq + (weight - weight).detach()
    
    def quantize_fc_weight(self, weight, scale_name):
        """对全连接层权重进行int8量化感知"""
        return self.quantize_conv_weight(weight, scale_name)
    
    def forward(self, x, branch='4bit'):
        # Conv1 with quantization
        weight_q = self.quantize_conv_weight(self.conv1.weight, 'conv1_weight_scale')
        x = F.conv2d(x, weight_q, self.conv1.bias, 
                     stride=self.conv1.stride, padding=self.conv1.padding)
        x = self.relu1(x)
        x = self.pool1(x)
        
        # Conv2 with quantization
        weight_q = self.quantize_conv_weight(self.conv2.weight, 'conv2_weight_scale')
        x = F.conv2d(x, weight_q, self.conv2.bias,
                     stride=self.conv2.stride, padding=self.conv2.padding)
        x = self.relu2(x)
        x = self.pool2(x)
        
        # Flatten
        x = x.reshape(x.size(0), -1)
        
        # FC1 with quantization
        weight_q = self.quantize_fc_weight(self.fc1.weight, 'fc1_weight_scale')
        x = F.linear(x, weight_q, self.fc1.bias)
        x = self.relu3(x)
        
        # FC2 with quantization
        weight_q = self.quantize_fc_weight(self.fc2.weight, 'fc2_weight_scale')
        x = F.linear(x, weight_q, self.fc2.bias)
        x = self.relu4(x)
        
        # FC3 分支 - 使用不同bit宽的量化层
        if branch == '1bit':
            x = self.fc3_1bit(x)
        elif branch == '2bit':
            x = self.fc3_2bit(x)
        else:  # 4bit
            x = self.fc3_4bit(x)
        
        return x


def prepare_data(batch_size=64):
    """准备MNIST数据集"""
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    
    train_dataset = datasets.MNIST('./data', train=True, download=False, transform=transform)
    test_dataset = datasets.MNIST('./data', train=False, download=False, transform=transform)
    
    train_loader = DataLoader(train_dataset, batch_size=batch_size, shuffle=True)
    test_loader = DataLoader(test_dataset, batch_size=batch_size, shuffle=False)
    
    return train_loader, test_loader


def train_one_epoch(model, device, train_loader, optimizer, criterion, epoch):
    """训练一个epoch"""
    model.train()
    running_loss = 0.0
    correct = 0
    total = 0
    
    for batch_idx, (data, target) in enumerate(train_loader):
        data, target = data.to(device), target.to(device)
        
        optimizer.zero_grad()
        
        # 三个分支的输出和损失
        output_1bit = model(data, '1bit')
        output_2bit = model(data, '2bit')
        output_4bit = model(data, '4bit')
        
        loss_1bit = criterion(output_1bit, target)
        loss_2bit = criterion(output_2bit, target)
        loss_4bit = criterion(output_4bit, target)
        
        # 总损失 - 可以调整权重
        loss = loss_1bit + loss_2bit + loss_4bit
        
        loss.backward()
        optimizer.step()
        
        running_loss += loss.item()
        
        # 使用4bit分支计算准确率
        _, predicted = output_4bit.max(1)
        total += target.size(0)
        correct += predicted.eq(target).sum().item()
        
        if batch_idx % 100 == 0:
            print(f'Epoch: {epoch} [{batch_idx * len(data)}/{len(train_loader.dataset)} '
                  f'({100. * batch_idx / len(train_loader):.0f}%)]\t'
                  f'Loss: {loss.item():.6f}')
    
    accuracy = 100. * correct / total
    avg_loss = running_loss / len(train_loader)
    print(f'Epoch {epoch}: Avg Loss: {avg_loss:.4f}, Accuracy: {accuracy:.2f}%')
    return avg_loss, accuracy


def test(model, device, test_loader, criterion):
    """测试模型"""
    model.eval()
    test_loss = 0
    correct_1bit = 0
    correct_2bit = 0
    correct_4bit = 0
    total = 0
    
    with torch.no_grad():
        for data, target in test_loader:
            data, target = data.to(device), target.to(device)
            
            output_1bit = model(data, '1bit')
            output_2bit = model(data, '2bit')
            output_4bit = model(data, '4bit')
            
            loss_1bit = criterion(output_1bit, target)
            loss_2bit = criterion(output_2bit, target)
            loss_4bit = criterion(output_4bit, target)
            test_loss += (loss_1bit + loss_2bit + loss_4bit).item()
            
            _, pred_1bit = output_1bit.max(1)
            _, pred_2bit = output_2bit.max(1)
            _, pred_4bit = output_4bit.max(1)
            
            total += target.size(0)
            correct_1bit += pred_1bit.eq(target).sum().item()
            correct_2bit += pred_2bit.eq(target).sum().item()
            correct_4bit += pred_4bit.eq(target).sum().item()
    
    test_loss /= len(test_loader)
    acc_1bit = 100. * correct_1bit / total
    acc_2bit = 100. * correct_2bit / total
    acc_4bit = 100. * correct_4bit / total
    
    print(f'\nTest set: Avg loss: {test_loss:.4f}')
    print(f'1-bit branch Accuracy: {acc_1bit:.2f}%')
    print(f'2-bit branch Accuracy: {acc_2bit:.2f}%')
    print(f'4-bit branch Accuracy: {acc_4bit:.2f}%\n')
    
    return test_loss, acc_1bit, acc_2bit, acc_4bit


def main():
    """主训练流程"""
    epochs = 10
    batch_size = 64
    learning_rate = 0.001
    
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f'Using device: {device}')
    print('\n=== Quantization Configuration ===')
    print('Conv1/Conv2/FC1/FC2: int8 (8-bit) quantization')
    print('fc3_1bit: 1-bit weight quantization')
    print('fc3_2bit: 2-bit weight quantization')
    print('fc3_4bit: 4-bit weight quantization')
    print('===================================\n')
    
    # 数据
    train_loader, test_loader = prepare_data(batch_size)
    
    # 模型
    model = MNISTQATNet().to(device)
    
    # 打印模型结构
    print('Model structure:')
    print(model)
    print()
    
    # 优化器和损失函数
    optimizer = optim.Adam(model.parameters(), lr=learning_rate)
    criterion = nn.CrossEntropyLoss()
    
    # 训练
    print('Starting Quantization-Aware Training...')
    for epoch in range(1, epochs + 1):
        train_loss, train_acc = train_one_epoch(model, device, train_loader, 
                                                 optimizer, criterion, epoch)
        test_loss, acc_1bit, acc_2bit, acc_4bit = test(model, device, 
                                                         test_loader, criterion)
    
    # 保存模型
    model.eval()
    os.makedirs('models', exist_ok=True)
    torch.save(model.state_dict(), 'models/mnist_qat_quantized.pth')
    
    print('\nTraining completed! Model saved to models/')
    print(f'Final accuracies:')
    print(f'  1-bit: {acc_1bit:.2f}%')
    print(f'  2-bit: {acc_2bit:.2f}%')
    print(f'  4-bit: {acc_4bit:.2f}%')
    
    return model


if __name__ == '__main__':
    main()
