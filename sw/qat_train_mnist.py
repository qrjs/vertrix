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
FC1_OUT = 64
FC2_OUT = 32
FC3_OUT = 10

# 内存分析 (int8权重):
# conv1: 3*1*3*3 = 27 bytes
# conv2: 6*3*3*3 = 162 bytes
# fc1: 64*294 = 18,816 bytes (~18KB)
# fc2: 32*64 = 2,048 bytes (~2KB)
# fc3: 10*32 = 320 bytes
# 总计: ~21KB (可放入248KB RAM)


class MNISTQATNet(nn.Module):
    """MNIST QAT网络，全部使用int8量化，无偏置"""
    def __init__(self):
        super(MNISTQATNet, self).__init__()
        
        # Conv layers - 无偏置
        self.conv1 = nn.Conv2d(1, CONV1_OUT_CHANNELS, kernel_size=3, stride=1, padding=1, bias=False)
        self.relu1 = nn.ReLU()
        self.pool1 = nn.MaxPool2d(kernel_size=2, stride=2)
        
        self.conv2 = nn.Conv2d(CONV1_OUT_CHANNELS, CONV2_OUT_CHANNELS, kernel_size=3, stride=1, padding=1, bias=False)
        self.relu2 = nn.ReLU()
        self.pool2 = nn.MaxPool2d(kernel_size=2, stride=2)
        
        # FC layers - 无偏置
        self.fc1 = nn.Linear(FC1_IN, FC1_OUT, bias=False)
        self.relu3 = nn.ReLU()
        
        self.fc2 = nn.Linear(FC1_OUT, FC2_OUT, bias=False)
        self.relu4 = nn.ReLU()
        
        self.fc3 = nn.Linear(FC2_OUT, FC3_OUT, bias=False)
        
    def quantize_weight(self, weight):
        """对权重进行int8量化感知"""
        weight_max = torch.max(torch.abs(weight))
        if weight_max == 0:
            scale = torch.tensor(1.0, device=weight.device)
        else:
            scale = weight_max / 127.0
        
        # 量化和反量化
        weight_q = torch.clamp(torch.round(weight / scale), -128, 127)
        weight_dq = weight_q * scale
        
        # Straight-through estimator
        return weight + (weight_dq - weight).detach()
    
    def forward(self, x):
        # Conv1 with quantization
        weight_q = self.quantize_weight(self.conv1.weight)
        x = F.conv2d(x, weight_q, bias=None, 
                     stride=self.conv1.stride, padding=self.conv1.padding)
        x = self.relu1(x)
        x = self.pool1(x)
        
        # Conv2 with quantization
        weight_q = self.quantize_weight(self.conv2.weight)
        x = F.conv2d(x, weight_q, bias=None,
                     stride=self.conv2.stride, padding=self.conv2.padding)
        x = self.relu2(x)
        x = self.pool2(x)
        
        # Flatten
        x = x.reshape(x.size(0), -1)
        
        # FC1 with quantization
        weight_q = self.quantize_weight(self.fc1.weight)
        x = F.linear(x, weight_q, bias=None)
        x = self.relu3(x)
        
        # FC2 with quantization
        weight_q = self.quantize_weight(self.fc2.weight)
        x = F.linear(x, weight_q, bias=None)
        x = self.relu4(x)
        
        # FC3 with quantization
        weight_q = self.quantize_weight(self.fc3.weight)
        x = F.linear(x, weight_q, bias=None)
        
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
        
        output = model(data)
        loss = criterion(output, target)
        
        loss.backward()
        optimizer.step()
        
        running_loss += loss.item()
        
        _, predicted = output.max(1)
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
    correct = 0
    total = 0
    
    with torch.no_grad():
        for data, target in test_loader:
            data, target = data.to(device), target.to(device)
            
            output = model(data)
            test_loss += criterion(output, target).item()
            
            _, predicted = output.max(1)
            total += target.size(0)
            correct += predicted.eq(target).sum().item()
    
    test_loss /= len(test_loader)
    accuracy = 100. * correct / total
    
    print(f'\nTest set: Avg loss: {test_loss:.4f}, Accuracy: {accuracy:.2f}%\n')
    
    return test_loss, accuracy


def main():
    """主训练流程"""
    epochs = 10
    batch_size = 64
    learning_rate = 0.001
    
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f'Using device: {device}')
    print('\n=== Quantization Configuration ===')
    print('All layers: int8 (8-bit) quantization, no bias')
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
    best_acc = 0.0
    for epoch in range(1, epochs + 1):
        train_loss, train_acc = train_one_epoch(model, device, train_loader, 
                                                 optimizer, criterion, epoch)
        test_loss, test_acc = test(model, device, test_loader, criterion)
        
        if test_acc > best_acc:
            best_acc = test_acc
    
    # 保存模型
    model.eval()
    os.makedirs('models', exist_ok=True)
    torch.save(model.state_dict(), 'models/mnist_qat_quantized.pth')
    
    print('\nTraining completed! Model saved to models/')
    print(f'Best accuracy: {best_acc:.2f}%')
    
    return model


if __name__ == '__main__':
    main()
