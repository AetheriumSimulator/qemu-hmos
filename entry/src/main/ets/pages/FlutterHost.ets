import { logI } from '../utils/Hilog'

@Entry
@Component
export struct FlutterHost {
  aboutToAppear() {
    logI('[FlutterHost] appear – waiting for Flutter engine attach…')
  }

  build() {
    Column() {
      Text('Flutter UI 宿主已就绪')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 12 })
      Text('请集成 Flutter 引擎到当前 EntryAbility 并通过 MethodChannel(qemu.bridge) 调用平台能力。')
        .fontSize(14)
        .fontColor(Color.Grey)
        .textAlign(TextAlign.Center)
        .margin({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(('app.color.page_bg_color'))
  }
}
