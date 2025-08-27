import router from '@ohos.router'
import ThemeManager, { AppTheme } from '../common/ThemeManager'

@Entry
@Component
export struct MinePage {
  @State message: string = 'Hello World'
  @State currentTheme: AppTheme = ThemeManager.getCurrentTheme()
  @State userName: string = '用户'
  private themeChangeListener = (theme: AppTheme) => {
    this.currentTheme = theme
  }

  aboutToAppear(): void {
    ThemeManager.addThemeChangeListener(this.themeChangeListener)
  }

  aboutToDisappear(): void {
    ThemeManager.removeThemeChangeListener(this.themeChangeListener)
  }

  build() {
    Column() {
      Text('个人中心')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.currentTheme.primaryTextColor)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ bottom: 16 })
      
      Text('设备信息和设置')
        .fontSize(16)
        .fontColor(this.currentTheme.secondaryTextColor)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 50 })
      
      List() {
        // 设置分组
        ListItemGroup({ header: '设置' }) {
          ListItem() {
            Row() {
              Text('通用设置')
                .fontSize(16)
                .fontColor(this.currentTheme.primaryTextColor)
                .layoutWeight(1)
              
              Image($r('app.media.ic_arrow_right'))
                .width(16)
                .height(16)
                .fillColor(this.currentTheme.tertiaryTextColor)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          }
          .backgroundColor(this.currentTheme.surfaceColor)
          .onClick(() => {
            router.pushUrl({ url: 'pages/Settings' })
              .catch((error: Error) => console.error('跳转设置页面失败:', error))
          })
        }
        .margin({ top: 0 })

        // 设备检测分组
        ListItemGroup({ header: '设备检测' }) {
          ListItem() {
            Row() {
              Text('运行性能测试')
                .fontSize(16)
                .fontColor(this.currentTheme.primaryTextColor)
                .layoutWeight(1)
              
              Image($r('app.media.ic_arrow_right'))
                .width(16)
                .height(16)
                .fillColor(this.currentTheme.tertiaryTextColor)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          }
          .backgroundColor(this.currentTheme.surfaceColor)
          .onClick(() => {
            AlertDialog.show({
              title: '设备检测',
              message: '设备性能检测功能开发中，敬请期待。',
              primaryButton: { value: '确定', action: () => {} }
            })
          })
        }
        .margin({ top: 16 })

        // 关于分组
        ListItemGroup({ header: '关于' }) {
          ListItem() {
            Row() {
              Text('关于应用')
                .fontSize(16)
                .fontColor(this.currentTheme.primaryTextColor)
                .layoutWeight(1)
              
              Image($r('app.media.ic_arrow_right'))
                .width(16)
                .height(16)
                .fillColor(this.currentTheme.tertiaryTextColor)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          }
          .backgroundColor(this.currentTheme.surfaceColor)
          .onClick(() => {
            AlertDialog.show({
              title: '关于应用',
              message: 'QEMU HarmonyOS\n版本: v1.0.0\n\n一个基于QEMU的虚拟机管理应用，支持创建和管理多种操作系统的虚拟机。',
              primaryButton: { value: '确定', action: () => {} }
            })
          })
        }
        .margin({ top: 16 })
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(this.currentTheme.backgroundColor)
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }
}
