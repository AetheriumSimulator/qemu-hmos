export const version: () => string;
export const enableJit: () => boolean;
export const kvmSupported: () => boolean;
export const startVm: (optionsJson: string) => boolean;
export const stopVm: (name: string) => boolean;

declare const _default: {
  version: typeof version;
  enableJit: typeof enableJit;
  kvmSupported: typeof kvmSupported;
  startVm: typeof startVm;
  stopVm: typeof stopVm;
};
export default _default;
