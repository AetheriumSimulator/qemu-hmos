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
      Button('新建虚拟机（占位）')
        .type(ButtonType.Capsule)
        .onClick(() => {
          this.tip = '后续将引导选择系统镜像并创建磁盘...';
        })
    }.width('100%').height('100%').padding(16)
  }
}
