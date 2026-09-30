/*
 * HarmonyOS shared-core ABI for QEMU system emulation.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef SYSTEM_QEMU_HMOS_H
#define SYSTEM_QEMU_HMOS_H

#define QEMU_HMOS_EXPORT __attribute__((visibility("default")))
#define QEMU_HMOS_RETAIN __attribute__((used, visibility("default")))

extern QEMU_HMOS_EXPORT const char qemu_hmos_core_marker[];
QEMU_HMOS_EXPORT int qemu_hmos_core_abi_version(void);
QEMU_HMOS_EXPORT const char *qemu_hmos_core_upstream_version(void);
QEMU_HMOS_EXPORT int qemu_hmos_probe(int argc, char **argv);
QEMU_HMOS_EXPORT int qemu_hmos_run(int argc, char **argv);

#ifdef CONFIG_HMOS_EMBEDDED_CORE
QEMU_HMOS_EXPORT int qemu_hmos_phone_run(int argc, char **argv);
/* BQL and replay lock held; vm_shutdown() must have stopped all CPUs. */
void hmos_rr_stop_vcpu_thread(void);
#endif

#endif /* SYSTEM_QEMU_HMOS_H */
