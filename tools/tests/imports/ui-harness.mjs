import { StoragePaths } from './StoragePaths.ts';
import { fs, hilog } from './platform.mjs';
export const ui = { pick: null, starts: [], toasts: [] };
const filePicker = { DocumentViewPicker: class { async select() { return ui.pick; } } };
const promptAction = { showToast(value) { ui.toasts.push(value.message); } };
const getContext = () => ({});
const FirmwareManager = { async ensureUefi() { return '/firmware.fd'; } };
const KeymapsManager = { async ensureKeymaps() { return '/keymaps'; } };
const QemuVMManager = { getInstance: () => ({ async startVM(config) {
  ui.starts.push(config); return { success: false, message: 'stopped at mocked native boundary' };
} }) };
const setTimeout = () => 0;
class PageState {
  vms = []; isLoading = false; isoSelectionBusy = false; isoSelectionEpoch = 0;
  wizardISOPath = ''; errorMessage = ''; selectedVmId = ''; currentSheet = 'wizard';
  sheetVisible = true; startTargetVM = null; saves = 0; settingsVncNativePort = 5901;
  kvmAvailable = false; keymapsAvailable = true;
  async saveAllVMs() { this.saves++; }
  openSheet() {}
}
class WizardState {
  filePickerBusy = false; wizardActive = true; selectionEpoch = 0; fileSelectionError = '';
  isoPath = ''; importedDiskPath = ''; currentStep = 'image'; vmName = '测试机';
  selectedOS = 'Linux'; selectedArch = 'aarch64'; memoryMB = 4096; diskSizeGB = 64; noDisk = false;
  selectedMachine = 'virt'; selectedDisplay = 'virtio-gpu-pci'; selectedNetwork = 'virtio-net'; selectedAudio = 'none';
  completed = []; cancelled = 0;
  onComplete(result) { this.completed.push(result); }
  onCancel() { this.cancelled++; }
  getSteps() { return ['image', 'name', 'done']; }
  getStepIndex() { return this.getSteps().indexOf(this.currentStep); }
}
