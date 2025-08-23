import qemu from 'libqemu_hmos.so';

@Component
export struct MinePage {
  @State info: string = '正在检测设备能力...';

  aboutToAppear() {
    this.refresh();
  }

  private refresh() {
    try {
      const ver = qemu.version();
      const jit = qemu.enableJit(); // 尝试开启 JIT
      const kvm = qemu.kvmSupported();
      this.info = `Native=${ver}\nJIT=${jit}\nKVM=${kvm}`;
    } catch (e) {
      this.info = `NAPI 调用失败: ${JSON.stringify(e)}`;
    }
  }

  build() {
    Column() {
      Text('我的')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16, bottom: 12 })
      Text(this.info)
        .fontSize(16)
        .lineHeight(22)
        .fontFamily('monospace')
        .backgroundColor('#1f1f1f')
        .fontColor('#e8e8e8')
        .borderRadius(8)
        .padding(12)
        .width('100%')
      Row() {
        Button('重新检测')
          .type(ButtonType.Capsule)
          .onClick(() => this.refresh())
      }.margin({ top: 12 })
    }.width('100%').height('100%').padding(16)
  }
}
