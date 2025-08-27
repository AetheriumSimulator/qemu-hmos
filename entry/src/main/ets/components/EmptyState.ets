/**
 * 内容区空状态组件
 */

@Component
export struct EmptyState {
  title: string = '找不到虚拟机'
  subtitle?: string = '请点击右下角 新建虚拟机 进行创建'
  showActionButton: boolean = true
  onActionClick?: () => void

  build() {
    Column() {
      // 占位插画：平板+斜线
      Column() {
        Text('💻')
          .fontSize(64)
          .fontColor('#C7C7CC')
        
        Text('/')
          .fontSize(32)
          .fontColor('#C7C7CC')
          .margin({ top: -20, left: 40 })
      }
      .margin({ bottom: 32 })
      
      // 主标题
      Text(this.title)
        .fontSize(20)
        .fontColor('#000000')
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 8 })
      
      // 次要说明文字
      if (this.subtitle) {
        Text(this.subtitle)
          .fontSize(14)
          .fontColor('#8E8E93')
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .margin({ bottom: 24 })
      }
      
      // 主操作按钮
      if (this.showActionButton) {
        Button('去创建')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .backgroundColor('#007AFF')
          .borderRadius(12)
          .padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .onClick(() => {
            if (this.onActionClick) {
              this.onActionClick()
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#FFFFFF')
    .padding(32)
  }
}