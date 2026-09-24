#!/usr/bin/env bash
set -euo pipefail

# Build LibVNC (server and client) static libraries for the selected OHOS ABI.
# Output: libvncserver.a and libvncclient.a

log() {
  printf '[libvnc-build] %s\n' "$*"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
LIBVNC_REPOSITORY="https://github.com/LibVNC/libvncserver.git"
# LibVNCServer has not published a point release containing its 2026 decoder
# fixes. Pin the reviewed upstream master commit instead of rebuilding 0.9.15
# or following a moving branch.
LIBVNC_REVISION="42494999e6492aaab9c1db785ecd293ef10b3aed"

if [[ -z "${LIBVNC_REVISION}" ]]; then
  log "error: LibVNC exact source revision is unresolved (release gate OSS-LIBVNC-REVISION)."
  log "Refusing to clone a moving branch or guess from the 0.9.15 version string."
  exit 78
fi

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

CROSS_TRIPLE="${OHOS_CROSS_TRIPLE:-aarch64-unknown-linux-ohos}"
case "${CROSS_TRIPLE}" in
  aarch64-*-linux-ohos|aarch64-linux-ohos)
    TARGET_CPU=aarch64
    BUILD_SUFFIX=""
    ;;
  x86_64-*-linux-ohos|x86_64-linux-ohos)
    TARGET_CPU=x86_64
    BUILD_SUFFIX=-x86_64
    ;;
  *) log "error: unsupported OHOS target triple: ${CROSS_TRIPLE}"; exit 1 ;;
esac
CLANG_BIN="${NDK_DIR}/llvm/bin/${CROSS_TRIPLE}-clang"
CXX_BIN="${NDK_DIR}/llvm/bin/${CROSS_TRIPLE}-clang++"
AR_BIN="${NDK_DIR}/llvm/bin/llvm-ar"
RANLIB_BIN="${NDK_DIR}/llvm/bin/llvm-ranlib"
SYSROOT="${NDK_DIR}/sysroot"
WINDOWS_NDK=0

if [[ ! -x "${CLANG_BIN}" && -f "${CLANG_BIN}.exe" ]]; then
  CLANG_BIN="${CLANG_BIN}.exe"
  CXX_BIN="${CXX_BIN}.exe"
  AR_BIN="${AR_BIN}.exe"
  RANLIB_BIN="${RANLIB_BIN}.exe"
  WINDOWS_NDK=1
fi

# Check tools
for tool in "${CLANG_BIN}" "${AR_BIN}"; do
  if [[ ! -x "${tool}" ]]; then
    log "error: tool not found: ${tool}"
    exit 1
  fi
done

# Source and build directories
SRC_DIR="${REPO_ROOT}/third_party/libvnc"
BUILD_DIR="${SRC_DIR}/build-ohos${BUILD_SUFFIX}-${LIBVNC_REVISION}"
if [[ -n "${OHOS_DEPS_PREFIX:-}" || "${TARGET_CPU}" != "aarch64" ]]; then
  VNC_PREFIX="${OHOS_DEPS_PREFIX:-${REPO_ROOT}/third_party/deps/install-ohos${BUILD_SUFFIX}}"
  if [[ "${TARGET_CPU}" != "aarch64" &&
        "$(realpath -m "${VNC_PREFIX}")" == "${REPO_ROOT}/third_party/deps/install-ohos" ]]; then
    log "error: ${TARGET_CPU} LibVNC must not overwrite the ARM64 dependency prefix"
    exit 1
  fi
  SERVER_DEST="${VNC_PREFIX}/lib"
  CLIENT_DEST="${VNC_PREFIX}/lib"
  HEADER_DEST="${VNC_PREFIX}/include/rfb"
else
  SERVER_DEST="${REPO_ROOT}/entry/src/main/cpp/third_party/libvncserver"
  CLIENT_DEST="${REPO_ROOT}/entry/src/main/cpp/third_party/libvncclient"
  HEADER_DEST="${CLIENT_DEST}/include/rfb"
fi

mkdir -p "$(dirname "${SRC_DIR}")" "${SERVER_DEST}" "${CLIENT_DEST}"

if [[ -e "${SRC_DIR}" && ! -d "${SRC_DIR}/.git" ]]; then
  log "error: ${SRC_DIR} is an unversioned source snapshot"
  exit 1
fi
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  log "Fetching LibVNC revision ${LIBVNC_REVISION}..."
  git clone --filter=blob:none --no-checkout "${LIBVNC_REPOSITORY}" "${SRC_DIR}"
  git -C "${SRC_DIR}" fetch --depth=1 origin "${LIBVNC_REVISION}"
  git -C "${SRC_DIR}" checkout --detach "${LIBVNC_REVISION}"
fi
ACTUAL_REVISION=$(git -C "${SRC_DIR}" rev-parse HEAD)
if [[ "${ACTUAL_REVISION}" != "${LIBVNC_REVISION}" ]]; then
  log "error: expected LibVNC ${LIBVNC_REVISION}, found ${ACTUAL_REVISION}"
  exit 1
fi

mkdir -p "${BUILD_DIR}"

log "Configuring LibVNC..."
cd "${SRC_DIR}"

# Check build system
if [[ -f "CMakeLists.txt" ]]; then
  # Use CMake
  mkdir -p "${BUILD_DIR}"

  CMAKE_CONFIGURE_ARGS=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR="${TARGET_CPU}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DBUILD_SHARED_LIBS=OFF
    -DWITH_GNUTLS=OFF
    -DWITH_OPENSSL=OFF
    -DWITH_SASL=OFF
    -DWITH_FFMPEG=OFF
    -DWITH_SDL=OFF
    -DWITH_TIGHTVNC_FILETRANSFER=OFF
    -DWITH_WEBSOCKETS=OFF
    -DWITH_JPEG=OFF
    -DWITH_PNG=OFF
    -DWITH_LZO=OFF
    -DWITH_GCRYPT=OFF
    -DBUILD_EXAMPLES=OFF
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  )

  if [[ "${WINDOWS_NDK}" == "1" ]]; then
    if ! command -v wslpath >/dev/null 2>&1; then
      log "error: Windows HarmonyOS SDK requires WSL wslpath"
      exit 1
    fi
    CMAKE_BIN="${NDK_DIR}/build-tools/cmake/bin/cmake.exe"
    NINJA_BIN="${NDK_DIR}/build-tools/cmake/bin/ninja.exe"
    if [[ ! -f "${CMAKE_BIN}" || ! -f "${NINJA_BIN}" ]]; then
      log "error: HarmonyOS SDK CMake/Ninja not found under ${NDK_DIR}/build-tools"
      exit 1
    fi
    SRC_CMAKE=$(wslpath -m "${SRC_DIR}")
    BUILD_CMAKE=$(wslpath -m "${BUILD_DIR}")
    CLANG_CMAKE=$(wslpath -m "${CLANG_BIN}")
    CXX_CMAKE=$(wslpath -m "${CXX_BIN}")
    AR_CMAKE=$(wslpath -m "${AR_BIN}")
    RANLIB_CMAKE=$(wslpath -m "${RANLIB_BIN}")
    SYSROOT_CMAKE=$(wslpath -m "${SYSROOT}")
    NINJA_CMAKE=$(wslpath -m "${NINJA_BIN}")
    "${CMAKE_BIN}" -G Ninja -DCMAKE_MAKE_PROGRAM="${NINJA_CMAKE}" \
      -S "${SRC_CMAKE}" -B "${BUILD_CMAKE}" \
      -DCMAKE_C_COMPILER="${CLANG_CMAKE}" \
      -DCMAKE_CXX_COMPILER="${CXX_CMAKE}" \
      -DCMAKE_AR="${AR_CMAKE}" \
      -DCMAKE_RANLIB="${RANLIB_CMAKE}" \
      -DCMAKE_C_COMPILER_AR="${AR_CMAKE}" \
      -DCMAKE_C_COMPILER_RANLIB="${RANLIB_CMAKE}" \
      -DCMAKE_SYSROOT="${SYSROOT_CMAKE}" \
      -DCMAKE_FIND_ROOT_PATH="${SYSROOT_CMAKE}" \
      -DZLIB_INCLUDE_DIR="${SYSROOT_CMAKE}/usr/include" \
      -DZLIB_LIBRARY="${SYSROOT_CMAKE}/usr/lib/${TARGET_CPU}-linux-ohos/libz.so" \
      -DCMAKE_C_FLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT_CMAKE} -fPIC -D__MUSL__ -DNO_CRYPTO" \
      -DCMAKE_CXX_FLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT_CMAKE} -fPIC -D__MUSL__ -DNO_CRYPTO" \
      "${CMAKE_CONFIGURE_ARGS[@]}"
  else
    CMAKE_BIN="cmake"
    if ! command -v cmake >/dev/null 2>&1; then
      CMAKE_BIN="${NDK_DIR}/build-tools/cmake/bin/cmake"
    fi
    "${CMAKE_BIN}" -S . -B "${BUILD_DIR}" \
      -DCMAKE_C_COMPILER="${CLANG_BIN}" \
      -DCMAKE_CXX_COMPILER="${CXX_BIN}" \
      -DCMAKE_AR="${AR_BIN}" \
      -DCMAKE_RANLIB="${RANLIB_BIN}" \
      -DCMAKE_SYSROOT="${SYSROOT}" \
      -DCMAKE_FIND_ROOT_PATH="${SYSROOT}" \
      -DZLIB_INCLUDE_DIR="${SYSROOT}/usr/include" \
      -DZLIB_LIBRARY="${SYSROOT}/usr/lib/${TARGET_CPU}-linux-ohos/libz.so" \
      -DCMAKE_C_FLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT} -fPIC -D__MUSL__ -DNO_CRYPTO" \
      -DCMAKE_CXX_FLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT} -fPIC -D__MUSL__ -DNO_CRYPTO" \
      "${CMAKE_CONFIGURE_ARGS[@]}"
  fi

  log "Building LibVNC with CMake (libraries only)..."
  # Build only libraries, skip examples and tools
  BUILD_CMAKE_PATH="${BUILD_DIR}"
  if [[ "${WINDOWS_NDK}" == "1" ]]; then
    BUILD_CMAKE_PATH=$(wslpath -m "${BUILD_DIR}")
  fi
  "${CMAKE_BIN}" --build "${BUILD_CMAKE_PATH}" --target vncserver vncclient --parallel || {
    log "⚠️  Full build failed, trying to build libraries individually..."
    # Try to build just the static libraries
    "${CMAKE_BIN}" --build "${BUILD_CMAKE_PATH}" --target vncserver --parallel || true
    "${CMAKE_BIN}" --build "${BUILD_CMAKE_PATH}" --target vncclient --parallel || true
  }
elif [[ -f "configure" ]] || [[ -f "autogen.sh" ]]; then
  # Use autotools
  log "Using autotools build system..."

  # Run autogen if needed
  if [[ -f "autogen.sh" ]]; then
    log "Running autogen.sh..."
    ./autogen.sh
  fi

  # Configure
  export CC="${CLANG_BIN}"
  export CXX="${CXX_BIN}"
  export AR="${AR_BIN}"
  export RANLIB="${RANLIB_BIN}"
  export CFLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT} -fPIC -D__MUSL__"
  export CXXFLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT} -fPIC -D__MUSL__"
  export LDFLAGS="--target=${CROSS_TRIPLE} --sysroot=${SYSROOT}"

  log "Running configure..."
  ./configure \
    --host="${TARGET_CPU}-linux-ohos" \
    --prefix="${BUILD_DIR}/install" \
    --enable-static \
    --disable-shared \
    --without-gnutls \
    --without-openssl \
    --without-sasl \
    --without-ffmpeg \
    --without-sdl \
    --disable-tightvnc-filetransfer \
    --disable-websockets

  log "Building LibVNC with make..."
  make -j$(nproc)
  make install

  BUILD_DIR="${BUILD_DIR}/install"
else
  log "error: Unknown build system in ${SRC_DIR}"
  exit 1
fi

# Find and copy libraries
log "Copying libraries..."

# Find libvncserver.a
SERVER_LIB=$(find "${BUILD_DIR}" -name "libvncserver.a" -type f | head -1)
if [[ -n "${SERVER_LIB}" ]]; then
  cp -f "${SERVER_LIB}" "${SERVER_DEST}/libvncserver.a"
  log "✅ Copied libvncserver.a to ${SERVER_DEST}"
else
  log "error: libvncserver.a not found"
  exit 1
fi

# Find libvncclient.a
CLIENT_LIB=$(find "${BUILD_DIR}" -name "libvncclient.a" -type f | head -1)
if [[ -n "${CLIENT_LIB}" ]]; then
  cp -f "${CLIENT_LIB}" "${CLIENT_DEST}/libvncclient.a"
  log "✅ Copied libvncclient.a to ${CLIENT_DEST}"
else
  log "error: libvncclient.a not found"
  exit 1
fi

# Copy headers
if [[ -d "${SRC_DIR}/include/rfb" ]]; then
  mkdir -p "${HEADER_DEST}"
  cp -f "${SRC_DIR}"/include/rfb/*.h "${HEADER_DEST}/"
  if [[ -f "${BUILD_DIR}/include/rfb/rfbconfig.h" ]]; then
    cp -f "${BUILD_DIR}/include/rfb/rfbconfig.h" "${HEADER_DEST}/rfbconfig.h"
  fi
  log "✅ Copied headers"
fi

log "Done!"
