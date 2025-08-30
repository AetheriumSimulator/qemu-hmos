export const version: () => string;
export const enableJit: () => boolean;
export const kvmSupported: () => boolean;
export const startVm: (optionsJson: string) => number;
export const stopVm: (handle: number) => boolean;
export const pauseVm: (handle: number) => boolean;
export const resumeVm: (handle: number) => boolean;
export const snapshotVm: (handle: number) => boolean;

declare const _default: {
  version: typeof version;
  enableJit: typeof enableJit;
  kvmSupported: typeof kvmSupported;
  startVm: typeof startVm;
  stopVm: typeof stopVm;
  pauseVm: typeof pauseVm;
  resumeVm: typeof resumeVm;
  snapshotVm: typeof snapshotVm;
};
export default _default;
