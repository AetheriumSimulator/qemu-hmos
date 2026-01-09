# Aetherium for HarmonyOS（HMOS）
## 让鸿蒙也能离线跑 Windows / Linux —— 一个“鸿蒙版 UTM”的实验项目

想象一下，你的鸿蒙设备瞬间变身为一台虚拟机：不用 root、不靠破解、尽量少黑魔法，直接在本地跑来宾系统。

> ⚠️ **小字说明**：本项目仍处于实验阶段，功能/兼容性在快速迭代中。请仅在合法镜像 / 自测环境下使用。  
> **免责声明**：请在拥有合法授权的镜像 / 系统环境下使用。本项目不对外提供商业支持，也不承担任何损失或法律责任。  

---

## 这是什么？

**Aetherium** 是一个运行在 **HarmonyOS NEXT** 上的虚拟机应用：  
- ArkTS（UI/页面） + C++（NAPI/桥接）驱动虚拟机生命周期  
- QEMU 以 **in-process（库形式）**集成到应用里（`libqemu_full.so`），而不是启动一个外部 qemu 进程  

> 仓库名字历史原因可能仍叫 `qemu-hmos`，但产品/项目名以 **Aetherium** 为准。

---

## 核心特性（已实现 / 实验中）

- [x] **Windows 11 ARM / Linux ARM64 虚拟机**：在 MatePad / 鸿蒙电脑上运行 aarch64 来宾系统  
- [x] **网络**：`usernet + hostfwd`（默认 RDP / VNC 端口映射）  
- [x] **显示链路**：安装和运行阶段均可 **VNC**；如果可以则使用 **RDP** 嵌入渲染  
- [x] **StartProgram（App 内）**：在 Aetherium 应用内点击图标即可拉起来宾系统里的指定 EXE（通过 RDP 通道）  
  - 说明：当前不支持把“来宾 App”固定到鸿蒙桌面（RemoteApp / RAIL 尚未实现）；桌面快捷方式目前仅用于快速启动/绑定某个 VM（见 `entry/src/main/resources/base/profile/shortcuts_config.json`）  
- [x] **文件共享（当前方案）**：通过 **virtiofs** 透传共享目录，把 App 沙箱目录映射为来宾可见目录/盘符  
  - 说明：**不使用 9P（virtio-9p）** 来透传文件  
- [x] **音频（实验）**：内置 HarmonyOS **OHAudio audiodev**（`aether-soundkit-hmos`）  
  - 目标：让 VNC 场景也能听到声音，并支持麦克风回传（需要麦克风权限）  
- [x] **TPM（实验）**：QEMU 构建显式启用 TPM，并提供 HarmonyOS 环境的最小 TPM2 兜底  
  - 说明：这保证 `-tpmdev` 参数链路可用、不会把 App 直接带崩；**不承诺通过 Windows 11 完整 TPM 认证**  

---

## 还没做（规划中 / 未实现）

- **RemoteApp / RAIL（尚未实现）**：目前仍以“完整桌面 RDP”体验为主  
- **快照 / 恢复**  
- 更完善的文件共享（例如 Samba/双向同步/剪贴板集成等）  
- GPU / USB 等更深度的虚拟化支持与兼容性完善  

---

## 性能与系统限制（必须先说清）

- **`/dev/kvm` 不可用**：我们发现华为 HarmonyOS NEXT 设备目前**不向第三方应用暴露 `/dev/kvm`**。华为的方法则是使用**HMV（HarmonyOS Virtualization）**，但是这个并不对我们开放。我们正在申请这个相关权限以便在以后获取更加快速的虚拟化性能，如果您掌握这个权限并且想要参与贡献，请务必告诉我们；目前会自动降级到 **TCG**（性能会很卡）。  
- **JIT / 可执行内存限制**：部分机型/系统版本对 JIT 有权限与签名要求；未满足条件时性能会明显下降。  

---

## 构建与开发（重要：别在仓库根目录跑 `./configure`）

### 1) 拉取源码（请您务必带子模块）

```bash
git clone --recurse-submodules https://github.com/AetheriumSimulator/qemu-hmos.git
cd qemu-hmos
git submodule update --init --recursive
```

**一眼自检：你到底有没有拉到子模块？**

```bash
# 看到 third_party/qemu/configure 才算子模块正常
ls third_party/qemu/configure
```

### 2) 在 WSL / Linux 里交叉编译 QEMU（推荐）

> Windows `cmd.exe` 不能直接运行 `.sh`。请使用 **WSL / Linux / Git Bash**。

```bash
export OHOS_NDK_HOME=/path/to/harmonyos-sdk/linux/native

bash tools/build_ohos_deps.sh
bash tools/build_qemu_full_linux.sh
```

产物默认输出到：
- `entry/src/main/libs/arm64-v8a/libqemu_full.so`（以脚本提示为准）

### 3) App 侧构建/运行

请用 **DevEco Studio** 打包安装到设备（本仓库不建议在终端直接跑 hvigor）。

---

## 常见报错（新手必看）

### 1) `./configure: 没有那个文件或目录`

你多半是在 **仓库根目录**执行了 `./configure`。本项目根目录没有 `configure`，正确位置是：
- `third_party/qemu/configure`

推荐做法：直接跑构建脚本
- `bash tools/build_qemu_full_linux.sh`

如果你一定要手动编译 QEMU，也请进入子模块目录：

```bash
cd third_party/qemu
./configure --target-list=aarch64-softmmu
```

### 2) `make: *** 没有指明目标并且找不到 makefile。 停止。`

你多半是在 **错误目录**（比如仓库根目录）直接 `make` 了。  
QEMU 的 `Makefile` 不在根目录，并且通常需要先 `./configure`（或脚本生成构建目录）后再编译。

### 3) “找不到任何 .sh 文件 / 不能运行 .sh”

这通常是因为你在 Windows 的 `cmd.exe` 环境里执行 `.sh`。请改用：
- WSL
- Linux 终端
- Git Bash（能力有限，优先 WSL）

> 经验法则：只要命令里出现 `bash xxx.sh`，就别用 Windows cmd。

---

## 许可证（非常重要）

本仓库是**多许可证**结构：
- **QEMU（`third_party/qemu`）**：遵循上游 QEMU 的 GPL 许可证（见 `third_party/qemu/COPYING`）
- 我们App使用到的[其他项目（详见星河合伙人页面）](docs/STARRIVER_PARTNER.md)，均遵循其他代码自带的许可证！  
- **本项目自研代码**（如 `entry/`、`tools/`、`scripts/`、`patches/` 等）：采用 **Apache-2.0** 开源（见 `LICENSE-APACHE`）  
- **其他 third_party 组件**：遵循各自上游许可证（例如 FreeRDP、OpenSSL、GLib/Pixman/PCRE2 等）  

> 说明：根目录的 `LICENSE` 当前放的是 GPL 文本，主要用于对 QEMU 相关分发/修改的合规提示；请以本节的“多许可证说明”理解整个仓库。  
> 非法律建议：若你要发布二进制或做商业分发，请自行评估 GPL/Apache/第三方许可证的合规要求。  

---

## 贡献指南

欢迎大家一起参与，特别需要的方向包括：  
- UI / 交互体验提升  
- 稳定性 / 性能优化 / Bug 修复  
- 新系统 / 来宾镜像模板支持  
- 音频/输入/显示链路的兼容性完善  
- 文档 / 教程 / 示例镜像（合法合规）  

