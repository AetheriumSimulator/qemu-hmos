import qemu from 'libqemu_hmos.so';
import data_preferences from '@ohos.data.preferences';

interface VmMeta {
  name: string;
  options: string;
  running?: boolean;
}

const PREFS_NAME: string = 'vms';

@Component
export struct VMsPage {
  @State vms: VmMeta[] = [];
  @State loading: boolean = false;
  @State error: string = '';
  private pref?: data_preferences.Preferences;

  async aboutToAppear() {
    await this.loadVms();
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

  private async addVm() {
    const vm: VmMeta = { name: `demo${Date.now()}`, options: '{"name":"demo"}' };
    this.vms.push(vm);
    await this.saveVms();
  }

  private async start(vm: VmMeta) {
    this.loading = true;
    try {
      const ok: boolean = qemu.startVm(vm.options);
      if (ok) {
        vm.running = true;
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
      const ok: boolean = qemu.stopVm(vm.name);
      if (ok) {
        vm.running = false;
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
          Button(vm.running ? '停止' : '启动')
            .type(ButtonType.Capsule)
            .onClick(() => {
              if (vm.running) {
                this.stop(vm);
              } else {
                this.start(vm);
              }
            })
        }
        .margin({ bottom: 8 })
      }, (vm: VmMeta) => vm.name)

      Button('新建虚拟机')
        .type(ButtonType.Capsule)
        .onClick(() => {
          this.addVm();
        })
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
