#!/usr/bin/env bash
set -euo pipefail

# Build OpenSSL static libraries for aarch64-linux-ohos
# Output: libssl.a and libcrypto.a

log() {
  printf '[openssl-build] %s\n' "$*"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

# Detect OHOS NDK
detect_ndk() {
  local candidates=(
    "${OHOS_NDK_HOME:-}"
    "${OHOS_NDK:-}"
    "${REPO_ROOT}/ohos-sdk/linux/native"
    "${HOME}/Library/OpenHarmony/Sdk/18/native"
    "${HOME}/Library/OpenHarmony/Sdk/15/native"
    "${HOME}/OpenHarmony/Sdk/18/native"
  )
  for d in "${candidates[@]}"; do
    if [[ -n "${d}" && -d "${d}/llvm/bin" && -d "${d}/sysroot" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

NDK_DIR="$(detect_ndk || true)"
if [[ -z "${NDK_DIR}" ]]; then
  log "error: OpenHarmony NDK not found. Set OHOS_NDK_HOME environment variable."
  exit 1
fi

log "Using OHOS NDK: ${NDK_DIR}"

CROSS_TRIPLE="aarch64-unknown-linux-ohos"
CLANG_BIN="${NDK_DIR}/llvm/bin/${CROSS_TRIPLE}-clang"
AR_BIN="${NDK_DIR}/llvm/bin/llvm-ar"
RANLIB_BIN="${NDK_DIR}/llvm/bin/llvm-ranlib"
SYSROOT="${NDK_DIR}/sysroot"

# Check tools
for tool in "${CLANG_BIN}" "${AR_BIN}"; do
  if [[ ! -x "${tool}" ]]; then
    log "error: tool not found: ${tool}"
    exit 1
  fi
done

# Source and build directories
SRC_DIR="${REPO_ROOT}/third_party/deps/openssl/src"
BUILD_DIR="${REPO_ROOT}/third_party/deps/openssl/build-ohos"
PREFIX_DIR="${REPO_ROOT}/third_party/deps/install-ohos"

mkdir -p "${BUILD_DIR}" "${PREFIX_DIR}"

# Check if OpenSSL source exists
if [[ ! -d "${SRC_DIR}" ]]; then
  log "error: OpenSSL source not found at ${SRC_DIR}"
  log "   Please ensure OpenSSL source is available"
  exit 1
fi

# Find OpenSSL source directory (could be openssl-* or directly in src/)
OPENSSL_DIR=""
if [[ -f "${SRC_DIR}/Configure" ]] || [[ -f "${SRC_DIR}/configure" ]]; then
  OPENSSL_DIR="${SRC_DIR}"
elif find "${SRC_DIR}" -maxdepth 1 -type d -name "openssl-*" | head -1 | read -r dir; then
  OPENSSL_DIR="${dir}"
fi

if [[ -z "${OPENSSL_DIR}" ]] || [[ ! -f "${OPENSSL_DIR}/Configure" ]]; then
  log "error: Could not find OpenSSL source (Configure script) in ${SRC_DIR}"
  log "   Please ensure OpenSSL source is available"
  exit 1
fi

log "Found OpenSSL source: ${OPENSSL_DIR}"
log "Configuring OpenSSL..."

cd "${OPENSSL_DIR}"

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Configure OpenSSL
env CC="${CLANG_BIN}" \
    AR="${AR_BIN}" \
    RANLIB="${RANLIB_BIN}" \
    perl Configure linux-aarch64 \
    no-shared \
    no-tests \
    no-docs \
    --prefix="${PREFIX_DIR}" \
    --openssldir="${PREFIX_DIR}/ssl" \
    --libdir=lib \
    CFLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT} -D__MUSL__ -fPIC" \
    LDFLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT}"

log "Building OpenSSL..."
make -j$(nproc)

log "Installing OpenSSL..."
make install_sw

log "✅ OpenSSL built successfully!"
log "Output:"
ls -lh "${PREFIX_DIR}/lib"/libssl.a "${PREFIX_DIR}/lib"/libcrypto.a 2>/dev/null || true

