import router from '@ohos.router'
import ThemeManager, { AppTheme } from '../common/ThemeManager'
import qemu from 'libqemu_hmos.so'

interface Capability {
  name: string
  supported: boolean
  tip?: string
}

@Entry
@Component
export struct MinePage {
  @State message: string = 'Hello World'
  @State currentTheme: AppTheme = ThemeManager.getCurrentTheme()
  @State userName: string = '用户'
  @State capabilities: Capability[] = []
  private themeChangeListener = (theme: AppTheme) => {
    this.currentTheme = theme
  }

  aboutToAppear(): void {
    ThemeManager.addThemeChangeListener(this.themeChangeListener)
    this.detectCapabilities()
  }

  aboutToDisappear(): void {
    ThemeManager.removeThemeChangeListener(this.themeChangeListener)
  }

  private detectCapabilities() {
    const caps: Capability[] = []
    try {
      qemu.enableJit()
      caps.push({ name: 'JIT', supported: true })
    } catch (e) {
      caps.push({ name: 'JIT', supported: false, tip: 'JIT 不可用，可能影响性能' })
    }
    try {
      qemu.kvmSupported()
      caps.push({ name: 'KVM', supported: true })
    } catch (e) {
      caps.push({ name: 'KVM', supported: false, tip: '未检测到 KVM，虚拟机将退回软件加速' })
    }
    this.capabilities = caps
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
          ForEach(this.capabilities, (cap: Capability) => {
            ListItem() {
              Column() {
                Row() {
                  Text(cap.name)
                    .fontSize(16)
                    .fontColor(this.currentTheme.primaryTextColor)
                    .layoutWeight(1)

                  Text(cap.supported ? '支持' : '不支持')
                    .fontSize(16)
                    .fontColor(cap.supported ? this.currentTheme.secondaryTextColor : Color.Red)
                }
                .width('100%')

                if (!cap.supported && cap.tip) {
                  Text(cap.tip)
                    .fontSize(14)
                    .fontColor(Color.Red)
                    .margin({ top: 4 })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            }
            .backgroundColor(this.currentTheme.surfaceColor)
          }, (cap: Capability) => cap.name)

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
