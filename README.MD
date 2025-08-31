# QEMU for HarmonyOS (HMOS)

在 **HarmonyOS NEXT**（鸿蒙平板 & 鸿蒙电脑）上以 **App** 形态运行 QEMU，提供本机可离线使用的 Windows / Linux 虚拟机能力。  
项目面向**个人自用**场景：不 root、不破解、不依赖 HNP（平板不支持）；以 **QEMU 作为 .so 库内嵌**，默认 **TCG JIT**，运行时探测 KVM 并自动降级。

> ⚠️ 免责声明：请仅在拥有合法授权的镜像/系统上使用。本项目仅作研究与个人测试，不建议对外分发。
> 本项目不提供任何形式的技术支持，也不负责任何形式的损失或伤害。
> 本项目的作者不承担任何因使用本项目而导致的任何损失或伤害。
> QEMU专指Quick Emulator模拟器 感谢QEMU的开发者帮助打造上游生态!
---

## ✨ 特性

-  在 MatePad / MateBook（HarmonyOS NEXT）上运行 **Windows 11 ARM**、**Linux ARM64**（来宾）
-  **离线可用**：QEMU 使用 `hostfwd` → 宿主 `127.0.0.1` 访问来宾（如 RDP 3390→3389）
-  安装期 VNC 观察；日常通过 **内嵌 RDP 视图** 使用
-  **Apps 启动**：支持 *StartProgram*（点击鸿蒙侧图标 → 直接拉起指定 Windows 程序窗口）
-  **共享文件夹**：RDP 驱动器重定向（将 App 沙箱目录映射为来宾盘符，如 `Z:`）
-  媒体控制透传（DVC + GSMTC → 鸿蒙 AVSession，WIP）
-  快照/休眠/恢复（WIP）
-  RemoteApp/RAIL 真·应用发布（WIP）
-  virtiofs/9p/Samba 长挂载（WIP）

> KVM：大多数设备/容器**不会暴露** `/dev/kvm` 给第三方 App。项目在运行时探测：可用则 `-accel kvm`，否则自动使用 `-accel tcg,thread=multi`。

---

## 📦 环境与前置

- **DevEco Studio 5+**，HarmonyOS NEXT SDK（API 12+）
- **开发者证书 + 调试签名**（启用 JIT / 可执行内存）
- 目标设备：HarmonyOS NEXT 平板或电脑（开启开发者选项）
- 构建依赖（本机）：`cmake` / `meson` / `ninja` / C/C++ toolchain  
  （用于编译 `libqemu.so` 与可选的 FreeRDP）

---

## 🏗️ 架构简述

```
app/
  entry/ArkTS UI（虚拟机 / Apps / 我的）
  native/ NAPI 桥（startVm/stopVm 等）
  libs/arm64-v8a/libqemu.so        ← 内嵌的 QEMU（aarch64-softmmu）
  assets/QEMU_EFI.fd               ← EDK2 固件
  assets/tools/                    ← 首启脚本、驱动等（可选）
```

- **QEMU 作为库**：导出 `qemu_main(argc, argv)`；App 内以线程方式启动主循环  
- **显示**：安装期 `-display vnc=:1`；日常嵌入 RDP 视图连接 `127.0.0.1:3390`
- **网络**：user-net + `hostfwd`（离线也可用）
- **KVM/JIT**：运行时 `open("/dev/kvm") + KVM_GET_API_VERSION` 探测；前置调用 `prctl("jit",1)`（开发签名下）

---

## 🚀 快速开始

1. **克隆仓库**
   ```bash
   git clone https://github.com/caidingding233/qemu-hmos.git
   ```
2. **配置签名**
   - 在 DevEco Studio 中为本 App 配置 **开发者证书 + 调试签名**（用于 JIT）
3. **编译 QEMU 为库**
   - 建议目标：`aarch64-softmmu`；可选开启 TCI 兜底（无 JIT 时仍可运行但性能较低）
   - 典型（示例）：
     ```bash
     ./configure --target-list=aarch64-softmmu \
                 --enable-tcg --disable-debug-info \
                 --disable-modules
     make -j$(nproc)
     # 产出 libqemu.so（或将 qemu-system-aarch64 的入口重命名为 qemu_main 并链接为 .so）
     ```
   - 将产物放入：`app/entry/libs/arm64-v8a/libqemu.so`
4. **准备固件与资源**
   - 将 `QEMU_EFI.fd` 放入 `app/entry/src/main/resources/rawfile/`（或 assets）
5. **运行到设备**
   - 连接鸿蒙设备（平板/电脑），运行工程

---

## 🖥️ 创建与安装来宾系统

1. 在 App 的 **虚拟机** 页创建 VM：选择 Windows 11 ARM 或 Linux ARM64
2. 选择/下载 ISO（支持断点续传与 SHA 校验）
3. 创建磁盘（比如 `win11arm.qcow2`，默认 64 GB）
4. 启动安装（安装期使用 VNC 观察）
5. 安装完成后，App 将改用 RDP 连接 `127.0.0.1:3390` 进入系统

> 典型 QEMU 参数（由 App 生成）：
```text
-machine virt,gic-version=3,virtualization=on
-cpu max -smp 4 -m 6144
-accel tcg,thread=multi,tb-size=128
-bios QEMU_EFI.fd
-drive if=none,id=d0,file=win11arm.qcow2,format=qcow2,cache=writeback,aio=threads,discard=unmap
-device nvme,drive=d0,serial=nvme0
-netdev user,id=n0,hostfwd=tcp:127.0.0.1:3390-:3389
-device virtio-net-pci,netdev=n0
```

---

## 🧰 首启增强（可选，一键配置）

- 启用 RDP、添加本地账户、放通防火墙
- 安装 VirtIO 驱动、QEMU Guest Agent（Windows）
- 将 App 沙箱目录映射为 `Z:`（RDP 驱动器重定向）
- （WIP）媒体桥（GSMTC）自启，支持播放状态透传

---

## 📱 Apps 启动与桌面集成

- **StartProgram**：在 **Apps** 页为某个 Windows 程序创建入口 → 点击即连接并拉起指定 EXE  
- **桌面图标**
  - 鸿蒙电脑：若系统允许**读写桌面目录**，可编程写入快捷方式文件
  - 平板：使用**静态快捷方式/服务卡片**，用户“固定到桌面”

---

## 🩺 故障排查（FAQ）

- **找不到 `/dev/kvm` / 无法打开**  
  这是预期：容器通常不暴露 KVM。项目会自动降级到 `tcg`。  
- **JIT 打不开**  
  确认使用开发者证书 + 调试签名；若仍失败，TCI 仍可运行但性能有限。  
- **RDP 连接不上**  
  确认 VM 内已启用远程桌面；端口映射为 `hostfwd tcp:127.0.0.1:3390-:3389`；安装期可先用 VNC。  
- **文件互通**  
  优先使用 RDP 驱动器重定向；长期建议切 virtiofs/9p（WIP）。

---

## 🗺️ Roadmap（摘录）

- MVP：QEMU 内嵌（TCG + JIT）、VNC 安装 + RDP 使用、Apps StartProgram、RDP 驱动器重定向
- V1：媒体控制透传（DVC + GSMTC + AVSession）、快照/休眠/恢复、下载器可视化
- V2：RemoteApp/RAIL、virtiofs/9p/Samba、图形与输入高级适配、多系统模板

---

## 🤝 贡献

欢迎提交 Issue / PR。建议先描述设备型号、HarmonyOS 版本、是否可用 JIT/KVM、问题复现步骤与日志。

---

## 📄 许可证

见仓库内[LICENSE](LICENSE)。