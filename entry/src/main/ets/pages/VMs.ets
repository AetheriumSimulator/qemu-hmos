import qemu from 'libqemu_hmos.so';

@Component
export struct VMsPage {
  @State tip: string = '这里将展示所有已安装的虚拟机（占位）';

  build() {
    Column() {
      Text('虚拟机')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16, bottom: 12 })
      Text(this.tip)
        .fontSize(16)
        .opacity(0.8)
        .margin({ bottom: 12 })
      Row() {
        Button('新建虚拟机（占位）')
          .type(ButtonType.Capsule)
          .onClick(() => {
            this.tip = '后续将引导选择系统镜像并创建磁盘...';
          })
      }
      .margin({ bottom: 8 })
      // 集成 QEMU：提供最小可行的环境检测与启动/停止占位
      Row({ space: 8 }) {
        Button('检测运行环境')
          .type(ButtonType.Capsule)
          .onClick(() => {
            try {
              const ver: string = qemu.version();
              const jit: boolean = qemu.enableJit();
              const kvm: boolean = qemu.kvmSupported();
              this.tip = `Native=${ver}  JIT=${jit}  KVM=${kvm}`;
            } catch (e) {
              this.tip = `环境检测失败: ${JSON.stringify(e)}`;
            }
          })
        Button('启动占位 VM')
          .type(ButtonType.Capsule)
          .onClick(() => {
            try {
              const ok: boolean = qemu.startVm('{"name":"demo"}');
              this.tip = ok ? '已调用原生启动（占位）' : '启动失败（占位）';
            } catch (e) {
              this.tip = `启动异常: ${JSON.stringify(e)}`;
            }
          })
        Button('停止')
          .type(ButtonType.Capsule)
          .onClick(() => {
            try {
              const ok: boolean = qemu.stopVm('demo');
              this.tip = ok ? '已停止（占位）' : '停止失败（占位）';
            } catch (e) {
              this.tip = `停止异常: ${JSON.stringify(e)}`;
            }
          })
      }
    }.width('100%').height('100%').padding(16)
  }
}
