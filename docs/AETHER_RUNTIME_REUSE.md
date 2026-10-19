# Aether / Aetherium 运行时复用方案

核对时间：2026-10-19（北京时间）。源码基线：
`98b4d7b583911cb45a3e46b08bce4c64e2137b9f`（PR #44 合并后）。
本文及 `runtime/` 是公开侧工程准备，不是私有 Aether 已接入、真机可用或闭源组合发行获准的证明。

## 仓库身份与授权范围

本次 GitHub 连接列出 37 个可访问仓库；后续偏移页为空。检查仓库元数据、
与产品相关的搜索结果及一份候选仓库 README，未找到足以确认其为目标
**私有 Aether 消费者 App** 的证据。不依据相似名称推定身份。
不能据此断言目标不存在，只能认定本次连接未确认目标。
不在公开文档中公布无关私有仓库清单，不复制其文件或配置。
私有侧比较、修改与迁移均未完成。

[PR #36](https://github.com/AetheriumSimulator/qemu-hmos/pull/36)
确认的公开范围继续有效：QEMU / LibVNC 移植及通用运行时可以公开维护；
Onboarding、Bubbles、世界手账、品牌素材等不因本次工作被自动公开。
这个范围决定本次可以编辑的材料，并不能改变第三方 GPL 对特定组合发行的要求。

## 当前依赖与两条不能混用的核心路径

| 层 | 已检查的源码 | 当前关系与风险 |
| --- | --- | --- |
| 根 HAP / fullcore | `entry/src/main/cpp/napi_init.cpp`、`tools/build_qemu_full_linux.sh`、`.github/workflows/build-qemu-so.yml` | QEMU 10.1.93 根子模块；N-API 自行加载 fullcore 的 init / main_loop / cleanup 等符号；不是 Phone ABI。包含线程、退出拦截、参数、QMP、渲染与输入逻辑。 |
| 旧 Native Wrapper | `entry/src/main/cpp/qemu_wrapper.cpp`、`.h` | 另有 dlopen、VM 配置、线程、状态、monitor、日志等逻辑；其中加载路径寻找 phone_run，尾部还有 legacy qemu_main/main 查询。这些路径不能当成统一已验收实现。 |
| Phone Core 导出 | `ports/qemu-11.1/overlay/qemu_hmos_phone_exports.c`、`.map` | 对外暴露 `qemu_hmos_phone_run` 和 marker；ARM64 TCI；marker 为 `reentrant=0`。核心自己负责 init / loop / cleanup；不得再次调用旧清理接口。未接入根 HAP。 |
| LibVNC viewer | `napi_init.cpp` 的 `LIBVNC_HAVE_CLIENT` 分支、`entry/src/main/cpp/third_party/libvncclient/` | N-API 直接使用 rfbClient 等类型；不是纯 ArkUI 展示层。CMake 根据 archive 是否存在启用客户端。 |
| LibVNC 静态链接 | `entry/src/main/cpp/CMakeLists.txt` | 条件地用 `--whole-archive` 链入 libvncclient.a / libvncserver.a；缺失时走 stub/受限路径。构建配置不是已进入某个 HAP 的证据。 |
| ArkUI / ArkTS | `entry/src/main/ets/managers/QemuVMManager.ets`、`VNCNativeClient.ets`、`pages/VNCNativeViewer.ets` | VM 管理器经 Worker / N-API 调用 Native；viewer 包含具体图像和输入适配。管理器现有 `startVm(): boolean` 不能表达完整启动状态。 |
| 产品模块 | 私有目标未确认 | 不推定具体依赖；只建立运行时结果与产品状态之间的转换契约，不迁移消费者页面。 |

[当前开源状态](OPEN_SOURCE_STATUS.md)描述的成功构建、测试 Release 与来源收集只适用于
其指定 fullcore 包。Phone 源码重建、单个符号和 ABI 检查均不能替代这个对应关系。

## 本次实现：独立、可复用的 Phone 适配器

新增 `runtime/`，不改根 HAP 构建、固件、Phone overlay 或既有发布门禁。
它是后续 Phone 迁移的一条明确调用路径，而不是 fullcore 的即插即用替换品。

| 文件 | 职责 |
| --- | --- |
| `runtime/include/aether_runtime.h` | C ABI v1；加载、阻塞运行、状态查询、线程局部错误文本。 |
| `runtime/src/aether_runtime.cpp` | 唯一核心加载与调用实现；只接受明确绝对路径；校验准确 Phone marker 和函数符号；不猜路径或回退 fullcore；保留核心句柄与 argv 存储。 |
| `runtime/harmonyos/napi_runtime.cpp` | 可选 N-API 模块；在 async work 中 load/run，完成后返回 Promise 结果；不在 ArkUI 线程执行 QEMU。 |
| `runtime/arkts/index.d.ts` | ArkTS 消费契约，`bridgeCode`、可空 `coreExitCode`、`error`、`state`。不是产品 UI。 |
| `runtime/CMakeLists.txt` | 独立共享库目标与可选 N-API/主机测试；没有导入旧应用大文件。 |
| `runtime/tests/` | 合成 DSO 的 ABI、错误、并发、一次性会话、argv 拷贝与非零退出码测试。 |
| `.github/workflows/shared-runtime.yml` | 只验证主机契约；不生成或发布 HAP。 |

新源文件使用明确的 `GPL-2.0-or-later` 标识；没有重许可历史 Apache 文件、第三方补丁
或产品模块。许可标识与工程模块化都不提供专有链接例外。

### 调用与状态语义

1. 从固定提交构建一次 `libaether_runtime.so`；两项目通过固定版本依赖引用同一源目标，
   不复制 `qemu_wrapper.cpp` 或 `napi_init.cpp` 形成分叉。
2. 宿主负责选择可信核心、核对发布清单哈希、申请文件/麦克风等权限、提供绝对沙箱路径；
   loader 只检查 ABI，不验证供应链或未知 DSO 的安全性。加载本身会运行 DSO constructor。
3. 在一条 Native worker / N-API async work 中传入 argv（包含 argv[0]）。
   参数规划由公开运行时层维护，产品只提供内存、镜像等数据；不要让 UI 拼 shell 命令。
4. 状态为 `UNLOADED → READY → RUNNING → CONSUMED`；参数错误不消耗会话。
   核心一经调用，即使初始化失败也消耗会话。并发调用返回 BUSY。
   重复 load 相同路径不重置状态，不能绕过一次性限制。
5. `AETHER_OK` 表示函数成功返回；QEMU 非零退出码是单独字段。
   Promise 在 QEMU 返回后才完成，不能用它表示“启动成功”或“来宾就绪”。
6. 本版不实现 QMP stop/pause/snapshot、画面、输入或 guest-ready 事件。
   这些应作为独立通道，基于标准 QMP/RFB，后续收敛已有实现，不能提前在 UI 宣称可用。
   N-API async work 使用系统工作池，长会话占用一个 worker；池容量与应用退出行为需设备验收。

纯 Native 调用（工作线程内）：

```cpp
#include <aether_runtime.h>
const char *argv[] = {"qemu-system-aarch64", "-machine", "virt", /* ... */};
int result = aether_runtime_load(AETHER_RUNTIME_ABI, trustedCorePath);
int coreExit = 0;
if (result == AETHER_OK) {
    result = aether_runtime_run(sizeof(argv) / sizeof(argv[0]), argv, &coreExit);
}
// 在本线程复制 aether_runtime_last_error() 后，再投递到 UI。
```

上例中的省略项必须由经过验证的机器/固件/TCI 配方补齐，不能直接用于来宾启动验收。
同进程不要并行启用旧 wrapper 和新适配器，也不要装载两份运行时副本；
marker 不会证明两个 loader 的状态一致。不得通过卸载 DSO、重建句柄或强杀线程实现“重启”。

### 构建与依赖固定

推荐让 Aether 的源码依赖（git submodule 或组织内受控依赖锁）指向本公开仓库的
不可变提交，宿主 `add_subdirectory(<checkout>/runtime)` 并链接 `aether_runtime`。
只编译 `runtime/` 目标，不把根 entry App 加进消费者 App。
单一进程只打包一份共享运行时；HAP 需要同时收集运行时、Phone Core 和真实依赖。

```sh
cmake -S runtime -B /tmp/aether-runtime -DAETHER_RUNTIME_TESTS=ON
cmake --build /tmp/aether-runtime --parallel 2
ctest --test-dir /tmp/aether-runtime --output-on-failure
```

设备构建需使用真实 SDK 的 OHOS CMake toolchain，关闭主机测试，可选开启
`-DAETHER_RUNTIME_NAPI=ON`；此模块名为 `aether_runtime_napi`，需按宿主工程配置
oh-package 与 Native 类型声明。未提供 SDK 安装路径猜测，未验证 API 20 编译或打包。
N-API 模块与 `libaether_runtime.so` 均须进入目标 HAP 的 Native 依赖集合。

## 文件迁移清单与后续收敛顺序

| 来源 | 目标/动作 | 本次状态 |
| --- | --- | --- |
| `ports/qemu-11.1/**` | 继续在公开仓库维护；固定 patch/overlay/manifest 构建，输出源码身份及哈希 | 保留，不改历史来源清单 |
| `runtime/**` | 两项目唯一 Phone ABI 适配实现 | 新增；主机合成核心验证，设备未验证 |
| `qemu_wrapper.cpp` 的 load/run 与 N-API 的核心调用 | 确认私有目标及核心版本后，逐调用点接到同一运行时；先删除旧双路径再启用新路径 | 未搬移；根 HAP 仍使用旧 fullcore |
| `napi_init.cpp` 的参数规划、QMP、日志 | 拆成公开配置/控制/诊断模块，保留原行为测试；不要整体复制进消费者 App | 清单阶段 |
| N-API 表面 | Phone 宿主可选使用新的小桥；fullcore 需另写版本化 backend，不能套 Phone marker | 新小桥已写，SDK 编译未验证；fullcore backend 未实现 |
| `ports/libvnc/**` 与 vendor headers | 对齐固定上游、构建 recipe 和 archive 实际身份，再整理 viewer；保留 GPL 来源 | 未修改；recipe hash 漂移仍未解决 |
| Native VNC / XComponent | 公开 viewer 运行时，UI 仅消费独立帧/输入契约；实际包含关系需发行审查 | 未搬移；不能把 GPL 类型简单藏在私有 N-API 内 |
| ArkTS VM Manager / Worker | 改为识别 bridgeCode、coreExitCode、QMP-ready 与 consumed；移除“bool 即成功”假设 | 新声明已给出；现有管理器未改 |
| Onboarding / Bubbles / 世界手账 / 账号 / 品牌 | 保持在已确认的消费者仓库；只交换用户意图与运行时状态 | 未读取或复制目标代码 |
| signing / AGC / SDK 配置 | 留在宿主本地/私有配置；公开模板不含凭据 | 无变更 |

需完成两个独立里程碑：先以 mock 与真实 Phone core 验证独立运行时；然后选定一款
HarmonyOS 宿主验收启动、失败、退出、权限拒绝及 UI 可观察状态。
之后才修改已有 HAP 的默认 backend，并建立新的包到源码映射。

## 逐项许可与发行检查

以下是基于已读源码和许可文本的工程核对，不是对未知私有组合的法律结论。

| 组件/关系 | 许可证据 | 义务、未决问题与处理 |
| --- | --- | --- |
| QEMU 整体与修改 | `ports/qemu-11.1/LICENSE`、`COPYING`；根子模块许可 | 整体 GPLv2，逐文件有 GPLv2-only / or-later 等差异；TCG 部分宽松许可不能把完整 QEMU 变成宽松库。分发修改版本须保留通知、修改记录、合适整体许可，并按 GPLv2 §3 提供完整机器可读对应源码及控制编译/安装的脚本。 |
| 新 Phone exports / adapter | `qemu_hmos_phone_exports.c` 与 `runtime/**` 的 GPL-2.0-or-later 标识 | 适配器可公开共享；同进程链接到专有宿主的组合边界仍待审查，新增 C ABI 不授予例外。 |
| LibVNC client/server | `ports/libvnc/COPYING` 为 GPLv2 文本；旧 rfbclient.h 明确 v2-or-later | 不是 LGPL 库。不能把 LGPL 的“给对象文件以重链接”当成闭源使用 LibVNC 的充分条件。具体构建应核对所有文件许可、修改与依赖。 |
| 条件静态链接 | 根 CMake 的 archive 存在检查、whole-archive | archive 真正加入 DSO 时，视为组合发行的重大审查项；需要 link command/map、archive 哈希、ELF 符号与最终 HAP 清单。动态符号表不包含静态库名字并不能排除静态链接。 |
| `dlopen` / N-API / ArkTS | wrapper 与 napi 源码 | 动态链接、私有仓库、独立 `.so`、薄 N-API 或一个 HAP 中的模块划分都不是独立程序证明。不能断言只公开 C++ 就一定够，也不能未经审查一概公开全部 ArkTS。 |
| GLib 及其他 LGPL 文件 | `third_party/deps/glib/src/COPYING` 为 LGPLv2.1；QEMU `COPYING.LIB` | 修改库须按适用许可提供源码。若采用 LGPLv2.1 §6，需允许用户为修改调试而逆向；静态组合通常需可重新链接的对象/源码及材料，或满足其他许可选项；合适动态共享机制需实际允许替换兼容修改库。SDK 签名/打包限制须实测，不能只看后缀。 |
| 历史自研 Native / ArkTS | `README.MD`、`LICENSE-APACHE` 的 Apache-2.0 范围声明 | Apache-2.0 与 GPLv2-only 不兼容；QEMU 存在 v2-only 文件，不能默认把整套组合升到 GPLv3。需要逐文件组合审查；获得权利人有效的兼容授权、调整依赖或独立程序方案，不能自动重许可历史代码。 |
| OpenSSL | vendored `LICENSE.txt` 为 Apache-2.0 | 同上，核对实际进入 QEMU / viewer 的 OpenSSL 版本、上游文件例外与组合许可；本次不认定存在足够例外或修改其许可。 |
| Pixman / PCRE2 / cJSON | vendored COPYING（MIT 主体）、LICENCE.md（BSD-3-Clause WITH PCRE2-exception）、cJSON.h（MIT） | 保留各自通知与适用例外；逐文件不同声明仍需清单，不被根 Apache 声明覆盖。 |
| libffi / libslirp / gettext / zlib 等实际依赖 | 构建记录与 release source collection | 只有构建选择的版本和文件清单能确定具体义务；逐个收集 LICENSE、静态/动态输入、来源身份。未对新 Phone 包完成此项，不能照搬旧 fullcore 的通过结果。 |
| UEFI / EDK2 / 固件 | 单独固件构建与 notices | 固件是独立组件，不能仅以 QEMU GPL 概括。应绑定每个固件哈希和对应来源/声明。 |
| 产品资源与商店条款 | 权利人/发行渠道材料未提供 | 品牌/插画与程序许可分别处理；商店 EULA、DRM、签名与禁止逆向条款不得冲突于适用自由软件义务。未核对私有目标，不自动公开其资源。 |

GPLv2 源码供应可选择 §3(a) 随附完整源码等有效方式；若选择 §3(b) 的书面要约，
需至少三年有效且适用于任何第三方，不能把七天 Actions Artifact 当作该要约的履行。
商业发行通常不能依赖仅适用于特定非商业再分发情形的 §3(c)。公开 Git 仓库若缺少实际
发行包对应的修改、依赖和脚本，也不能代替完整对应源码。
GPL 的义务不是仅“把自己修改过的几个文件上传”，也不当然要求把与程序无关的品牌
素材或独立服务代码按 GPL 授权。

### 保留合理私有边界的两种方向

- **当前工程复用方向**：统一公开运行时和派生改进，以固定版本供两个项目开发使用。
  对外分发同进程专有 Aether 前，必须解决具体组合许可和历史 Apache/GPLv2-only
  兼容问题；本实现没有解决这些法律前提。内部私用/开发与向用户分发是不同场景。
- **需要论证的独立程序方向**：将可独立运行、具通用控制协议的开源引擎作为独立程序，
  私有产品通过标准 QMP/RFB 交互；若私有 viewer 仍链接 GPL LibVNC，则问题仍存在。
  私有端可评估具有适当宽松授权且来源清楚的独立客户端实现。
  进程边界与 IPC 不是豁免，需要审查通信语义、数据结构和相互依赖。
  HarmonyOS 设备是否允许所需独立进程/服务与生命周期，必须用正式平台能力验证；
  本次没有实现 fork/exec、服务 HAP 或跨应用 IPC，也不把云端方案当成已验证替代。

如果同进程闭源组合既无适用例外又不能满足 GPL，不能通过隐藏符号解决；需更改该
组合的许可/发行安排，或经过审查采用实际独立的程序结构。开源贡献应回到 Aetherium，
私有消费者代码是否可保留则由真实组合边界决定，不能由仓库名称决定。

## 验证状态与交付前证据

**已验证**：独立适配器用 g++ C++17、`-Wall -Wextra -Werror` 编译并链接；五组
mock DSO 场景（参数、缺符号、错误 marker、一次性调用、并发）和 C 编译器头文件
调用均通过。mock 在运行中改写 argv 并返回 17，验证参数拷贝和退出码分离。

**已编写，未验证**：CMake 工作流（当前环境未安装 CMake，实际主机测试通过直接
编译器完成）、可选 HarmonyOS N-API、ArkTS 声明及 API 20 设备打包。

**尚未完成**：目标私有仓库身份确认、私有代码比较/迁移、真实 Phone DSO 装载、
设备启动/退出、LibVNC 重建及哈希漂移修复、fullcore backend 收敛、完整对应源码
审查、商店/签名条款审查。同进程多次启动明确不支持。

新二进制发行至少需要：固定源码提交与所有构建输入、核心/adapter/依赖/固件/HAP
哈希、链接 map 与配置、可复现来源包及可访问的源码供应方式、逐文件许可与组合
审查结论、设备日志和消费者状态展示记录。本次没有触发 HAP/Release 发布。

参考依据（2026-10-19 检查）：
- [QEMU 官方许可说明](https://www.qemu.org/docs/master/about/license.html)
- [GPLv2 原文 §2–3](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
- [LGPLv2.1 原文 §2、§6](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)
- [GNU FAQ：静态/动态链接与插件](https://www.gnu.org/licenses/gpl-faq.html#GPLStaticVsDynamic)
- [GNU FAQ：独立程序与聚合](https://www.gnu.org/licenses/gpl-faq.html#MereAggregation)
- [Apache 官方 GPL 兼容说明](https://apache.org/licenses/GPL-compatibility.html)
- 上表所列仓库内保留的 COPYING、LICENSE 与逐文件声明；在线资料不取代实际版本文本。
