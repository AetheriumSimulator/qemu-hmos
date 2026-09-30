#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Development embedded TCI core. Does not stage into a release HAP.
set -euo pipefail

phone_checkout=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
phone_triple=${OHOS_CROSS_TRIPLE:-aarch64-unknown-linux-ohos}
phone_work=${QEMU_PHONE_BUILD_DIR:-"${HOME}/.cache/aether-phone-qemu-${phone_triple}"}
phone_sdk=${OHOS_SDK_DIR:?Set OHOS_SDK_DIR to a HarmonyOS SDK containing native/}
phone_ndk="${phone_sdk}/native"
phone_deps=${OHOS_DEPS_PREFIX:-"${phone_checkout}/../deps/install-ohos"}
phone_cross="${phone_checkout}/../deps/bin"
phone_commit=$(git -C "${phone_checkout}" rev-parse HEAD)
mkdir -p "${phone_work}"

# Capture tracked changes and the explicit new phone source files. Build keys
# include the patch; an uncommitted development binary must never claim to be
# the unchanged pinned commit used by the release manifest.
git -c core.filemode=false -c core.autocrlf=true -c diff.ignoreSubmodules=all -C "${phone_checkout}" diff HEAD --binary \
    -- . ':!subprojects' > "${phone_work}/source.patch.tmp"
phone_new=(qemu_hmos_phone_exports.c qemu_hmos_phone.map util/coroutine-hmos-stack.c)
phone_digest=$({
    printf '%s\n' "${phone_commit}"
    printf '%s\n' "${phone_triple}" "${phone_deps}" "${phone_sdk}"
    cat "${phone_work}/source.patch.tmp"
    for phone_path in "${phone_new[@]}"; do
        printf '%s\n' "${phone_path}"
        cat "${phone_checkout}/${phone_path}"
    done
} | sha256sum | cut -d' ' -f1)
phone_source="${phone_work}/source-${phone_digest}"
phone_build="${phone_work}/build-${phone_digest}"
phone_stage="${phone_work}/stage-${phone_digest}"
if [[ ! -e "${phone_source}/.ready" ]]; then
    mkdir -p "${phone_source}"
    git -C "${phone_checkout}" archive HEAD | tar -x -C "${phone_source}"
    if [[ -s "${phone_work}/source.patch.tmp" ]]; then
        git -C "${phone_source}" apply "${phone_work}/source.patch.tmp"
    fi
    for phone_path in "${phone_new[@]}"; do
        cp "${phone_checkout}/${phone_path}" "${phone_source}/${phone_path}"
    done
    cp "${phone_work}/source.patch.tmp" "${phone_source}/.phone-source.patch"
    printf '%s\n' "${phone_commit}" "${phone_digest}" > "${phone_source}/.ready"
fi

export PKG_CONFIG_LIBDIR="${phone_deps}/lib/pkgconfig:${phone_deps}/share/pkgconfig"
export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"
phone_pkg_config=${PKG_CONFIG:-$(command -v pkg-config)}
export AETHER_PHONE_REAL_PKG_CONFIG="${phone_pkg_config}"
# Resolve relocatable dependency metadata against its current .pc directory.
# Old cross-build prefixes (/work or /e) must not leak into the link command.
cat > "${phone_work}/pkg-config-phone" <<'EOF'
#!/bin/sh
exec "$AETHER_PHONE_REAL_PKG_CONFIG" --define-prefix "$@"
EOF
chmod +x "${phone_work}/pkg-config-phone"
export PKG_CONFIG="${phone_work}/pkg-config-phone"
export AR="${phone_ndk}/llvm/bin/llvm-ar"
export NM="${phone_ndk}/llvm/bin/llvm-nm"
export RANLIB="${phone_ndk}/llvm/bin/llvm-ranlib"
export STRIP="${phone_ndk}/llvm/bin/llvm-strip"
phone_flags='-D__OHOS__=1 -D__HARMONYOS__=1 -DCONFIG_HMOS_EMBEDDED_CORE=1 -fPIC -fvisibility=hidden'
mkdir -p "${phone_build}" "${phone_stage}"
if [[ ! -f "${phone_build}/build.ninja" ]]; then
    (
        cd "${phone_build}"
        "${phone_source}/configure" \
            --target-list=aarch64-softmmu \
            --cross-prefix="${phone_ndk}/llvm/bin/${phone_triple}-" \
            --cc="${phone_ndk}/llvm/bin/${phone_triple}-clang" \
            --cxx="${phone_ndk}/llvm/bin/${phone_triple}-clang++" \
            --host-cc=cc \
            --extra-cflags="${phone_flags}" --extra-cxxflags="${phone_flags}" \
            --extra-ldflags="-fuse-ld=lld -L${phone_deps}/lib" \
            --without-default-features --enable-system --enable-tcg \
            --enable-tcg-interpreter --enable-pixman --enable-vnc \
            --enable-slirp --enable-fdt=internal --enable-tpm --enable-libusb \
            --enable-ohos-ohaudio --audio-drv-list=ohos-ohaudio \
            --with-coroutine=hmos-stack --disable-rust --disable-modules \
            --disable-plugins --disable-tools --disable-docs --disable-guest-agent \
            --disable-opengl --disable-virglrenderer --disable-pie --disable-werror \
            -Ddefault_library=static -Db_staticpic=true -Db_pie=false -Dstrip=false \
            -Dharmonyos_shared_core=false -Dharmonyos_phone_core=true \
            --with-devices-aarch64=harmonyos --without-default-devices
    )
fi
ninja -C "${phone_build}" -j "${QEMU_BUILD_JOBS:-8}" libqemu_phone.so
cp "${phone_build}/libqemu_phone.so" "${phone_stage}/libqemu_phone.so"
"${STRIP}" --strip-unneeded --keep-symbol=tci_tb_ptr --keep-symbol=__emutls_v.tci_tb_ptr "${phone_stage}/libqemu_phone.so"
printf '%s\n' "base_commit=${phone_commit}" "source_digest=${phone_digest}" \
    'reentrant=false' > "${phone_stage}/phone-core-build.txt"
sha256sum "${phone_stage}/libqemu_phone.so" >> "${phone_stage}/phone-core-build.txt"
printf 'Development phone core: %s\n' "${phone_stage}/libqemu_phone.so"
