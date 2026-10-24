# 当前公开 HAP 的 QEMU 配置

核对日期：2026-10-18（北京时间）。本页依据 [validate-so 配方](../.github/actions/validate-so/action.yml)与 [main run 39027202185](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/39027202185)，不是上游 QEMU 全功能清单。

| 项目 | 当前构建证据 |
| --- | --- |
| 核心 / 来宾目标 | QEMU 10.1.93，`aarch64-softmmu`；不能因 UI 有架构选项或包内有 OVMF 就称 x86 来宾已支持。 |
| TCG / KVM | 启用 TCG；`--disable-kvm`，日志 `KVM support: NO`。JIT 设备权限未验收。 |
| 网络 | 启用 slirp/curl；原生启动代码有 usernet/hostfwd。来宾联网需另测。 |
| 显示 | QEMU VNC/pixman 启用；wrapper 的可选 LibVNCClient 缺失，内置客户端不可用，见 [VNC 状态](VNC_NATIVE.md)。 |
| vhost / VDUSE / guest agent | 此 CI 配方禁用 vhost-user、vhost-net、vhost-kernel、libvduse、vduse-blk-export、guest-agent 等；不能沿用旧文档的“已启用”列表。 |
| 音频 | 实际配置日志 `Audio drivers: oss`。OHAudio 补丁文件存在，但当前 CI 没有执行应用该补丁的本地脚本，不能声称本包验证了 HarmonyOS 音频。 |
| TPM | 当前启动路径不自动创建 TPM，兼容性接口报告不可用。日志 `TPM support: YES` 仅表示通用构建能力；最小 TPM2 兜底补丁未启用，Windows 11 TPM 要求未验证。 |
| 固件 | EDK2 ArmVirt/OVMF 单独构建并打包；并非使用 QEMU 旧预编译 ROM 集合。 |
| 共享目录 | 主启动代码的 virtio-9p 路径禁用；未确认 virtiofs 已接通。 |

上游源码中存在的设备模型、VFIO 对象或可配置参数不等于本机直通、平台授权或真机可用。该 HAP 的实际载荷、SDK 和源码身份见 Release 附带的 `release-evidence.json`。签名、安装、guest boot 和运行效果没有被云构建代替。

独立的 [QEMU 11.1 phone-core](../ports/qemu-11.1/README.md)和 API 20 迁移目标不属于此构建；其 `reentrant=0` 限制仍有效。实现/未验证/规划/明确不做的分类见 [README](../README.MD) 和 [路线图](ROADMAP.md)。
