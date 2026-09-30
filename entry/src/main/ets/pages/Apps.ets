import qemu from 'qemu_hmos';
import router from '@ohos.router';

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
  @State statusMessage: string = '';


  private async startApp(app: AppInfo) {
    this.loading = true;
    this.error = '';
    this.statusMessage = '正在启动虚拟机...';
    
    try {
      // 启动VM并运行应用
      const ok: boolean = qemu.startVm({
        name: 'default-vm',
        accel: qemu.kvmSupported() ? 'kvm' : 'tcg,thread=multi,tb-size=128',
        display: 'vnc=127.0.0.1:1',
        nographic: false
      });
      
      if (!ok) {
        this.error = 'VM启动失败';
        return;
      }
      
      // 真正等待 VM 启动完成
      this.statusMessage = '等待虚拟机就绪...';
      const vmReady = await this.waitForVMReady('default-vm');
      
      if (!vmReady) {
        this.error = 'VM启动超时';
        return;
      }
      
      // 远程应用执行不可用。
      this.error = `无法直接启动 ${app.name}：远程应用功能暂不可用，请通过 VNC 手动启动`;
      this.statusMessage = '正在打开 VNC...';
      router.pushUrl({ url: 'pages/VNCNativeViewer', params: { vmName: 'default-vm', vncHost: '127.0.0.1', vncPort: 5901 } });
      
    } catch (e) {
      this.error = `启动异常: ${e instanceof Error ? e.message : JSON.stringify(e)}`;
    } finally {
      this.loading = false;
      this.statusMessage = '';
    }
  }
  
  /**
   * 等待 VM 就绪（图形服务可用）
   */
  private async waitForVMReady(vmName: string, timeout: number = 60000): Promise<boolean> {
    const startTime = Date.now();
    const checkInterval = 2000;
    
    while (Date.now() - startTime < timeout) {
      try {
        // 检查 VM 状态
        const status = qemu.getVmStatus(vmName);
        if (status === 'running') {
          // 等待图形服务初始化
          await new Promise<void>(resolve => setTimeout(resolve, 3000));
          return true;
        }
      } catch (e) {
        console.warn('[Apps] VM status check failed:', e);
      }
      
      await new Promise<void>(resolve => setTimeout(resolve, checkInterval));
    }
    
    return false;
  }
  

  build() {
    Column() {
      Text('应用启动器')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      if (this.statusMessage) {
        Row() {
          LoadingProgress()
            .width(20)
            .height(20)
            .margin({ right: 8 })
          Text(this.statusMessage)
            .fontSize(14)
            .fontColor('#666666')
        }
        .padding(12)
        .backgroundColor('#E3F2FD')
        .borderRadius(4)
        .margin({ bottom: 16 })
      }

      if (this.error) {
        Text(this.error)
          .fontSize(14)
          .fontColor(Color.Red)
          .padding(8)
          .backgroundColor('#FFEBEE')
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
