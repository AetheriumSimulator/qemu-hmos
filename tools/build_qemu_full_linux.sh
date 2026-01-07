#!/bin/bash
#
# QEMU 完整构建脚本 - HarmonyOS OHOS 交叉编译
# 用于在 WSL/Linux 环境下构建 libqemu_full.so 共享库
#
set -e

log() {
    echo "[qemu-build] $*"
}

error() {
    echo "[qemu-build] ❌ $*" >&2
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
QEMU_SRC="${REPO_ROOT}/third_party/qemu"
DEPS_PREFIX="${REPO_ROOT}/third_party/deps/install-ohos"
OUTPUT_DIR="${REPO_ROOT}/entry/src/main/libs/arm64-v8a"

# 检查 NDK
if [[ -z "${OHOS_NDK_HOME}" ]]; then
    for candidate in \
        "/mnt/e/HMOS_SDK/linux/native" \
        "${HOME}/Library/OpenHarmony/Sdk/18/native" \
        "${REPO_ROOT}/ohos-sdk/linux/native"; do
        if [[ -d "${candidate}" ]]; then
            OHOS_NDK_HOME="${candidate}"
            break
        fi
    done
fi

if [[ -z "${OHOS_NDK_HOME}" || ! -d "${OHOS_NDK_HOME}" ]]; then
    error "请设置 OHOS_NDK_HOME 环境变量"
    exit 1
fi

log "=== QEMU HarmonyOS 构建脚本 ==="
log "NDK: ${OHOS_NDK_HOME}"
log "QEMU 源码: ${QEMU_SRC}"
log "依赖: ${DEPS_PREFIX}"
log "输出: ${OUTPUT_DIR}"

# 检查依赖是否已构建
if [[ ! -f "${DEPS_PREFIX}/lib/libglib-2.0.a" ]]; then
    error "依赖库未构建，请先运行: bash tools/build_ohos_deps.sh"
    exit 1
fi

# 设置交叉编译环境
CROSS_TRIPLE="aarch64-unknown-linux-ohos"
SYSROOT="${OHOS_NDK_HOME}/sysroot"
LLVM_BIN="${OHOS_NDK_HOME}/llvm/bin"

CC="${LLVM_BIN}/${CROSS_TRIPLE}-clang"
CXX="${LLVM_BIN}/${CROSS_TRIPLE}-clang++"
AR="${LLVM_BIN}/llvm-ar"
RANLIB="${LLVM_BIN}/llvm-ranlib"
STRIP="${LLVM_BIN}/llvm-strip"
NM="${LLVM_BIN}/llvm-nm"

# 验证编译器
if [[ ! -x "${CC}" ]]; then
    error "C 编译器不存在: ${CC}"
    exit 1
fi

log "编译器: ${CC}"

# 构建目录
BUILD_DIR="${QEMU_SRC}/build_harmonyos_full"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# ========== Apply local QEMU patches (idempotent) ==========
# We keep QEMU as an upstream submodule; HarmonyOS-specific fixes are applied as patches at build time.
# This avoids needing to push to upstream qemu/qemu while keeping the repo PR-friendly.
QEMU_PATCHES=(
  "${REPO_ROOT}/patches/qemu/0001-ohos-builtin-minimal-tpm2.patch"
  "${REPO_ROOT}/patches/qemu/0002-ohos-ohaudio-audiodev.patch"
)
for p in "${QEMU_PATCHES[@]}"; do
  if [[ -f "${p}" ]]; then
    log "Applying QEMU patch: ${p}"
    if git -C "${QEMU_SRC}" apply --reverse --check "${p}" >/dev/null 2>&1; then
      log "✅ Patch already applied, skip"
    else
      git -C "${QEMU_SRC}" apply --whitespace=nowarn "${p}"
      log "✅ Patch applied"
      log "Note: QEMU submodule working tree is now dirty. To clean: git -C third_party/qemu reset --hard"
    fi
  else
    log "⚠️  QEMU patch not found (skip): ${p}"
  fi
done

# 创建 Python 虚拟环境（如果不存在）
if [[ ! -d "pyvenv" ]]; then
    log "创建 Python 虚拟环境..."
    python3 -m venv pyvenv
    ./pyvenv/bin/pip install meson ninja
fi

# 设置 PKG_CONFIG_PATH
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${REPO_ROOT}/third_party/deps/lib/pkgconfig"

log ""
log "配置 QEMU (使用 configure)..."

# 运行 configure 生成 meson 交叉编译文件
../configure \
    --target-list=aarch64-softmmu \
    --cross-prefix="${CROSS_TRIPLE}-" \
    --cc="${CC}" \
    --cxx="${CXX}" \
    --objcc="${CC}" \
    --ar="${AR}" \
    --nm="${NM}" \
    --ranlib="${RANLIB}" \
    --strip="${STRIP}" \
    --host-cc="$(command -v gcc || command -v clang)" \
    --extra-cflags="--sysroot=${SYSROOT} -fPIC -I${DEPS_PREFIX}/include" \
    --extra-ldflags="--sysroot=${SYSROOT} -fuse-ld=lld -L${DEPS_PREFIX}/lib" \
    \
    --enable-vnc \
    --enable-slirp \
    --enable-tpm \
    --enable-tcg \
    --enable-fdt=internal \
    --enable-plugins \
    \
    --disable-kvm \
    --disable-xen \
    --disable-werror \
    --disable-docs \
    --disable-gio \
    --disable-sdl \
    --disable-gtk \
    --disable-vte \
    --disable-curses \
    --disable-brlapi \
    --disable-gnutls \
    --disable-nettle \
    --disable-gcrypt \
    --disable-libssh \
    --disable-curl \
    --disable-lzo \
    --disable-snappy \
    --disable-bzip2 \
    --disable-lzfse \
    --disable-zstd \
    --disable-spice \
    --disable-usb-redir \
    \
    -Db_staticpic=true \
    -Dvhost_user=disabled \
    -Dvhost_user_blk_server=disabled \
    -Dlibvhost_user=disabled \
    -Dvhost_vdpa=disabled \
    -Dlibvduse=disabled \
    -Dvduse_blk_export=disabled \
    -Dvhost_net=disabled \
    -Dvhost_kernel=disabled \
    -Dkeyring=disabled \
    -Dpasst=disabled \
    -Dguest_agent=disabled

# 修复 config-meson.cross 中的工具路径
log "修复交叉编译配置..."
sed -i "s|ar = \[.*\]|ar = ['${AR}']|" config-meson.cross
sed -i "s|nm = \[.*\]|nm = ['${NM}']|" config-meson.cross
sed -i "s|ranlib = \[.*\]|ranlib = ['${RANLIB}']|" config-meson.cross
sed -i "s|strip = \[.*\]|strip = ['${STRIP}']|" config-meson.cross

# 确保 b_staticpic 在正确的位置
if ! grep -q "b_staticpic = true" config-meson.cross; then
    sed -i '/\[built-in options\]/a b_staticpic = true' config-meson.cross
fi

log ""
log "运行 meson setup..."
rm -rf meson-* build.ninja 2>/dev/null || true

./pyvenv/bin/meson setup \
    --cross-file=config-meson.cross \
    --native-file=config-meson.native \
    -Dkvm=disabled \
    -Dxen=disabled \
    -Dvnc=enabled \
    -Dslirp=enabled \
    -Dtpm=enabled \
    -Ddocs=disabled \
    -Dplugins=true \
    -Dwerror=false \
    -Dvhost_user=disabled \
    -Dvhost_user_blk_server=disabled \
    -Dkeyring=disabled \
    -Dpasst=disabled \
    . ..

log ""
log "开始编译..."
NPROC=$(nproc 2>/dev/null || echo 4)
ninja -j${NPROC} qemu-system-aarch64

# 检查编译结果
if [[ ! -f "qemu-system-aarch64" ]]; then
    error "编译失败，未生成 qemu-system-aarch64"
    exit 1
fi

log ""
log "=== 链接为共享库 ==="

# 收集所有 .o 文件（排除 main 和 stubs）
find . -name '*.o' -type f \
    | grep -v 'system_main.c.o' \
    | grep -v '/test/' \
    | grep -v 'stubs_' \
    | grep -v 'libqemuutil.a.p/stubs' \
    > /tmp/qemu_objects.txt

log "找到 $(wc -l < /tmp/qemu_objects.txt) 个对象文件"

# 链接为共享库
${CC} -shared -fPIC \
    --sysroot=${SYSROOT} \
    -fuse-ld=lld \
    -o libqemu_full.so \
    @/tmp/qemu_objects.txt \
    -L${DEPS_PREFIX}/lib \
    -Lsubprojects/slirp \
    -Lsubprojects/dtc/libfdt \
    -lglib-2.0 \
    -lpixman-1 \
    -lpcre2-8 \
    -lintl \
    -lfdt \
    -lslirp \
    -lz -lm -lpthread -ldl \
    -Wl,--allow-shlib-undefined \
    -Wl,-soname,libqemu_full.so

if [[ ! -f "libqemu_full.so" ]]; then
    error "共享库链接失败"
    exit 1
fi

log ""
log "复制文件到输出目录..."
mkdir -p "${OUTPUT_DIR}"

# 复制共享库
cp libqemu_full.so "${OUTPUT_DIR}/"
log "✅ libqemu_full.so 已复制 ($(du -h libqemu_full.so | cut -f1))"

# 复制 slirp 共享库
if [[ -f "subprojects/slirp/libslirp.so.0.4.0" ]]; then
    cp subprojects/slirp/libslirp.so.0.4.0 "${OUTPUT_DIR}/libslirp.so"
    log "✅ libslirp.so 已复制"
fi

log ""
log "=== 验证导出符号 ==="
nm -D "${OUTPUT_DIR}/libqemu_full.so" 2>/dev/null | grep -E 'qemu_init|qemu_main_loop' | head -5

log ""
log "=== 构建完成 ==="
ls -lh "${OUTPUT_DIR}/"
log ""
log "文件信息:"
file "${OUTPUT_DIR}/libqemu_full.so"

