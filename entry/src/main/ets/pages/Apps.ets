@Component
export struct AppsPage {
  @State tip: string = '这里显示客户机内已安装的应用（占位）';

  build() {
    Column() {
      Text('应用')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16, bottom: 12 })
      Text(this.tip)
        .fontSize(16)
        .opacity(0.8)
        .margin({ bottom: 12 })
      Button('打开示例应用（占位）')
        .type(ButtonType.Capsule)
        .onClick(() => {
          this.tip = '后续将通过 FreeRDP RemoteApp/程序启动通道打开指定程序...';
        })
    }.width('100%').height('100%').padding(16)
  }
}
