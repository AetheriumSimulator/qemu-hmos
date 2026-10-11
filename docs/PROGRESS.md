# 项目进展记录（QEMU on HarmonyOS）

本文件跟踪近期完成的工作、诊断结论、打包与集成要点，以及后续待办。便于回溯问题与快速复现。

## 目标概述
- 在 HarmonyOS 上构建并运行 QEMU，提供稳定的原生 N-API 桥接。
- 创建/启动 VM 后自动进入 VNC 视图，通过 WebView 加载 noVNC（支持 websocket）。
- 修复 N-API/ABI 崩溃（SIGBUS 等），确保原生库与资源正确打包进 HAP。
- 增加“删除 VM”“真实诊断”等功能，便于用户定位问题和清理数据。

## 已完成的关键改动

- 原生/N-API 稳定性
  - 新增 `napi_compat.h`，设备端走系统 `native_api.h`，主机端可选简化 shim（受编译开关保护）。
  - 修复 N-API 常量与字符串读入安全问题：统一使用安全辅助函数（长度 + 1 NUL 缓冲）。
  - 修正导出数组长度，避免数组越界；N-API 导出包含 `checkCoreLib()` 等真实探测方法。
  - 引入 HILOG 打印（弱链接 `OH_LOG_Print`），并同时落地到日志文件，便于设备端排查。

- 核心库加载与诊断
  - N-API 模块仍为 `libqemu_hmos.so`；运行时通过 `dlopen()` 加载 `libqemu_full.so`。
  - 加载顺序：默认搜索路径 → N-API 模块同目录 → 应用 files 目录（`/data/storage/el2/base/haps/entry/files/`）。
  - `StartVm` 启动前强制 `EnsureQemuCoreLoaded`，核心库缺失则中止启动并返回失败，避免 UI 误判。
  - `checkCoreLib()` 返回真实探测结果（是否已加载、各路径探测结果、错误信息），供 UI 诊断显示。

- VNC/noVNC 与页面流转
  - QEMU 启动参数统一：`-display vnc=127.0.0.1:1,websocket=on`，默认 ARM64 (`qemu-system-aarch64`)；
    UEFI 固件路径统一为 `files/edk2-aarch64-code.fd`。
  - `VNCViewer.ets`：将 `rawfile/novnc/*.js` 复制到 `files/novnc/`，生成本地 `index.html` 并通过 WebView 加载。
    支持 UMD (`novnc.min.js`) 和 ESM (`novnc.esm.js`) 两种加载方式，优先 UMD。
  - 创建/启动 VM 后自动路由到 `VNCViewer` 页面；websocket 默认开启。

- UI/UX 与管理能力
  - 新增“删除 VM”：删除元数据与磁盘/日志等文件（尽力而为）。
  - 新增“诊断依赖”按钮：展示核心库、多路径探测结果以及 noVNC 资源的真实状态。
  - 精简/整理路由页面，避免 Kit/类型不一致导致 ArkTS 报错。

- 打包/构建（hvigor + CMake）
  - 确保原生输出落盘到 `entry/src/main/libs/arm64-v8a/`，便于 HAP 打包：
    - `CMakeLists.txt` 新增：
      - `copy_qemu_full` 自定义目标：将 `entry/src/main/libs/arm64-v8a/libqemu_full.so` 同步到构建产物与 `oh_modules/`，保证运行时可用。
      - `qemu_full_prebuilt` IMPORTED SHARED 目标并链接（配合 `-Wl,--no-as-needed`）强制生成 DT_NEEDED，
        防止打包器裁剪。
  - 若未提供 `OHOS_NDK_HOME`，CMake 会降级为主机侧构建：自动启用简化 NAPI shim、跳过 HarmonyOS 特有链接依赖，并避免强制链接 ARM 架构的 `libqemu_full.so`。
  - 新增 GitHub Actions 工作流 `Native Build (Host)`，在 Ubuntu runner 上执行 `cmake -S entry/src/main/cpp -B build/host && cmake --build build/host`，确保 PR 至少通过一次主机侧编译检查。
  - `module.json5`：`libIsolation=false`、`compressNativeLibs=false`，减少打包裁剪/压缩带来的问题。

## 最近修复（2025-09-07）

### NAPI模块加载问题调试（进行中）
- **问题描述**：ArkTS层调用`qemu.startVm`返回`true`，但没有C++调试日志，说明NAPI模块未被正确加载
- **已尝试的解决方案**：
  1. 修复模块名称匹配：将`nm_modname`从`qemu_hmos`改为`libqemu_hmos.so`以匹配ArkTS导入
  2. 添加多个构造函数注册：`NAPI_qemu_hmos_Register`、`RegisterQemuModule`、`RegisterLibQemuHmos`
  3. 使用HarmonyOS NAPI_MODULE宏：`NAPI_MODULE(libqemu_hmos, Init)`
  4. 确保Init函数使用`static`修饰符防止符号冲突
- **当前状态**：所有方案均未成功，C++调试日志（`QEMU:`开头）未出现
- **影响**：VM启动虽然返回成功，但实际未执行QEMU代码，导致VNC连接失败

### VNC连接失败问题
- **现象**：`qemu.startVm`返回`true`，但VNC连接`127.0.0.1:5901`失败
- **根本原因**：NAPI模块未加载，实际调用的是stub函数，QEMU进程未真正启动
- **临时表现**：ArkTS层显示"VM启动成功"，但VNC客户端无法连接

### 权限和资源问题修复
- **权限配置**：添加`ohos.permission.READ_MEDIA`、`ohos.permission.WRITE_MEDIA`、`ohos.permission.GET_NETWORK_INFO`
- **字符串资源**：修复`$string:permission_read_media_reason`等字符串资源定义在`base/element/string.json`
- **ArkTS编译错误**：修复类型安全问题和`any`类型使用

### 构建系统优化
- **CMake配置**：优化库文件复制到`libs/arm64-v8a`目录
- **Hvigor集成**：确保native库正确打包到HAP中
- **调试日志**：添加详细的HilogPrint调试信息

## 最近修复（2025-09-06）
- 修复诊断不识别 `libs/arm64-v8a` 中核心库的问题：
  - `checkCoreLib()` 现使用 `dladdr()` 获取 `libqemu_hmos.so` 的真实路径，并在"同目录"尝试 `dlopen("libqemu_full.so")`；
  - 诊断面板将显示 `Core.selfDir` 和 `Core.foundSelfDir` 的真实结果与错误原因，便于定位依赖缺失。

### 新增：原生 VNC（LibVNCClient）集成（实验性）
- N-API 新增原生 VNC 客户端接口（已接线 LibVNCClient，工作线程抓帧）：
  - `vncAvailable()`、`vncCreate()`、`vncConnect(id,host,port)`、`vncDisconnect(id)`、`vncGetFrame(id)`。
  - 线程循环 `WaitForMessage/HandleRFBServerMessage`，`MallocFrameBuffer/GotFrameBufferUpdate` 将服务端帧拷贝为 RGBA 缓冲，可由 ArkTS 轮询渲染。
- 产物与依赖：
  - 新增 `entry/src/main/cpp/third_party/libvncclient/libvncclient.a`（aarch64‑linux‑ohos，-fPIC 编译）。
  - 新增头文件目录 `entry/src/main/cpp/third_party/libvncclient/include/` 与最小 `rfb/rfbconfig.h`。
  - CMake 接入并移除未使用的 `-ljpeg/-lpng`，仅链接 `-lpthread -lz`；确保可在 OHOS sysroot 下链接。
- ArkTS 封装与页面：
  - `managers/VNCNativeClient.ets` 调用上述 N-API；
  - 新页 `pages/VNCNativeViewer.ets`（“安装期 (VNC - 原生)”）使用 `-display vnc=:1` 直连 `127.0.0.1:5901`；后续补上画布渲染和输入映射。
- 说明文档：新增 `docs/VNC_NATIVE.md`（放置库与实现计划）。

### WebView/noVNC 加载链改造
- `pages/VNCViewer.ets`：
  - WebView 启用 `.fileAccess(true) / .domStorageAccess(true)`；
  - 首选 `internal://app`，其次 `file://`，失败回退到 `data:` 方案；
  - 动态加载 `novnc.esm.js`（`import()` 多路径尝试），优先 UMD `novnc.min.js`，缺失时显示明确错误文本；
  - 顶部增加原生状态文案（非 WebView），避免“白屏无字”。
- 新增工具脚本 `tools/build_novnc_umd.sh`（esbuild 打 UMD），但因上游包含 TLA，不作为默认方案；当前以 ESM 动态加载为主。

### 端口与路由修正
- WebSocket 端口统一为 `5701`（`display :1`），前端路由传参 `vncPort: 5701`；
- 添加 `pages/RDPViewer` 至 `main_pages.json`，避免导航失败；
- RDPViewer/RDPDisplay ArkTS 兼容修复：去除 `TextEncoder`、移除不支持的 `borderBottom/maxWidth`，`padding` 使用显式 `left/right/top/bottom`；消除 `any`/`this` 于独立函数的用法。

### 冷启动状态同步（防“假运行”）
- Index/VMs 页面在加载持久化列表后，逐个调用 `qemu.getVmStatus(name)` 同步真实状态；
- 非 running 的统一校正为 `stopped` 并持久化，避免 HAP 重装后仍显示“运行中”却无法进入查看页。

## 当前状态
- HAP 内包含：
  - `libs/arm64-v8a/libc++_shared.so`
  - `libs/arm64-v8a/libqemu_full.so`
  - `libs/arm64-v8a/libqemu_hmos.so`
  - `resources/rawfile/edk2-aarch64-code.fd`
  - `resources/rawfile/novnc/novnc.esm.js`（建议同时提供 `novnc.min.js` 以避免 ESM 白屏风险）
- UI“诊断依赖”应能正确显示 `Core.foundSelfDir=true`（若仍为 false，请查看 `Core.errSelfDir` 的具体依赖缺失信息）。

## 已知问题与建议思路

### 🔴 关键问题：NAPI模块加载失败
- **问题**：ArkTS `import qemu from 'libqemu_hmos.so'` 未加载到我们的C++实现
- **现象**：`qemu.startVm`返回`true`但无C++调试日志，VNC连接失败
- **可能原因**：
  1. HarmonyOS NAPI模块注册机制与标准Node.js不同
  2. 模块名称或路径不匹配
  3. 库文件未正确打包到运行时路径
  4. 需要特殊的模块声明或配置
- **建议思路**：
  1. **检查HarmonyOS官方文档**：查找正确的NAPI模块注册方式
  2. **尝试不同的模块名称**：如`qemu_hmos`、`libqemu_hmos`等
  3. **检查module.json5配置**：可能需要添加nativeLibs声明
  4. **使用HarmonyOS特定的导入方式**：如`@ohos.xxx`格式
  5. **检查库文件路径**：确认运行时能正确找到`libqemu_hmos.so`

### 🟡 次要问题：VNC连接失败
- **问题**：VNC客户端无法连接到`127.0.0.1:5901`
- **根本原因**：QEMU进程未真正启动（NAPI模块问题导致）
- **解决思路**：先解决NAPI模块加载问题

### 🟡 构建和打包问题
- **问题**：Hvigor可能未正确打包native库
- **现象**：库文件在HAP中但运行时找不到
- **解决思路**：
  1. 检查`module.json5`中的`nativeLibs`配置
  2. 确认CMake输出路径与Hvigor期望路径一致
  3. 验证库文件在设备上的实际路径

## 仍需跟进/待办
- **高优先级**：解决NAPI模块加载问题，确保C++代码被正确调用
- **中优先级**：完成VNC连接和QEMU进程启动验证
- **低优先级**：
  - noVNC：建议补充 `resources/rawfile/novnc/novnc.min.js`（UMD 版本）以简化加载与兼容性
  - 若 `dlopen` 报缺符号/库：将对应依赖 `.so` 一并打入 `libs/arm64-v8a/`，或将其静态进 `libqemu_full.so`
  - 完成真实 QEMU 核心集成验证（`qemu_main` 运行、循环与退出路径），并完善崩溃回收与重启策略
  - 安装完成后的 RDP 流程与页面联动（`hostfwd`、FreeRDP 页面等）
  - KVM 能力探测与参数选择完善（`/dev/kvm` 检查失败自动降级 TCG）
  - hvigor 打包在 Release/不同签名场景的复测（验证原生库未被裁剪）

## 下一步计划（优先级）

### 🔴 最高优先级：解决NAPI模块加载问题
- **HarmonyOS NAPI模块注册研究**：
  - 查阅HarmonyOS官方文档，了解正确的NAPI模块注册方式
  - 对比标准Node.js NAPI与HarmonyOS NAPI的差异
  - 尝试不同的模块注册方法和命名约定
- **模块路径和配置检查**：
  - 验证`module.json5`是否需要`nativeLibs`声明
  - 检查库文件在设备上的实际路径和权限
  - 尝试不同的ArkTS导入方式（如`@ohos.xxx`格式）
- **调试和诊断增强**：
  - 添加更详细的模块加载日志
  - 检查HarmonyOS NAPI模块注册表
  - 验证库文件符号导出和依赖关系

### 🟡 高优先级：VNC连接和QEMU启动验证
- **QEMU进程启动验证**：
  - 确保NAPI模块正确加载后，验证QEMU进程真正启动
  - 检查QEMU命令行参数和配置
  - 验证UEFI固件和磁盘镜像路径
- **VNC连接问题排查**：
  - 检查VNC端口配置和网络连接
  - 验证QEMU VNC显示后端是否正确启动
  - 测试VNC客户端连接逻辑

### 🟡 中优先级：原生VNC渲染与交互
- 原生 VNC 渲染与交互
  - ArkTS 侧以 30–60fps 轮询 `vncGetFrame()`，使用 Canvas/PixelMap 将 RGBA 帧绘制；
  - N-API 增加输入接口 `vncSendPointer(x,y,mask)`、`vncSendKey(code,down)`，ArkTS 事件映射；
  - 处理窗口尺寸变化、重连与释放（退出页/停止 VM 时安全回收）。
- `dlopen` 自救与诊断增强
  - 若 `dlopen(libqemu_full.so)` 失败：自动从 HAP 内 `libs/arm64-v8a/` 复制到 `files/` 再重试；
  - 诊断接口返回更详细 `dlerror()` 与依赖缺失列表；首页"诊断依赖"支持一键复制日志。
- WebView/noVNC 可观测性（中优先）
  - 将 WebView 的 console/error 注入到 HILOG；
  - VNC 页“连接探测”按钮：探测 `ws://127.0.0.1:5701` 与 `tcp://127.0.0.1:5901` 可达性，直观区分前后端问题。
- 端口与模式切换（中优先）
  - 原生 VNC（5901）与 noVNC（5701）二选一开关；安装期默认原生 VNC，noVNC 作为备选；
  - RDP 模式完善：整合 FreeRDP 原生能力（替换当前 Stub），参数（分辨率/色深/音频）生效。
- 构建与打包（中优先）
  - 提供 noVNC 打包产物（UMD/ESM）说明与脚本；默认优先 UMD 以规避 ESModule 兼容性；
  - 持续保障静态库 `libvncclient.a` 与核心库 `libqemu_full.so` 为 `-fPIC`；
  - 打包规则覆盖 Release 签名/压缩策略，防止原生库裁剪。

---

## 今日进展（NAPI加载修复）

日期：2025-09-07

问题复盘：ArkTS 侧使用 `import qemu from 'libqemu_hmos.so'`，但 C++ 侧既通过 `napi_module` 结构体注册了模块名 `libqemu_hmos.so`，又同时使用 `NAPI_MODULE(libqemu_hmos, Init)` 宏注册了另一个名字（`libqemu_hmos`）。在 HarmonyOS 上，重复/不一致的模块名可能导致加载流程与导出对象出现偏差，表现为：

- ArkTS 调用返回对象存在，但看不到对应的 C++ 侧 HILOG（怀疑命中错误的导出或未触发 Init）。
- `startVm` 行为与 C++ 预期不一致，VNC 也随之失败。

解决方案（已实施）：

- 去除重复注册与名称不一致：仅保留一个构造器注册点，模块名固定为 `libqemu_hmos.so`，确保与 ArkTS 导入字符串完全一致。
- 在构造器与 Init 中添加明确的 HILOG（`QEMU: NAPI module constructor running...` / `QEMU: NAPI Init function called!`），便于现场确认模块真正完成加载与导出。

落地变更：

- 文件：`entry/src/main/cpp/napi_init.cpp`
  - 删除多余的注册构造器与 `NAPI_MODULE(...)` 宏（避免名称分叉）。
  - 保留并统一 `g_qemu_module.nm_modname = "libqemu_hmos.so"`。
  - 新增/强化加载日志，方便用 `hilog` 直接观察。

验证方法：

1. 构建并安装 HAP（Debug）：`hvigor assembleDebug` → `hdc install -r ./entry/build/outputs/hap/*.hap`
2. 启动应用前持续采集日志：`hdc shell hilog > issue34-hilog.txt`，应看到：
   `hdc shell hilog -x | grep QEMU` 仅用于一次性快照，不默认使用 `-r`。
   - `QEMU: NAPI module constructor running, registering libqemu_hmos.so`
   - `QEMU: NAPI Init function called!`
3. 进入首页后，`qemu.version/enableJit/kvmSupported` 的日志应正常打印；执行 `startVm` 失败时也会写入更详细的 `dlopen/dlsym` 失败信息。

后续观察点：

- 若仍出现 `dlopen libqemu_full.so` 失败，优先检查 HAP 内 `libs/arm64-v8a/` 是否包含该文件，或关闭 `compressNativeLibs` 以防被打包成 `.z.so`（当前已为 false）。
- 如设备路径不同（厂商定制），`EnsureQemuCoreLoaded` 已支持自定位（`dladdr` 同目录）与显式 libs 路径的回退加载。
- KVM/TCG 自适应（中优先）
  - `kvmSupported()` 失败时显式切换到 `-accel tcg` 并提示；
  - 记录性能/稳定性指标，辅助选择参数（thread=multi 等）。

## 验证步骤（速查）
1. 构建 & 安装后，进入首页点击“诊断依赖”：
   - 查看 `Core.loaded/Core.foundLd/Core.foundSelfDir/Core.foundFiles` 与错误信息；
   - `noVNC.min.js/noVNC.esm.js` 至少有一项为 true。
2. 启动 VM（默认安装模式 VNC）：
   - 观察 HILOG：过滤 `QEMU_CORE` 日志，确认“Core library loaded”与参数回显；
   - WebView 打开 VNC 页，连上 `ws://127.0.0.1:5901`。
3. 停止/删除 VM：确认状态与文件清理。

## 主要文件/路径
- 原生：
  - `entry/src/main/cpp/napi_init.cpp`（加载/诊断/VM 启动）
  - `entry/src/main/cpp/napi_compat.h`、`napi_simple.h`（N-API 兼容/桩）
  - `entry/src/main/cpp/CMakeLists.txt`（复制/链接预编译核心库，输出到 `libs/arm64-v8a/`）
- ArkTS：
  - `entry/src/main/ets/pages/Index.ets`（创建/启动/停止/删除/诊断）
  - `entry/src/main/ets/pages/VMs.ets`（简化 VM 列表与启动流）
  - `entry/src/main/ets/pages/VNCViewer.ets`（noVNC 资源下发与 WebView 加载）
- 资源/打包：
  - `entry/src/main/module.json5`（权限与打包参数）
  - `entry/src/main/resources/rawfile/edk2-aarch64-code.fd`
  - `entry/src/main/resources/rawfile/novnc/novnc.esm.js`（建议补充 `novnc.min.js`）
  - `entry/src/main/libs/arm64-v8a/*.so`

## 总结

### 当前项目状态
- ✅ **基础架构完成**：QEMU编译、NAPI接口设计、ArkTS UI框架、VNC集成
- ✅ **构建系统稳定**：CMake配置、Hvigor集成、库文件打包
- ✅ **权限和资源修复**：HarmonyOS权限配置、字符串资源定义
- ❌ **关键阻塞问题**：NAPI模块加载失败，C++代码未被调用

### 技术债务
1. **NAPI模块加载机制**：需要深入研究HarmonyOS NAPI与标准Node.js NAPI的差异
2. **模块注册方式**：当前所有尝试的注册方法均未成功
3. **调试能力不足**：缺乏有效的模块加载状态检测和诊断工具

### 建议的下一步行动
1. **立即行动**：查阅HarmonyOS官方NAPI文档，了解正确的模块注册方式
2. **短期目标**：解决NAPI模块加载问题，确保C++代码被正确调用
3. **中期目标**：完成QEMU进程启动和VNC连接验证
4. **长期目标**：实现完整的虚拟机管理和VNC显示功能

---
如需定位问题，请优先：1) 点击"诊断依赖"收集面板信息；2) 查看 `hilog | grep QEMU_CORE`；3) 提供设备型号/系统版本与构建模式（Debug/Release）。
