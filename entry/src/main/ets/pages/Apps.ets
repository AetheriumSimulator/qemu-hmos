import qemu from 'libqemu_hmos.so';

interface AppInfo {
  name: string;
  cmd: string;
}

@Component
export struct AppsPage {
  @State apps: AppInfo[] = [];
  @State loading: boolean = false;
  @State error: string = '';

  aboutToAppear() {
    this.loadApps();
  }

  private loadApps() {
    this.loading = true;
    try {
      const json = '[{"name":"终端","cmd":"xterm"},{"name":"浏览器","cmd":"firefox"}]';
      this.apps = JSON.parse(json);
      this.error = '';
    } catch (e) {
      this.error = `解析程序列表失败: ${JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  private startApp(app: AppInfo) {
    this.loading = true;
    try {
      const ok: boolean = qemu.startVm(JSON.stringify({ app: app.cmd }));
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
      Text('应用')
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

      ForEach(this.apps, (app: AppInfo) => {
        Button(app.name)
          .type(ButtonType.Capsule)
          .onClick(() => {
            this.startApp(app);
          })
          .margin({ bottom: 8 })
      }, (app: AppInfo) => app.name)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
