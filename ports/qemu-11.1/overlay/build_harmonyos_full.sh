#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build one QEMU 11.1 AArch64 HarmonyOS shared core.
#
# QEMU_CORE_FLAVOR=tcg (default) builds the native AArch64 TCG backend.
# QEMU_CORE_FLAVOR=tci builds the interpreter backend in a separate build tree.

set -euo pipefail

checkout_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
core_flavor=${QEMU_CORE_FLAVOR:-tcg}
if [[ ${core_flavor} != "tcg" && ${core_flavor} != "tci" ]]; then
    printf 'Unsupported QEMU_CORE_FLAVOR: %s (expected tcg or tci)\n' \
        "${core_flavor}" >&2
    exit 2
fi
work_root=${QEMU_OHOS_BUILD_DIR:-"${TMPDIR:-/tmp}/qemu-hmos-11.1-ohos"}
source_commit=$(git -c safe.directory="${checkout_dir}" \
    -C "${checkout_dir}" rev-parse HEAD)
source_dir="${work_root}/source-${source_commit}"
source_ready="${source_dir}/.qemu-ohos-source-ready"
if [[ ${core_flavor} == "tci" ]]; then
    build_dir="${work_root}/build-${source_commit}-tci"
    stage_dir=${QEMU_OHOS_STAGE_DIR:-"${work_root}/stage-${source_commit}-tci"}
else
    build_dir="${work_root}/build-${source_commit}"
    stage_dir=${QEMU_OHOS_STAGE_DIR:-"${work_root}/stage-${source_commit}"}
fi
deps_prefix=${OHOS_DEPS_PREFIX:-"${checkout_dir}/../deps/install-ohos"}
cross_bin=${OHOS_CROSS_BIN:-"${checkout_dir}/../deps/bin"}

if [[ -z "${OHOS_SDK_DIR:-}" ]]; then
    printf '%s\n' \
        "OHOS_SDK_DIR must point to a HarmonyOS SDK containing native/." >&2
    exit 2
fi

ndk_dir="${OHOS_SDK_DIR}/native"
clang="${ndk_dir}/llvm/bin/aarch64-unknown-linux-ohos-clang"
clangxx="${ndk_dir}/llvm/bin/aarch64-unknown-linux-ohos-clang++"
llvm_ar="${ndk_dir}/llvm/bin/llvm-ar"
llvm_nm="${ndk_dir}/llvm/bin/llvm-nm"
llvm_ranlib="${ndk_dir}/llvm/bin/llvm-ranlib"
llvm_strip="${ndk_dir}/llvm/bin/llvm-strip"

for required in \
    "${clang}" \
    "${clangxx}" \
    "${llvm_ar}" \
    "${llvm_nm}" \
    "${llvm_ranlib}" \
    "${llvm_strip}" \
    "${cross_bin}/aarch64-unknown-linux-ohos-pkg-config" \
    "${deps_prefix}/lib/libglib-2.0.a" \
    "${deps_prefix}/lib/libpixman-1.a" \
    "${deps_prefix}/lib/libusb-1.0.a" \
    "${deps_prefix}/lib/pkgconfig/libusb-1.0.pc" \
    "${deps_prefix}/lib/libintl.a"; do
    if [[ ! -e "${required}" ]]; then
        printf 'Required HarmonyOS build input is missing: %s\n' \
            "${required}" >&2
        exit 2
    fi
done
if [[ ${core_flavor} == "tci" ]]; then
    for required in \
        "${deps_prefix}/lib/libffi.a" \
        "${deps_prefix}/lib/pkgconfig/libffi.pc"; do
        if [[ ! -e "${required}" ]]; then
            printf 'TCI requires the HarmonyOS libffi input: %s\n' \
                "${required}" >&2
            exit 2
        fi
    done
fi

libusb_version=$(awk '$1 == "Version:" { print $2 }' \
    "${deps_prefix}/lib/pkgconfig/libusb-1.0.pc")
if [[ ${libusb_version} != "1.0.30" ]]; then
    printf '%s: %s\n' \
        'HarmonyOS USB passthrough requires pinned libusb 1.0.30' \
        "${libusb_version:-missing}" >&2
    exit 2
fi
if ! strings "${deps_prefix}/lib/libusb-1.0.a" | \
    grep -F 'HarmonyOS descriptor-only context' >/dev/null; then
    printf '%s\n' \
        'The pinned libusb archive is missing the HarmonyOS' \
        'descriptor-only patch.' >&2
    exit 2
fi

source_version=$(git -c safe.directory="${checkout_dir}" \
    -C "${checkout_dir}" show "${source_commit}:VERSION")
if [[ ${source_version} != "11.1.0" ]]; then
    printf '%s\n' "This port is pinned to QEMU 11.1.0." >&2
    exit 2
fi

export PKG_CONFIG_LIBDIR="${deps_prefix}/lib/pkgconfig:"
export PKG_CONFIG_LIBDIR+="${deps_prefix}/share/pkgconfig"
export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"
export AR="${llvm_ar}"
export NM="${llvm_nm}"
export RANLIB="${llvm_ranlib}"
export STRIP="${llvm_strip}"
qemu_ohos_flags='-D__OHOS__=1 -D__HARMONYOS__=1 -fPIC -fvisibility=hidden'

mkdir -p "${work_root}" "${stage_dir}"

# Meson initializes pinned QEMU fallback subprojects with Git. HarmonyOS
# development commonly happens on NTFS/DrvFs, whose executable-bit semantics
# can make that initialization fail. Build the exact checked-out commit from a
# metadata-free archive on a native Linux filesystem. This also prevents old
# build trees and unrelated untracked files from entering the build input.
if [[ -e "${source_dir}" && ! -f "${source_ready}" ]]; then
    printf '%s: %s\n' \
        'Incomplete archived source; choose a new build root or remove it' \
        "${source_dir}" >&2
    exit 2
fi
if [[ ! -f "${source_ready}" ]]; then
    source_temp=$(mktemp -d "${work_root}/.source-${source_commit}.XXXXXX")
    trap 'rm -rf -- "${source_temp}"' EXIT
    git -c safe.directory="${checkout_dir}" \
        -C "${checkout_dir}" archive --format=tar "${source_commit}" | (
        cd "${source_temp}"
        tar -xf -
    )
    if [[ $(<"${source_temp}/VERSION") != "${source_version}" ]]; then
        printf '%s\n' \
            'Archived QEMU VERSION does not match the locked commit.' >&2
        exit 2
    fi
    printf '%s\n' "${source_commit}" > "${source_temp}/.qemu-ohos-source-ready"
    mv "${source_temp}" "${source_dir}"
    trap - EXIT
elif [[ $(<"${source_ready}") != "${source_commit}" ]]; then
    printf 'Archived source marker mismatch: %s\n' "${source_dir}" >&2
    exit 2
fi

mkdir -p "${build_dir}"

tcg_interpreter_args=()
if [[ ${core_flavor} == "tci" ]]; then
    tcg_interpreter_args+=(--enable-tcg-interpreter)
fi

if [[ ! -f "${build_dir}/build.ninja" ]]; then
    (
        cd "${build_dir}"
        "${source_dir}/configure" \
            --target-list=aarch64-softmmu \
            --cross-prefix="${cross_bin}/aarch64-unknown-linux-ohos-" \
            --cc="${clang}" \
            --cxx="${clangxx}" \
            --host-cc=cc \
            --extra-cflags="${qemu_ohos_flags}" \
            --extra-cxxflags="${qemu_ohos_flags}" \
            --extra-ldflags='-fuse-ld=lld' \
            --without-default-features \
            --enable-system \
            --enable-tcg \
            "${tcg_interpreter_args[@]}" \
            --enable-pixman \
            --enable-vnc \
            --enable-slirp \
            --enable-fdt=internal \
            --enable-tpm \
            --enable-libusb \
            --enable-ohos-ohaudio \
            --audio-drv-list=ohos-ohaudio \
            --with-coroutine=sigaltstack \
            --disable-rust \
            --disable-modules \
            --disable-plugins \
            --disable-tools \
            --disable-docs \
            --disable-guest-agent \
            --disable-opengl \
            --disable-virglrenderer \
            --disable-pie \
            --disable-werror \
            -Ddefault_library=static \
            -Db_staticpic=true \
            -Db_pie=false \
            -Dstrip=false \
            -Dharmonyos_shared_core=true \
            --with-devices-aarch64=harmonyos \
            --without-default-devices
    )
fi

if [[ ${core_flavor} == "tci" ]]; then
    if ! grep -Eq '^#define CONFIG_TCG_INTERPRETER([[:space:]]+1)?$' \
        "${build_dir}/config-host.h"; then
        printf '%s\n' 'TCI build did not enable CONFIG_TCG_INTERPRETER.' >&2
        exit 2
    fi
else
    if grep -Eq '^#define CONFIG_TCG_INTERPRETER([[:space:]]+1)?$' \
        "${build_dir}/config-host.h"; then
        printf '%s\n' 'Native TCG build unexpectedly enabled the interpreter.' >&2
        exit 2
    fi
fi

if ! grep -qx 'CONFIG_TPM_EMULATOR=y' \
    "${build_dir}/aarch64-softmmu-config-devices.mak"; then
    printf '%s\n' \
        'HarmonyOS QEMU core is missing the SWTPM emulator backend.' >&2
    exit 2
fi

jobs=${QEMU_BUILD_JOBS:-8}
ninja -C "${build_dir}" -j "${jobs}" libqemu_full.so

meson_bin="${build_dir}/pyvenv/bin/meson"
if [[ ! -x "${meson_bin}" ]]; then
    printf 'Meson executable is missing from the QEMU build: %s\n' \
        "${meson_bin}" >&2
    exit 2
fi

DESTDIR="${stage_dir}" "${meson_bin}" install \
    -C "${build_dir}" \
    --no-rebuild \
    --tags harmonyos-core

installed_core="${stage_dir}/usr/local/lib/libqemu_full.so"
if [[ ! -f "${installed_core}" ]]; then
    printf 'Installed HarmonyOS core is missing: %s\n' "${installed_core}" >&2
    exit 2
fi

printf 'HarmonyOS QEMU %s core: %s\n' "${core_flavor}" "${installed_core}"
