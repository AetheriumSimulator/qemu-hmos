import { qemu } from '../cpp/types/libqemu_hmos/Index';

interface AppInfo {
  name: string;
  cmd: string;
  icon?: string;
}

@Entry
@Component
struct AppsPage {
  @State apps: AppInfo[] = [
    { name: '记事本', cmd: 'notepad.exe' },
    { name: '计算器', cmd: 'calc.exe' },
    { name: '画图', cmd: 'mspaint.exe' },
    { name: '命令提示符', cmd: 'cmd.exe' }
  ];
  @State loading: boolean = false;
  @State error: string = '';

  private startApp(app: AppInfo) {
    this.loading = true;
    try {
      // 启动VM并运行应用
      const vmConfig: {
        name: string;
        app: string;
      } = {
        name: 'default-vm',
        app: app.cmd
      };
      const ok: boolean = qemu.startVm(vmConfig);
      if (!ok) {
        this.error = '启动失败';
      } else {
        this.error = '';
      }
    } catch (e) {
      this.error = `启动异常: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  build() {
    Column() {
      Text('应用启动器')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      if (this.error) {
        Text(this.error)
          .fontSize(14)
          .color(Color.Red)
          .padding(8)
          .backgroundColor(Color.Red + '20')
          .borderRadius(4)
          .margin({ bottom: 16 })
      }

      List() {
        ForEach(this.apps, (app: AppInfo) => {
          ListItem() {
            Row() {
              Text(app.name)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
              Blank()
              Button('启动')
                .onClick(() => this.startApp(app))
                .enabled(!this.loading)
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(8)
            .margin({ bottom: 8 })
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#F5F5F5')
  }
}
