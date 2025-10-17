#!/bin/bash

# ARM VM optimized build script for QEMU on HarmonyOS
# This script is designed to run in ARM64 Ubuntu VM
# Assumes HarmonyOS SDK is already installed and configured

set -e

echo "=== ARM VM Build for QEMU on HarmonyOS ==="

# Check if we're on ARM64
if [[ $(uname -m) != "aarch64" ]]; then
  echo "❌ This script is designed for ARM64 architecture"
  echo "Current architecture: $(uname -m)"
  exit 1
fi

# Install dependencies
echo "=== Installing dependencies ==="
sudo apt-get update --quiet
sudo apt-get install -y --quiet \
  build-essential cmake curl wget unzip python3 python3-pip python3-venv \
  nasm iasl uuid-dev libssl-dev pkg-config meson tree \
  libglib2.0-dev libpixman-1-dev libcurl4-openssl-dev \
  libsasl2-dev libpam0g-dev libbz2-dev libzstd-dev libpcre2-dev

# Set up Python virtual environment
echo "=== Setting up Python environment ==="
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install meson ninja edk2-basetools

echo "✅ Dependencies installed"

# Assume HarmonyOS SDK paths (adjust if different)
export OHOS_NDK_HOME="/opt/ohos-sdk/native"
export SYSROOT="/opt/ohos-sdk/native/sysroot"
export CC="/opt/ohos-sdk/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
export CXX="/opt/ohos-sdk/native/llvm/bin/aarch64-unknown-linux-ohos-clang++"
export CMAKE="/opt/ohos-sdk/native/build-tools/cmake/bin/cmake"

# Verify tools exist
echo "=== Verifying HarmonyOS SDK ==="
if [ ! -f "$CC" ]; then
  echo "❌ HarmonyOS clang not found at: $CC"
  echo "Please install HarmonyOS SDK first"
  echo "Download from: https://repo.huaweicloud.com/harmonyos/os/6.0-Release/ohos-sdk-windows_linux-public.tar.gz"
  exit 1
fi

echo "✅ HarmonyOS SDK found"

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
echo "You can now build the HarmonyOS HAP package."
