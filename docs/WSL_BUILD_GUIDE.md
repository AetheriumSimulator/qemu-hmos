# WSL 构建指南

## 概述

由于 HarmonyOS NDK 只提供 x86-64 版本，在 ARM64 Linux 系统上无法直接编译。推荐使用 **WSL（Windows Subsystem for Linux）** 进行编译。

## 为什么使用 WSL？

1. ✅ **架构兼容**：WSL 运行在 x86-64 架构上，可以使用 x86-64 版本的 HarmonyOS NDK
2. ✅ **轻量级**：比完整虚拟机更轻量，启动更快
3. ✅ **官方推荐**：华为/鸿蒙团队推荐使用 WSL
4. ✅ **易于集成**：可以直接访问 Windows 文件系统

## 前置要求

### 1. 安装 WSL

在 Windows PowerShell（管理员权限）中运行：

```powershell
# 安装 WSL（如果尚未安装）
wsl --install

# 或者安装特定发行版（推荐 Ubuntu 22.04）
wsl --install -d Ubuntu-22.04
```

### 2. 安装构建工具

在 WSL 中安装必要的构建工具：

```bash
sudo apt update
sudo apt install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    curl \
    wget \
    file \
    binutils
```

### 3. 下载 HarmonyOS NDK

```bash
# 创建目录
mkdir -p ~/command-line-tools/sdk/default/openharmony/native
cd ~/command-line-tools/sdk/default/openharmony/native

# 下载 NDK（x86-64 Linux 版本）
wget https://repo.huaweicloud.com/openharmony/os/5.1.0-Release/ohos-sdk-windows_linux-public.tar.gz

# 解压
tar -xzf ohos-sdk-windows_linux-public.tar.gz

# 设置环境变量（添加到 ~/.bashrc 或 ~/.zshrc）
echo 'export OHOS_NDK_HOME="$HOME/command-line-tools/sdk/default/openharmony/native"' >> ~/.bashrc
source ~/.bashrc
```

### 4. 验证 NDK 安装

```bash
# 检查 NDK 路径
echo $OHOS_NDK_HOME

# 运行检查脚本
cd /mnt/c/path/to/qemu-hmos  # 或你的项目路径
bash tools/check_ndk_linux.sh
```

## 构建步骤

### 1. 克隆/访问项目

如果项目在 Windows 文件系统中，可以直接访问：

```bash
# Windows 路径映射到 /mnt/c/
cd /mnt/c/Users/YourUsername/projects/qemu-hmos
```

或者将项目克隆到 WSL 文件系统中（性能更好）：

```bash
cd ~/projects
git clone <your-repo-url> qemu-hmos
cd qemu-hmos
```

### 2. 构建依赖库

```bash
# 构建基础依赖（GLib, PCRE2, Pixman, OpenSSL）
bash tools/build_ohos_deps.sh

# 构建 LibVNC（如果需要）
bash tools/build_libvnc_ohos.sh

# RDP / RemoteApp 不计划实现；不再提供 FreeRDP 构建待办。
```

### 3. 构建 libqemu_hmos.so

```bash
# 使用 Linux 构建脚本
bash tools/build_libqemu_hmos_linux.sh
```

### 4. 验证构建结果

```bash
# 检查生成的库文件
file entry/src/main/libs/arm64-v8a/libqemu_hmos.so

# 应该显示：ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), dynamically linked, stripped
```

## 常见问题

### Q1: WSL 中无法访问 Windows 文件系统？

**A:** 确保使用 `/mnt/c/` 路径访问 Windows C 盘。如果性能有问题，建议将项目复制到 WSL 文件系统中。

### Q2: 编译速度慢？

**A:** 
- 将项目放在 WSL 文件系统中（`~/projects/`），而不是 Windows 文件系统（`/mnt/c/`）
- 使用 `-j$(nproc)` 启用并行编译
- 确保 WSL 分配了足够的 CPU 和内存

### Q3: 如何配置 WSL 资源？

在 Windows 用户目录下创建 `.wslconfig`：

```ini
[wsl2]
memory=8GB
processors=4
swap=2GB
```

然后重启 WSL：

```powershell
wsl --shutdown
```

### Q4: 编译完成后如何将文件复制到 Windows？

**A:** 如果项目在 Windows 文件系统中，文件会自动同步。如果在 WSL 文件系统中，可以使用：

```bash
# 复制到 Windows 目录
cp entry/src/main/libs/arm64-v8a/libqemu_hmos.so /mnt/c/path/to/windows/project/entry/src/main/libs/arm64-v8a/
```

## 完整构建流程示例

```bash
# 1. 进入项目目录
cd ~/projects/qemu-hmos

# 2. 检查 NDK
bash tools/check_ndk_linux.sh

# 3. 构建依赖
bash tools/build_ohos_deps.sh

# 4. 构建 libqemu_hmos.so
bash tools/build_libqemu_hmos_linux.sh

# 5. 验证
ls -lh entry/src/main/libs/arm64-v8a/libqemu_hmos.so
file entry/src/main/libs/arm64-v8a/libqemu_hmos.so
```

## 下一步

构建完成后，`libqemu_hmos.so` 会位于 `entry/src/main/libs/arm64-v8a/` 目录中。你可以：

1. 在 macOS/Windows 上使用 `hvigor` 构建完整的 HarmonyOS 应用
2. 将 `.so` 文件提交到版本控制系统
3. 在 CI/CD 中使用 WSL 进行自动化构建

## 参考链接

- [WSL 官方文档](https://learn.microsoft.com/zh-cn/windows/wsl/)
- [HarmonyOS NDK 下载](https://repo.huaweicloud.com/openharmony/os/5.1.0-Release/)
- [项目构建文档](../docs/BUILD_GUIDE.md)

