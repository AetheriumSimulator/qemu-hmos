# Aetherium 云构建与测试下载

核对日期：2026-10-18（北京时间）；基线 `220702399b91f90dbfaa39335914b8159fe87c84`。本页描述当前工作流，不再沿用历史独立 SO Artifact 流程。

## 已验证的交付

[main run 39027202185](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/39027202185) 成功完成原生库 → ArmVirt/OVMF → 未签名 HAP → 源码/通知收集 → 归档输入重放 → 校验 → Artifact → Release。

[公开测试 Release](https://github.com/AetheriumSimulator/qemu-hmos/releases/tag/test-220702399b91f90dbfaa39335914b8159fe87c84) 有且仅有三项交付资产：

- `aetherium-unsigned.hap`：未签名应用。
- `aetherium-source.tar.gz`：该构建的源码候选归档、配方、SDK 原始通知/元数据及排除项。
- `release-evidence.json`：身份、哈希、来源和未完成评审清单。

2026-10-17 三项公开 URL 已匿名下载并核对哈希；2026-10-18 再次核对发布记录。下载入口和 HAP 哈希见 [README](../README.MD)。不要以 GitHub 自动 “Source code” 压缩包替代 `aetherium-source.tar.gz`，也不要把历史 `prebuilt-libs` 当成本包依赖。

## 事件、步骤与权限

以 [build-complete.yml](../.github/workflows/build-complete.yml) 和 [build-validation.yml](../.github/workflows/build-validation.yml) 为准：

| 事件 / 阶段 | 当前行为 |
| --- | --- |
| main push | 构建并收集；校验通过才上传三资产并发布 unsigned test prerelease。 |
| 面向 main 的 PR / 非 tag 手动运行 | 可以构建和校验；不上传、不发 Release。 |
| tag | 只执行源码前置检查，不是二进制发布触发器。 |
| 其他分支 push | 独立源码检查；不是完整 HAP 分发触发器。 |
| 上传 | 一个 `aetherium-delivery-<SHA>-<run>-<attempt>` Artifact，保留七天；不单独上传 SO/固件。 |
| Release | 按确切 Artifact ID 下载并重新校验，先建草稿、附齐资产，再公开测试 prerelease；不覆盖已有资产。 |
| 权限 | 构建只读；仅独立 Release job 使用已有 `contents: write` 和自动 `GITHUB_TOKEN`。 |

该 run 的 Artifact ID 为 `12099471932`，到期时间为 2026-10-24 11:20:38 UTC。CI 上传及 Release job 下载成功；审查环境直接下载 Actions 存储副本返回403，公开 Release 下载及哈希验证成功。二者不可混写。

## 实际构建配置

- Ubuntu 24.04 hosted runner；原生、固件、HAP 在同一构建任务顺序生成。
- 根 QEMU 10.1.93，`aarch64-softmmu`，TCG/VNC/slirp/curl/pixman；KVM、vhost 系列和 guest agent 在此配方禁用。
- HAP target API 18 / compatible API 17，Hvigor 5.18.6；SDK 精确 URL/哈希以该次 `release-evidence.json` 为准。不是 API 20 phone-core 构建。
- 原生库暂存 `so-artifacts/libs/arm64-v8a`，打包前复制至 `entry/libs/arm64-v8a` 和原生暂存目录；固件由 `firmware-artifacts` 进入 raw resources。这些不是需提交 Git 的预编译文件。
- 三个权威配方：[原生](../.github/actions/validate-so/action.yml)、[UEFI](../.github/actions/validate-uefi/action.yml)、[HAP](../.github/actions/validate-hap/action.yml)。本地脚本不自动等同于它们。

## 如何读结果

`test-disclosure-v1` 允许人工评审未完成时的公开测试分发，同时要求完整性、必需文件、来源与公开缺口披露。`allowed=true` **不是许可合规批准**；严格人工评审模式仍另行存在。见 [交付策略](RELEASE_DELIVERY.md)。

依次查看源码检查、Native、UEFI、HAP、源码收集/重放、上传及 Release 的实际结果。跳过不是成功；HAP 构建、资产下载、归档重放均不能替代签名安装、guest boot、VNC 输入或生命周期真机验收。遇到 SDK、权限或验证失败应读具体日志，不改凭证或绕过校验。
