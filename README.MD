# Aetherium for HarmonyOS（HMOS）

Aetherium 是实验性的开源本地虚拟机应用：ArkTS 界面通过 C++/N-API 调用进程内 QEMU。目标是让 HarmonyOS 设备运行来宾系统；**目前已验证云端构建和公开测试分发，尚未建立本测试包的真机安装、Windows/Linux 启动及稳定运行验收记录**。

本页核对日期：**2026-10-18（北京时间）**；源码基线为 `220702399b91f90dbfaa39335914b8159fe87c84`。这里描述的是本仓库的 **Aetherium**，不代表商业 **Aether** 的代码、许可证、应用商店版本或产品能力。

## 已验证的测试版与下载

[公开测试 Release：test-2207023](https://github.com/AetheriumSimulator/qemu-hmos/releases/tag/test-220702399b91f90dbfaa39335914b8159fe87c84) 来自 [PR #42](https://github.com/AetheriumSimulator/qemu-hmos/pull/42) 合并后的 [main 构建 39027202185](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/39027202185)。原生库、两种 UEFI、HAP、源码收集、归档输入重放、上传和测试 prerelease 发布均成功。

| 下载项 | 内容 |
| --- | --- |
| [aetherium-unsigned.hap](https://github.com/AetheriumSimulator/qemu-hmos/releases/download/test-220702399b91f90dbfaa39335914b8159fe87c84/aetherium-unsigned.hap) | 未签名测试应用，55,998,657 字节；设备安装可能需要自行签名和配置。 |
| [aetherium-source.tar.gz](https://github.com/AetheriumSimulator/qemu-hmos/releases/download/test-220702399b91f90dbfaa39335914b8159fe87c84/aetherium-source.tar.gz) | 与该构建匹配的源码候选归档、构建配方、原始 SDK 通知/元数据及排除项。 |
| [release-evidence.json](https://github.com/AetheriumSimulator/qemu-hmos/releases/download/test-220702399b91f90dbfaa39335914b8159fe87c84/release-evidence.json) | HAP/源码哈希、成员清单、依赖来源、SDK 身份和未完成评审事项。 |

三项资产已在 2026-10-17 通过匿名下载及哈希复核，2026-10-18 再次核对发布记录。HAP SHA-256：

```text
0f16e219c3c007e80a607de3060ad5c11cc442af17b184f8c2bcbde733ff7405
```

请使用上述 **`aetherium-source.tar.gz`**；GitHub 自动生成的 “Source code (zip/tar.gz)” 不是这份构建匹配源码归档。归档输入重放不是完整的干净源码到 HAP 重建，也不证明对应源码已经完整验收。

当前 `test-disclosure-v1` 是**公开披露未完成评审的测试分发策略**，不是许可合规批准。实际组合许可评估、SDK 运行库下游源码/补丁映射及源码完整性审查仍未完成，见 [分发状态](docs/OPEN_SOURCE_STATUS.md) 和 [交付策略](docs/RELEASE_DELIVERY.md)。未签名或短期保留不使产物变成私有。

## 当前构建与下一代核心不是同一条链路

| 项目 | 当前公开 HAP | 独立开发材料 / 目标 |
| --- | --- | --- |
| QEMU | 根子模块固定 `9c23f2a7…`，版本 10.1.93；构建 `libqemu_full.so`，当前只配置 `aarch64-softmmu`。 | [QEMU 11.1 phone-core 源码导出](ports/qemu-11.1/README.md)及重建配方；尚未接入根 HAP。 |
| HarmonyOS API | [构建配置](build-profile.json5)为 target 5.1.0/API 18、compatible 5.0.5/API 17；这是声明，不是机型兼容认证。 | phone-core/API 20 是后续迁移目标，不能用其材料描述当前包。 |
| 加速 / 生命周期 | CI 启用 TCG、禁用 KVM；有启动、停止、状态、日志等源码，未验收设备上的完整生命周期。 | phone entry 明确 `reentrant=0`，拒绝第二次会话；不能宣称已支持同进程反复启动或 A→B→A。 |
| 固件 | 从 EDK2 构建 ArmVirt 和 OVMF 并打包。 | OVMF 在包内不代表当前核心已支持 x86_64 来宾。 |

[独立 LibVNC 来源材料](ports/libvnc/README.md)也不等于根 HAP 已链接可用的原生 VNC 客户端。源码树重建成功不能替代 HAP 对应关系或设备验收。

## 实现状态：已有代码不等于真机通过

“源码存在”表示有接口或实现；“云构建通过”表示该构建链路成功；“公开测试分发”表示有可下载资产。以下未提供设备记录的项目均不能标为“真机已验证”。

| 能力 | 当前证据与限制 |
| --- | --- |
| 原生集成与 HAP | **云构建、打包及公开分发通过**。`libqemu_full.so`、`libqemu_hmos.so`、C++ 运行库及两种固件已校验；不是启动成功证明。见 [构建配置](.github/actions/validate-so/action.yml)。 |
| Windows 11 ARM / Linux ARM64 | 有来宾参数、磁盘和固件配置代码；**本发布包的安装、引导、桌面及兼容性未验收**，不再宣称已在 MatePad/鸿蒙电脑稳定运行。 |
| VM 创建、磁盘与日志 | 有创建向导、配置存储、QCOW2 创建、日志和错误报告代码；QCOW2 扩容路径依赖外部 `qemu-img`，当前 HAP 未交付该工具。见 [原生实现](entry/src/main/cpp/napi_init.cpp)、[VM 管理](entry/src/main/ets/managers/QemuVMManager.ets)。 |
| 启动 / 停止 / 暂停 / 恢复 | 有线程、关闭请求、QMP 和状态处理；完整生命周期、退出清理、并发多 VM、反复启动未验收。暂停/恢复及快照的 wrapper 注册表与主启动路径的接通还需验证，不能用接口返回值代替实际来宾状态。 |
| 快照 | **不是“完全没做”**：Worker、N-API 和 [wrapper](entry/src/main/cpp/qemu_wrapper.cpp)已有 `savevm/loadvm/delvm/info snapshots` 路径。端到端连接、错误判断、存储一致性和恢复结果尚未验收。 |
| 网络 | QEMU 构建启用 slirp/curl；[启动参数](entry/src/main/cpp/napi_init.cpp)包含 usernet/hostfwd。端口配置不代表来宾网络或 RDP 客户端已工作，真机联网未验证。 |
| VNC 显示与输入 | QEMU VNC 服务端已启用；有原生客户端、帧回调、键盘/指针及 ArkTS 页面源码。**当前 CI 缺少 LibVNCClient 静态库，客户端编译为不可用分支**，不能称内置 VNC 可操作。见 [VNC 状态](docs/VNC_NATIVE.md)。 |
| RDP / RemoteApp / RAIL | **明确不计划实现，不在项目范围**（2026-10-18 产品决定）。旧注释、端口转发和 FreeRDP 材料是历史遗留，不是待开发或待验收承诺。 |
| 来宾应用启动 / StartProgram | [Apps 页面](entry/src/main/ets/pages/Apps.ets)明确提示远程应用不可用并转向 VNC；基于 RDP/RemoteApp 的旧启动方案不再列入路线图，不能宣称支持一键 EXE 或来宾应用桌面固定。 |
| 文件共享 | 有配置字段和相关页面，但主启动路径中的 virtio-9p 被注释禁用；未确认接通 virtiofs。不能宣称已映射共享目录、盘符、剪贴板或双向同步。 |
| 音频 / 麦克风 | 有 [OHAudio 补丁](patches/qemu/0002-ohos-ohaudio-audiodev.patch)及参数代码；当前 CI 不调用应用该补丁的本地构建脚本，实际日志为 `Audio drivers: oss`。不能据此称当前 HAP 已验证 OHAudio 后端，设备播放/录音未验收。 |
| TPM / Windows 11 配置 | 有配置代码及 [最小 TPM2 补丁](patches/qemu/0001-ohos-builtin-minimal-tpm2.patch)；实际日志 `TPM support: YES` 仅说明通用构建能力，补丁存在不证明当前 CI 应用了它。TPM 行为、Windows 检测及安装兼容性未验证。 |
| 镜像下载 | 有下载页面、任务/进度与 Range 请求相关代码；下载服务、断点恢复和实况窗等设备行为未验收。不是镜像授权或下载成功承诺。 |
| AET / Guest Tools | 未找到本仓库完整 AET 交付或与此 HAP 配套的验收记录；[Guest Tools 工作流](.github/workflows/build-guest-tools.yml)仍含 TODO，且其独立旧门禁保持关闭。不能借用商业产品能力填充本仓库状态。 |
| 硬件虚拟化 / JIT | 有 KVM/JIT 探测代码，但**当前 CI 明确 `--disable-kvm`**；没有 HMV 接入成功或权限获批证据。TCG 构建通过不证明某台设备获得 JIT 权限，也不证明 TCI 自动回退已接通。 |
| GPU / USB / 摄像头 | 虚拟设备参数、上游设备模型或 VFIO 对象不代表鸿蒙设备直通可用；未建立本包的 GPU/USB/摄像头接入验收。 |
| 跨设备连续性 / 商业愿景 | 世界日记、Bubbles、CSN、跨设备世界和云端连续性不属于本仓库已交付能力；不将商业 Aether 的描述或商店状态当作 Aetherium 实现证据。 |

待办与验收顺序见 [路线图](docs/ROADMAP.md)。历史笔记中的勾选项或“完成”字样不应覆盖本页的构建匹配状态。

## 构建、安装与贡献

```bash
git clone --recurse-submodules https://github.com/AetheriumSimulator/qemu-hmos.git
cd qemu-hmos
git submodule update --init --recursive
```

复现当前测试包请以 [云构建说明](docs/CLOUD_BUILD_README.md)、三个 [原生](.github/actions/validate-so/action.yml) / [固件](.github/actions/validate-uefi/action.yml) / [HAP](.github/actions/validate-hap/action.yml) 构建配方和发布证据为准。`tools/build_qemu_full_linux.sh` 是另一条本地配方，不能未经对比就视为当前 CI 的等价流程。不要在根目录执行 `./configure`，QEMU 源码位于 `third_party/qemu`。

发布包未签名。设备测试需在自己的开发环境配置签名/安装材料，记录设备、系统版本、包哈希、启动日志和实际来宾结果；不要提交证书、密钥或密码。Hosted CI 没有连接真机。参见 [源码维护说明](docs/PUBLIC_SOURCE.md)。

本次文档核对对应的回归套件为 73 项；它验证工作流边界、产物证据及源码重建逻辑，不是 73 项真机功能验收。贡献时请把“新增代码”“构建通过”“设备实测”分别报告。

## 许可证与范围

仓库包含多许可证代码：项目自有代码的 [Apache-2.0](LICENSE-APACHE) 不替代 QEMU 和其他第三方组件的许可证；对第三方的补丁遵循相应上游要求。根 [LICENSE](LICENSE)、组件原文及发布归档中的通知需要结合实际打包内容阅读，不能给整个组合简单贴一个已批准标签。

GPL 软件可商业使用；开源仓库可见性、独立 `.so`、`dlopen` 或测试版发布均不自动证明组合许可和完整对应源码已经验收。[分发状态](docs/OPEN_SOURCE_STATUS.md)列出当前证据与缺口。本仓库不提供商业 Aether 的代码或授权结论。
