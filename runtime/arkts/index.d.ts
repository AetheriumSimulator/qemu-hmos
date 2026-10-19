/** SPDX-License-Identifier: GPL-2.0-or-later
 * Optional libaether_runtime_napi.so. API 20 / SDK build not yet verified.
 */
export interface RuntimeResult {
  bridgeCode: number;
  coreExitCode: number | null;
  error: string;
  state: number;
}
/** Resolves only after QEMU returns. Never equate resolution with guest ready.
 * QMP greeting / running state and guest readiness need separate observation.
 * No new run may be attempted after an invocation consumes the process.
 */
export const run: (absoluteCorePath: string, argv: string[]) => Promise<RuntimeResult>;
