import qemu from 'libqemu_hmos.so';
import data_preferences from '@ohos.data.preferences';
import { DownloadManager, DownloadTaskInfo } from '../managers/DownloadManager';

interface VmMeta {
  name: string;
  options: string;
  handle?: number;
  state?: 'running' | 'paused';
}

const PREFS_NAME: string = 'vms';

@Component
export struct VMsPage {
  @State vms: VmMeta[] = [];
  @State loading: boolean = false;
  @State error: string = '';
  @State downloads: DownloadTaskInfo[] = [];
  private pref?: data_preferences.Preferences;
  private dlManager?: DownloadManager;

  async aboutToAppear() {
    await this.loadVms();
    await this.initDownloads();
  }

  private async loadVms() {
    this.loading = true;
    try {
      this.pref = await data_preferences.getPreferences(getContext(this), PREFS_NAME);
      const raw = await this.pref.get('list', '[]');
      this.vms = JSON.parse(raw as string);
      this.error = '';
    } catch (e) {
      this.error = `加载失败: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  private async saveVms() {
    if (!this.pref) {
      return;
    }
    await this.pref.put('list', JSON.stringify(this.vms));
    await this.pref.flush();
  }

  private async initDownloads() {
    this.dlManager = new DownloadManager(getContext(this));
    await this.dlManager.init();
    this.downloads = this.dlManager.getTasks();
    this.dlManager.onUpdate((tasks: DownloadTaskInfo[]) => {
      this.downloads = tasks;
    });
  }

  private addDownload() {
    const url = 'https://example.com/demo.bin';
    const path = `/data/${Date.now()}.bin`;
    this.dlManager?.enqueue(url, path);
  }

  private async addVm() {
    const vm: VmMeta = { name: `demo${Date.now()}`, options: '{"name":"demo"}', sharedDir: '' };
    this.vms.push(vm);
    await this.saveVms();
  }

  private async selectSharedDir(vm: VmMeta) {
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.maxSelectNumber = 1;
      const documentViewPicker = new picker.DocumentViewPicker();
      const result = await documentViewPicker.select(documentSelectOptions);
      if (result && result.length > 0) {
        vm.sharedDir = result[0];
        await this.saveVms();
      }
    } catch (err) {
      const error = err as BusinessError;
      console.error('选择共享目录失败:', error);
    }
  }

  private async start(vm: VmMeta) {
    this.loading = true;
    try {
      const handle: number = qemu.startVm(vm.options);
      if (handle) {
        vm.handle = handle;
        vm.state = 'running';
        this.error = '';
      } else {
        this.error = '启动失败';
      }
    } catch (e) {
      this.error = `启动异常: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  private async stop(vm: VmMeta) {
    this.loading = true;
    try {
      const ok: boolean = vm.handle !== undefined && qemu.stopVm(vm.handle);
      if (ok) {
        vm.state = undefined;
        vm.handle = undefined;
        this.error = '';
      } else {
        this.error = '停止失败';
      }
    } catch (e) {
      this.error = `停止异常: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  private async pause(vm: VmMeta) {
    this.loading = true;
    try {
      const ok: boolean = vm.handle !== undefined && qemu.pauseVm(vm.handle);
      if (ok) {
        vm.state = 'paused';
        this.error = '';
      } else {
        this.error = '暂停失败';
      }
    } catch (e) {
      this.error = `暂停异常: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  private async resume(vm: VmMeta) {
    this.loading = true;
    try {
      const ok: boolean = vm.handle !== undefined && qemu.resumeVm(vm.handle);
      if (ok) {
        vm.state = 'running';
        this.error = '';
      } else {
        this.error = '恢复失败';
      }
    } catch (e) {
      this.error = `恢复异常: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  private async snapshot(vm: VmMeta) {
    this.loading = true;
    try {
      const ok: boolean = vm.handle !== undefined && qemu.snapshotVm(vm.handle);
      if (ok) {
        this.error = '';
      } else {
        this.error = '快照失败';
      }
    } catch (e) {
      this.error = `快照异常: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  build() {
    Column() {
      Text('虚拟机')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16, bottom: 12 })

      if (this.loading) {
        Text('请稍候...')
          .fontSize(16)
          .margin({ bottom: 12 })
      }

      if (this.error) {
        Text(this.error)
          .fontSize(14)
          .fontColor(Color.Red)
          .margin({ bottom: 12 })
      }

      ForEach(this.vms, (vm: VmMeta) => {
        Row({ space: 8 }) {
          Text(vm.name)
            .fontSize(16)
          if (vm.state === 'running') {
            Button('暂停')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.pause(vm);
              })
            Button('快照')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.snapshot(vm);
              })
            Button('停止')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.stop(vm);
              })
          } else if (vm.state === 'paused') {
            Button('恢复')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.resume(vm);
              })
            Button('快照')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.snapshot(vm);
              })
            Button('停止')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.stop(vm);
              })
          } else {
            Button('启动')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.start(vm);
              })
          }

        }
        .margin({ bottom: 8 })
      }, (vm: VmMeta) => vm.name)

      Button('新建虚拟机')
        .type(ButtonType.Capsule)
        .onClick(() => {
          this.addVm();
        })
        .margin({ top: 12 })

      if (this.downloads.length > 0) {
        Text('下载队列')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 24, bottom: 12 })

        ForEach(this.downloads, (task: DownloadTaskInfo) => {
          Column() {
            Text(task.url)
              .fontSize(14)
            Text(`${(task.downloaded * 100 / task.total || 0).toFixed(1)}%  ` +
                 `${(task.speed).toFixed(1)}B/s  ETA ${(task.eta).toFixed(1)}s`)
              .fontSize(12)
          }
          .margin({ bottom: 8 })
        }, (task: DownloadTaskInfo) => task.id)
      }

      Button('添加下载任务')
        .type(ButtonType.Capsule)
        .onClick(() => {
          this.addDownload();
        })
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
