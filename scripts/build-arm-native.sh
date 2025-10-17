#!/bin/bash

# Native ARM64 build script for QEMU on HarmonyOS
# This script assumes HarmonyOS SDK is already installed in /opt/ohos-sdk
# Designed to run on ARM64 Ubuntu VM

set -e

echo "=== Native ARM64 Build for QEMU on HarmonyOS ==="

# Check if we're on ARM64
if [[ $(uname -m) != "aarch64" ]]; then
  echo "❌ This script requires ARM64 architecture"
  echo "Current architecture: $(uname -m)"
  exit 1
fi

# Check if HarmonyOS SDK exists
SDK_PATH="/opt/ohos-sdk"
if [ ! -d "$SDK_PATH" ]; then
  echo "❌ HarmonyOS SDK not found at $SDK_PATH"
  echo "🚨 ARM64系统必须使用ARM64版本的HarmonyOS SDK！"
  echo ""
  echo "🔧 正确的安装步骤："
  echo ""
  echo "方法1：从华为开发者网站下载"
  echo "1. 打开：https://developer.huawei.com/consumer/cn/download/"
  echo "2. 搜索 'HarmonyOS SDK'"
  echo "3. 选择 'Command line tools' （命令行工具）"
  echo "4. ⚠️  重要：下载 ARM64 版本，不是 x86_64！"
  echo "5. 下载完成后："
  echo "   sudo mkdir -p /opt/ohos-sdk"
  echo "   sudo tar -xzf 下载的文件.tar.gz -C /opt"
  echo "   sudo mv /opt/linux/* /opt/ohos-sdk/ 2>/dev/null || sudo mv /opt/linux /opt/ohos-sdk"
  echo ""
  echo "方法2：使用sdkmgr（如果已安装DevEco Studio）"
  echo "sdkmgr install 'Command line tools' --arch arm64"
  echo ""
  echo "方法3：尝试自动下载（可能不可用）"
  echo "wget https://repo.huaweicloud.com/harmonyos/os/6.0-Release/ohos-sdk-linux-arm64-public.tar.gz"
  echo ""
  exit 1
fi

echo "✅ Found HarmonyOS SDK at $SDK_PATH"

# Install dependencies
echo "=== Installing dependencies ==="
sudo apt-get update --quiet
sudo apt-get install -y --quiet \
  build-essential cmake curl wget unzip python3 python3-pip python3-venv \
  nasm iasl uuid-dev libssl-dev pkg-config meson tree \
  libglib2.0-dev libpixman-1-dev libcurl4-openssl-dev

# Set up Python virtual environment
echo "=== Setting up Python environment ==="
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install meson ninja edk2-basetools

echo "✅ Dependencies installed"

# Set SDK paths
export OHOS_NDK_HOME="$SDK_PATH"
export SYSROOT="$SDK_PATH/sysroot"

# Find compilers
echo "=== Finding compilers ==="
COMPILER_PATHS=(
  "$SDK_PATH/llvm/bin/aarch64-unknown-linux-ohos-clang"
  "$SDK_PATH/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
  "$SDK_PATH/bin/aarch64-unknown-linux-ohos-clang"
)

CC_PATH=""
CXX_PATH=""

for path in "${COMPILER_PATHS[@]}"; do
  if [ -f "$path" ]; then
    CC_PATH="$path"
    CXX_PATH="${path}++"
    break
  fi
done

if [ -z "$CC_PATH" ]; then
  echo "❌ Could not find HarmonyOS clang compiler"
  echo "Searching for any clang in SDK..."
  find "$SDK_PATH" -name "*clang*" -type f 2>/dev/null | head -5
  exit 1
fi

export CC="$CC_PATH"
export CXX="$CXX_PATH"

echo "✅ Found compilers:"
echo "CC: $CC"
echo "CXX: $CXX"

# Test compiler
echo "=== Testing compiler ==="
if ! "$CC" --version >/dev/null 2>&1; then
  echo "❌ Compiler test failed"
  file "$CC"
  exit 1
fi
echo "✅ Compiler works"

# Build QEMU
echo "=== Building QEMU ==="
cd third_party/qemu

mkdir -p build
cd build

../configure \
  --target-list=aarch64-softmmu \
  --cc="$CC" \
  --cxx="$CXX" \
  --host-cc="/usr/bin/cc" \
  --extra-cflags="-target aarch64-unknown-linux-ohos --sysroot=${SYSROOT}" \
  --extra-ldflags="-target aarch64-unknown-linux-ohos --sysroot=${SYSROOT}" \
  -Db_staticpic=true \
  -Db_pie=false \
  -Ddefault_library=static \
  -Dtools=disabled \
  --enable-tcg \
  --disable-kvm \
  --disable-xen \
  --disable-werror \
  --enable-vnc \
  --enable-slirp \
  --enable-curl \
  --enable-fdt \
  --enable-guest-agent \
  --enable-vhost-user \
  --enable-vhost-net \
  --enable-keyring \
  --disable-gtk \
  --disable-sdl \
  --disable-vte \
  --disable-curses \
  --disable-brlapi \
  --disable-spice \
  --disable-usb-redir \
  --disable-lzo \
  --disable-snappy \
  --disable-bzip2 \
  --disable-lzfse \
  --disable-zstd \
  --disable-libssh \
  --disable-nettle \
  --disable-gcrypt

ninja -j$(nproc)

echo "✅ QEMU build completed"

# Create shared library
echo "=== Creating libqemu_full.so ==="
$CXX -shared -fPIC -Wl,--no-undefined \
  -target aarch64-unknown-linux-ohos --sysroot=$SYSROOT \
  -Wl,--whole-archive \
  libqemu-aarch64-softmmu.a \
  libqemuutil.a \
  -Wl,--no-whole-archive \
  -lpthread -ldl -lm -lcurl -lssl -lcrypto \
  -o libqemu_full.so

if [ ! -f "libqemu_full.so" ]; then
  echo "❌ Shared library creation failed"
  exit 1
fi

echo "✅ libqemu_full.so created"

# Build NAPI wrapper
echo "=== Building HarmonyOS NAPI wrapper ==="
cd ../../../entry/src/main/cpp

mkdir -p build
cd build

$CXX -shared -fPIC -Wl,--no-undefined \
  -target aarch64-unknown-linux-ohos --sysroot=$SYSROOT \
  -I../ \
  -I../../../../third_party/qemu/build \
  ../qemu_napi.cpp \
  -L../../../../third_party/qemu/build \
  -lqemu_full \
  -o libqemu_hmos.so

if [ ! -f "libqemu_hmos.so" ]; then
  echo "❌ NAPI wrapper build failed"
  exit 1
fi

echo "✅ libqemu_hmos.so created"

# Build UEFI firmware
echo "=== Building UEFI Firmware ==="
cd ../../../../third_party/qemu-code/roms/edk2

# Set up environment variables
export WORKSPACE="$(pwd)"
export PACKAGES_PATH="$WORKSPACE"
export EDK_TOOLS_PATH="$WORKSPACE/BaseTools"
export CONF_PATH="$WORKSPACE/Conf"

# Create necessary directories
mkdir -p "$CONF_PATH"

# Configure build settings
echo "ACTIVE_PLATFORM       = ArmVirtPkg/ArmVirtQemu.dsc" > "$CONF_PATH/target.txt"
echo "TARGET_ARCH           = AARCH64" >> "$CONF_PATH/target.txt"
echo "TOOL_CHAIN_TAG        = GCC" >> "$CONF_PATH/target.txt"
echo "BUILD_TARGET          = RELEASE" >> "$CONF_PATH/target.txt"

# Build BaseTools
echo "=== Building BaseTools ==="
cd BaseTools
make -j$(nproc)
cd ..

# Build ARM64 UEFI firmware
echo "=== Building ARM64 UEFI firmware ==="
source edksetup.sh
build -a AARCH64 -t GCC -p ArmVirtPkg/ArmVirtQemu.dsc -b RELEASE

# Build x86_64 UEFI firmware (OVMF)
echo "=== Building x86_64 UEFI firmware (OVMF) ==="
build -a X64 -t GCC -p OvmfPkg/OvmfPkgX64.dsc -b RELEASE

# Check build results
echo "=== Checking UEFI build results ==="
if [ -f "Build/ArmVirtQemu-AARCH64/RELEASE_GCC/FV/QEMU_EFI.fd" ]; then
  echo "✅ ARM64 UEFI firmware built successfully"
  ls -lh "Build/ArmVirtQemu-AARCH64/RELEASE_GCC/FV/QEMU_EFI.fd"
else
  echo "❌ ARM64 UEFI firmware not found"
  exit 1
fi

if [ -f "Build/OvmfX64/RELEASE_GCC/FV/OVMF_CODE.fd" ]; then
  echo "✅ x86_64 UEFI firmware built successfully"
  ls -lh "Build/OvmfX64/RELEASE_GCC/FV/OVMF_CODE.fd"
else
  echo "❌ x86_64 UEFI firmware not found"
  exit 1
fi

# Copy UEFI firmware to project resources
echo "=== Copying UEFI firmware to project ==="
cd ../../../../entry/src/main/resources/rawfile
cp ../../../third_party/qemu-code/roms/edk2/Build/ArmVirtQemu-AARCH64/RELEASE_GCC/FV/QEMU_EFI.fd edk2-aarch64-code.fd
cp ../../../third_party/qemu-code/roms/edk2/Build/OvmfX64/RELEASE_GCC/FV/OVMF_CODE.fd OVMF_CODE.fd

echo "UEFI firmware copied to resources:"
ls -lh edk2-aarch64-code.fd OVMF_CODE.fd

echo ""
echo "=== Build Summary ==="
echo "✅ QEMU core library: third_party/qemu/build/libqemu_full.so"
echo "✅ HarmonyOS NAPI: entry/src/main/cpp/build/libqemu_hmos.so"
echo "✅ ARM64 UEFI: entry/src/main/resources/rawfile/edk2-aarch64-code.fd"
echo "✅ x86_64 UEFI: entry/src/main/resources/rawfile/OVMF_CODE.fd"
echo ""
echo "🎉 All components built successfully!"
echo ""
echo "Next steps:"
echo "1. Run: hvigor assembleDebug"
echo "2. Deploy to HarmonyOS device"
echo "3. Test virtual machine functionality"
