# 致谢名单

> 本页是第三方来源与历史致谢，不是当前 HAP 的完整 SBOM 或功能验收表。实际打包与限制见 [分发状态](OPEN_SOURCE_STATUS.md) 和 [README](../README.MD)。

我们非常感谢很多开发者的努力 来带来了这个QEMU鸿蒙版App 我们在这个过程引用到了很多代码和相关的设计理念 
以及很多现成的其他开发者做的这些上游的代码啊之类的 我们按照他们的要求开源这个项目 并且引用他们写的 我们
放在这里面用的这些东西   

## 完整名单如下：

### 1. QEMU - Quick Emulator

**项目地址**: https://www.qemu.org/  
**许可证**: GPL-2.0 / LGPL-2.1  
**用途**: 虚拟机核心引擎，提供 ARM64 虚拟化能力  
**致谢**: 感谢 QEMU 项目组提供了强大的开源虚拟化解决方案，使我们能够在 HarmonyOS 设备上运行 Windows 和 Linux 虚拟机。

---

### 2. LibVNC - VNC 服务器和客户端库

**项目地址**: https://github.com/LibVNC/libvncserver  
**许可证**: GPL-2.0  
**用途**: 
- VNC 服务器：用于虚拟机安装阶段的远程桌面显示
- VNC 客户端：用于在 HarmonyOS 应用中显示虚拟机画面

**致谢**: 感谢 LibVNC 项目提供了跨平台的 VNC 实现，使我们能够实现虚拟机的图形界面显示。

---

### 3. FreeRDP - 历史第三方材料（不计划集成）

**项目地址**: https://www.freerdp.com/  
**许可证**: Apache License 2.0  
**范围**：保留上游来源和许可证致谢，不表示当前 HAP 使用其客户端。2026-10-18 产品决定：RDP 与 RemoteApp 不计划实现，旧接入设想不再列入路线图。

**致谢**：感谢 FreeRDP 上游项目提供公开的协议实现和历史参考材料。

---

### 4. OpenSSL - 加密工具库

**项目地址**: https://www.openssl.org/  
**许可证**: Apache License 2.0 / OpenSSL License  
**用途**: 
- 当前原生构建用于 curl/OpenSSL 网络依赖；旧 FreeRDP 关联不是当前集成证据
- 为网络通信提供加密功能

**致谢**: 感谢 OpenSSL 项目提供了强大的加密库，保障了远程连接的安全性。

---

### 5. GLib - C 工具库

**项目地址**: https://wiki.gnome.org/Projects/GLib  
**许可证**: LGPL-2.1  
**用途**: 
- QEMU 的核心依赖库
- 提供数据结构、线程、内存管理等基础功能

**致谢**: 感谢 GNOME 项目提供的 GLib 库，为 QEMU 提供了坚实的基础设施支持。

---

### 6. PCRE2 - Perl 兼容正则表达式库

**项目地址**: https://www.pcre.org/  
**许可证**: BSD License  
**用途**: 
- GLib 的依赖库
- 提供正则表达式匹配功能

**致谢**: 感谢 PCRE2 项目提供了高效的正则表达式库。

---

### 7. Pixman - 像素操作库

**项目地址**: https://cairographics.org/pixman/  
**许可证**: MIT License  
**用途**: 
- QEMU 图形渲染的核心库
- 提供像素级别的图像操作和合成功能

**致谢**: 感谢 Pixman 项目提供了高性能的像素操作库，使虚拟机图形渲染成为可能。

---

### 8. noVNC - HTML5 VNC 客户端

**项目地址**: https://novnc.com/  
**许可证**: MPL-2.0  
**用途**: 
- Web 版本的 VNC 客户端
- 用于在 WebView 中显示虚拟机画面（备选方案）

**致谢**: 感谢 noVNC 项目提供了基于 Web 技术的 VNC 客户端，为跨平台显示提供了另一种选择。

---

## 设计理念参考

### UTM - macOS 虚拟机应用

**项目地址**: https://mac.getutm.app/  
**设计理念**: 
- 在移动设备上运行虚拟机的用户体验设计
- 虚拟机管理界面的交互设计
- 虚拟机配置和启动流程的设计

**致谢**: 感谢 UTM 项目为我们提供了在移动设备上运行虚拟机的设计灵感。我们的目标是打造"鸿蒙版的 UTM"。

---

## 技术参考和研究对象   
### HiSH - 针对鸿蒙平台做的iSH   
**GitHub链接**：https://github.com/harmoninux/HiSH
**许可证**：MIT用户协议
**致谢**：感谢他们的开发者启发了我们，并且促使我们做出来一个适合Windows的自由的鸿蒙VM，以及我们从他们那边借来了一个。

### TermonyHQ/QEMU
**GitHub链接**：https://github.com/TermonyHQ/qemu
**许可证**：？？？
**介绍**：这是针对鸿蒙平台专门优化和适配的QEMU 原本用于一个叫做[Termony](https://github.com/TermonyHQ/Termony)的终端模拟器 但是他是开源的 我们也很高兴使用这个代码来对原版QEMU做深度研究
**致谢**：感谢他们针对鸿蒙平台对QEMU进行适配 来方便我们更加方便的通过UI使用QEMU 并且享受到无缝的体验

---   

## 许可证说明

本项目遵循各开源项目的许可证要求：

- **GPL-2.0 / LGPL-2.1**: QEMU、LibVNC、GLib 等使用 GPL/LGPL 许可证的项目，要求衍生作品也使用相同的许可证。本项目遵循 GPL-2.0 许可证。
- **Apache License 2.0**: FreeRDP、OpenSSL 等使用 Apache 许可证的项目，允许商业使用和修改。
- **MIT License**: Pixman 使用 MIT 许可证，允许自由使用和修改。
- **MPL-2.0**: noVNC 使用 MPL-2.0 许可证，允许在专有软件中使用。

完整的许可证信息请参考各项目的 LICENSE 文件：
- `third_party/qemu/COPYING`
- `third_party/libvnc/COPYING`
- `third_party/freerdp/src/LICENSE`
- `third_party/novnc/LICENSE.txt`
- `third_party/deps/glib/COPYING`
- `third_party/deps/pcre2/LICENSE`
- `third_party/deps/pixman/COPYING`

---

## 特别感谢

感谢所有开源项目的维护者和贡献者，没有你们的努力，这个项目不可能实现。我们承诺：

1. ✅ 遵循所有开源项目的许可证要求
2. ✅ 在项目中明确标注使用的开源项目
3. ✅ 保持项目的开源状态
4. ✅ 回馈开源社区

---

## 如何贡献

如果你发现本项目的致谢名单有任何遗漏或错误，欢迎提交 Issue 或 Pull Request。

我们也会持续关注上游项目的更新，及时同步最新的功能和修复。

---

**最后更新**: 2025-11-21
