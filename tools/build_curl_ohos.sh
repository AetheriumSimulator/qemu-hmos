#!/usr/bin/env bash
set -euo pipefail

# Keep the QEMU HTTP(S)/FTP block backend without using build-host libcurl.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREFIX="${REPO_ROOT}/third_party/deps/install-ohos"
BUILD_ROOT="${REPO_ROOT}/third_party/deps/.ohos-build"
TOOLCHAIN="${BUILD_ROOT}/toolchain/aarch64-unknown-linux-ohos-toolchain.cmake"
# curl 8.22.0: pin the release commit, not a moving branch or tag.
CURL_REVISION=01346829096c61b372692f6dc43ffa778c6caccd
SRC="${BUILD_ROOT}/curl-${CURL_REVISION}"
BUILD="${BUILD_ROOT}/curl-build"
test -f "${TOOLCHAIN}"
test -f "${PREFIX}/lib/libssl.a"
test -f "${PREFIX}/lib/libcrypto.a"
unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
unset CMAKE_PREFIX_PATH CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"

if [[ ! -d "${SRC}/.git" ]]; then
  git init "${SRC}"
  git -C "${SRC}" remote add origin https://github.com/curl/curl.git
fi
git -C "${SRC}" fetch --depth=1 origin "${CURL_REVISION}"
git -C "${SRC}" checkout --detach "${CURL_REVISION}"
test "$(git -C "${SRC}" rev-parse HEAD)" = "${CURL_REVISION}"

cmake -S "${SRC}" -B "${BUILD}" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
  -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
  -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF \
  -DCURL_USE_OPENSSL=ON -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DOPENSSL_ROOT_DIR="${PREFIX}" \
  -DOPENSSL_INCLUDE_DIR="${PREFIX}/include" \
  -DOPENSSL_SSL_LIBRARY="${PREFIX}/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="${PREFIX}/lib/libcrypto.a" \
  -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
  -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF -DUSE_NGHTTP2=OFF \
  -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON
cmake --build "${BUILD}" --parallel "$(nproc)"
cmake --install "${BUILD}"
test -s "${PREFIX}/lib/libcurl.a"
test -s "${PREFIX}/lib/pkgconfig/libcurl.pc"
"${BUILD_ROOT}/toolchain/aarch64-unknown-linux-ohos-pkg-config" --static --libs libcurl
