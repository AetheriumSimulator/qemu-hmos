# DevEco 启动与导入回归（#49–53）

针对报告中的 `test-14456eb66216`、DevEco HarmonyOS 7.0.0.107 二合一模拟器，源码修复保留 QEMU 10.1.93/fullcore、target API18 / compatible API17 和现有发布策略。没有混入 Draft #45 的 Phone Core / SDK20 迁移。

## 修复与边界

- **#49 TPM**：当前构建没有可用的内置 TPM 或 swtpm 后端。启动不再无条件发送缺少 `chardev` 的 `-tpmdev emulator`；Native 和兼容性界面报告 TPM 不可用。这解决错误参数引起的退出，不表示 Windows 11 的 TPM 要求已满足，也没有启用最小 TPM2 补丁。
- **#50 固件**：打包时保留 EDK2 CODE 内容并将尾部零填充到 64 MiB，HAP 校验尺寸和 SHA-256。应用使用按内容身份命名的新管理路径，因此升级不复用旧的 2 MiB 沙箱副本。旧固件和自定义固件保留；Native 在进入 QEMU 前检查 pflash 尺寸。已有 VM 的 VARS 不在安装模式下重置，也不将共享模板作为可写 VARS 回退。
- **#51 显卡**：aarch64 `virt` 保留用户选择的 `virtio-gpu-pci`，安装模式也保留。显式 MMIO GPU 使用 modern virtio 传输；未选择显卡的安装模式仍有 ramfb 回退。这里验证的是参数，不能替代 UEFI / 来宾首帧或桌面验收。
- **#52 ISO**：向导和设置页使用原始 DocumentPicker URI 打开文件描述符，等待复制并校验大小后才保存路径。复制失败显示错误并保留原选择；异步回调不能在向导取消后更新选择。每次导入独立分配目录，不再从 VM 名归一化生成 ISO 文件名。弹出只解除挂载，保留可能被旧 VM 共用的文件。
- **#53 磁盘**：初始化沙箱父目录，必要目录的错误传回调用方。新建 VM 独占预留目录；中文名称保留，同名自动添加后缀。只有磁盘复制完成后才加入 VM 列表，旧磁盘拒绝覆盖。失败或取消的导入可能留下空目录或未引用的独立 ISO；重试使用新目录，不自动删除历史用户文件。

修复根据本仓库源码独立实现。报告者的 [说明](https://github.com/BH3GEI/ohmarchy/blob/main/docs/emulator-aetherium.md)与 [补丁脚本](https://github.com/BH3GEI/ohmarchy/blob/main/emulator/lib/patch_aetherium.py)仅供只读核对，未执行二进制 patch 或复制其实现。

## 回归方法

`python3 -m unittest discover -s tools -p 'test_*.py' -v` 执行现有与新增 host 回归。新增测试执行实际 Native 参数生成代码、固件与导入方法，并注入文件系统或平台边界；Node 24 用于剥离 TypeScript 类型。实际 ArkTS/API18 构建及完整 Native/UEFI/HAP/source-evidence 流程由 CI 核验。PR 的最终 commit、具体计数和运行链接记录在 PR 描述中。

Host 测试和编译不能证明真实 DocumentPicker 授权期限、设备文件系统行为、UEFI 首帧、VNC 输入、来宾驱动或安装成功。没有在本次工作中启动 HarmonyOS 模拟器、真机或真实 QEMU 来宾。

## 原环境复测清单

请先备份重要 VM 数据，使用本 PR 对应构建；不要清空应用数据来绕过升级验证。

1. **原沙箱升级**：保留旧的 2 MiB 固件与已有 VM，安装新版后启动 Linux aarch64 `virt`。日志应无缺少 TPM `chardev` 或 pflash 大小错误；旧 CODE、用户自定义固件和已有 VARS 应保持原内容。
2. **显卡**：选择 `virtio-gpu-pci`，分别普通启动与安装启动，确认日志保留该设备。用可用的外部 VNC 客户端确认 UEFI、引导器和来宾图形；内置 VNC 客户端可用性仍是独立事项。
3. **ISO**：向导选择 ISO 后等待复制结束，再创建并安装启动。使用中文同名/不同名 VM 和同名 ISO，确认彼此不会覆盖。模拟不可读源或空间不足，确认显示失败、无不存在的挂载路径，并可重新选择重试。复制期间取消向导后，旧回调不应创建 VM 或更改当前选择。
4. **全新安装**：在独立的干净应用环境直接导入 QCOW2，不先打开设置页。确认能创建 `files/vms`、完成复制并创建 VM。对同名已有 VM 再次导入时，应创建独立后缀名称，原磁盘内容不变。
5. **自定义/异常固件**：尺寸不匹配的显式自定义 pflash 应在 QEMU 启动前得到可读错误，源文件保持不变；修正选择后重试。不要用删除旧 VM 或 NVRAM 作为恢复办法。

PR 保持 Draft、未合并，等待报告者在原 DevEco 环境复核。现有 PR 工作流只验证，不上传 HAP 或发布 Release；运行链接不是可下载构建链接。没有实际产出的下载链接时，必须明确说明。
