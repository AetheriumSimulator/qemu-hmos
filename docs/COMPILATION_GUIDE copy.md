# 🚀 QEMU HarmonyOS 项目编译指南

## 📋 项目介绍
这是一个在HarmonyOS上运行QEMU虚拟机的项目，支持运行Windows/Linux ARM虚拟机。

## 🎯 编译目标
- `libqemu_full.so` - QEMU核心库
- `libqemu_hmos.so` - HarmonyOS NAPI封装
- `edk2-aarch64-code.fd` - ARM64 UEFI固件
- `OVMF_CODE.fd` - x86_64 UEFI固件

## 🛠️ 编译环境要求

### 硬件要求
- **推荐**: ARM64 Ubuntu虚拟机 (8GB+ RAM)
- **备选**: x86_64 Linux (用于交叉编译)

### 软件要求
- Ubuntu 20.04+ 或 ARM64 Ubuntu
- HarmonyOS SDK 5.0.1+ (推荐6.0)
- Python 3.8+
- CMake 3.20+
- GCC/Clang

## 📥 第一步：获取项目

```bash
# 克隆项目
git clone <repository-url>
cd qemu-hmos

# 初始化子模块
git submodule update --init --recursive
```

## 🔧 第二步：安装HarmonyOS SDK

### ARM64原生编译 (推荐)
```bash
# 🚨 重要：ARM64系统必须下载ARM64版本的SDK！
# 不要下载x86_64版本，否则编译器会无法执行！

# 方法1：从华为官网下载（推荐）
# 1. 打开浏览器：https://developer.huawei.com/consumer/cn/download/
# 2. 搜索 "HarmonyOS SDK"
# 3. 选择 "Command line tools" 版本
# 4. ⚠️ 务必下载 ARM64 版本（不是 x86_64！）
# 5. 下载完成后重命名为 ohos-sdk-linux-arm64-public.tar.gz

# 方法2：尝试自动下载（可能不存在）
wget https://repo.huaweicloud.com/harmonyos/os/6.0-Release/ohos-sdk-linux-arm64-public.tar.gz

# 安装到/opt/ohos-sdk
sudo mkdir -p /opt/ohos-sdk
sudo tar -xzf ohos-sdk-linux-arm64-public.tar.gz -C /opt
sudo mv /opt/linux/* /opt/ohos-sdk/ 2>/dev/null || sudo mv /opt/linux /opt/ohos-sdk

# 验证安装 - 检查是否有ARM64编译器
ls -la /opt/ohos-sdk/native/llvm/bin/
file /opt/ohos-sdk/native/llvm/bin/aarch64-unknown-linux-ohos-clang
```

### 交叉编译 (x86_64主机)
```bash
# SDK会由构建脚本自动下载
# 无需手动安装
```

## 🏗️ 第三步：编译项目

### 方法1：ARM64原生编译 (推荐)

```bash
# 确保在项目根目录
cd /path/to/qemu-hmos

# 运行ARM原生构建脚本
./scripts/build-arm-native.sh
```

### 方法2：自动全量编译

```bash
# 适用于任何Linux环境，自动下载SDK
./scripts/build-local-complete.sh
```

### 方法3：ARM虚拟机专用

```bash
# 针对ARM虚拟机优化
./scripts/build-arm-vm.sh
```

## 📂 输出文件

编译成功后，生成的文件：

```
entry/src/main/cpp/build/
├── libqemu_hmos.so          # HarmonyOS NAPI封装

third_party/qemu/build/
├── libqemu_full.so          # QEMU核心库

entry/src/main/resources/rawfile/
├── edk2-aarch64-code.fd     # ARM64 UEFI固件
└── OVMF_CODE.fd            # x86_64 UEFI固件
```

## 📦 第四步：构建HAP包

```bash
# 使用hvigor构建HarmonyOS应用包
hvigor assembleDebug

# 输出位置
entry/build/outputs/hap/debug/
```

## 🔍 第五步：部署测试

```bash
# 安装到HarmonyOS设备
hdc install entry/build/outputs/hap/debug/*.hap

# 或者推送到远程设备
hdc install -r entry/build/outputs/hap/debug/*.hap
```

## 🐛 常见问题解决

### 问题1：CMake执行失败 - "无法执行二进制文件"
```bash
# 🚨 最常见问题：下载了错误的SDK架构！

# 检查当前架构
uname -m  # 应该输出 "aarch64"

# 如果是ARM64系统，但下载了x86_64 SDK，会出现此错误

# 解决方案：
# 1. 删除错误的SDK
rm -rf /opt/ohos-sdk ohos-sdk*

# 2. 下载正确的ARM64 SDK（见上面的安装步骤）
# 3. 重新安装到 /opt/ohos-sdk
# 4. 重新运行构建脚本
./scripts/build-arm-native.sh
```

### 问题5：UEFI编译失败
```bash
# 检查edk2子模块
git submodule status

# 重新初始化
git submodule update --init --recursive
```

## 🎯 验证编译结果

```bash
# 检查文件大小和权限
ls -lh entry/src/main/cpp/build/*.so
ls -lh third_party/qemu/build/*.so
ls -lh entry/src/main/resources/rawfile/*.fd

# 检查文件类型
file entry/src/main/cpp/build/libqemu_hmos.so
file third_party/qemu/build/libqemu_full.so
```

## 📞 获取帮助

如果编译遇到问题：
1. 检查系统架构：`uname -m`
2. 验证SDK路径：`ls -la /opt/ohos-sdk/`
3. 查看详细日志：重新运行脚本并保存输出
4. 清理重试：删除build目录重新编译

## 🎉 编译成功标志

看到以下输出即表示编译成功：

```
✅ libqemu_full.so created
✅ libqemu_hmos.so created
✅ ARM64 UEFI firmware built successfully
✅ x86_64 UEFI firmware built successfully
🎉 All components built successfully!
```

然后就可以用 `hvigor assembleDebug` 构建最终的HarmonyOS应用了！
