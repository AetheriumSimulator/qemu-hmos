import { ThemeManager, AppTheme, ThemeMode } from '../common/ThemeManager.ets'
import router from '@ohos.router'
import { Button, ButtonType } from '@ohos.arkui.advanced.Button'
import { Column, Row, Text, List, ListItem, ListItemGroup, Divider, Image } from '@ohos.arkui.advanced.Layout'
import { Color, FontWeight, TextAlign, FlexAlign, VerticalAlign, HorizontalAlign } from '@ohos.arkui.advanced.Common'

@Entry
@Component
export struct SettingsPage {
  @State currentTheme: AppTheme = ThemeManager.getCurrentTheme()
  @State currentThemeMode: ThemeMode = ThemeManager.getThemeMode()
  private themeChangeListener = (theme: AppTheme) => {
    this.currentTheme = theme
  }

  aboutToAppear(): void {
    ThemeManager.addThemeChangeListener(this.themeChangeListener)
  }

  aboutToDisappear(): void {
    ThemeManager.removeThemeChangeListener(this.themeChangeListener)
  }

  private onThemeModeChange(mode: ThemeMode): void {
    this.currentThemeMode = mode
    ThemeManager.setThemeMode(mode)
  }

  private goBack(): void {
    router.back()
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button('返回')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor(this.currentTheme.brandColor)
          .onClick(() => {
            this.goBack()
          })
        
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.currentTheme.primaryTextColor)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        
        // 占位符保持居中
        Button()
          .width(60)
          .height(32)
          .backgroundColor(Color.Transparent)
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      
      Divider()
        .color(this.currentTheme.dividerColor)
        .strokeWidth(0.5)
      
      // 设置内容
      List() {
        // 主题设置
        ListItemGroup({ header: '外观' }) {
          ListItem() {
            Row() {
              Column() {
                Text('主题模式')
                  .fontSize(16)
                  .fontColor(this.currentTheme.primaryTextColor)
                  .fontWeight(FontWeight.Medium)
                Text('选择应用的主题模式')
                  .fontSize(14)
                  .fontColor(this.currentTheme.secondaryTextColor)
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              
              Column() {
                Row() {
                  Button('浅色')
                    .type(this.currentThemeMode === ThemeMode.LIGHT ? ButtonType.Capsule : ButtonType.Normal)
                    .backgroundColor(this.currentThemeMode === ThemeMode.LIGHT ? this.currentTheme.brandColor : this.currentTheme.surfaceColor)
                    .fontColor(this.currentThemeMode === ThemeMode.LIGHT ? Color.White : this.currentTheme.primaryTextColor)
                    .fontSize(12)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .onClick(() => {
                      this.onThemeModeChange(ThemeMode.LIGHT)
                    })
                  
                  Button('深色')
                    .type(this.currentThemeMode === ThemeMode.DARK ? ButtonType.Capsule : ButtonType.Normal)
                    .backgroundColor(this.currentThemeMode === ThemeMode.DARK ? this.currentTheme.brandColor : this.currentTheme.surfaceColor)
                    .fontColor(this.currentThemeMode === ThemeMode.DARK ? Color.White : this.currentTheme.primaryTextColor)
                    .fontSize(12)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .margin({ left: 8 })
                    .onClick(() => {
                      this.onThemeModeChange(ThemeMode.DARK)
                    })
                  
                  Button('自动')
                    .type(this.currentThemeMode === ThemeMode.AUTO ? ButtonType.Capsule : ButtonType.Normal)
                    .backgroundColor(this.currentThemeMode === ThemeMode.AUTO ? this.currentTheme.brandColor : this.currentTheme.surfaceColor)
                    .fontColor(this.currentThemeMode === ThemeMode.AUTO ? Color.White : this.currentTheme.primaryTextColor)
                    .fontSize(12)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .margin({ left: 8 })
                    .onClick(() => {
                      this.onThemeModeChange(ThemeMode.AUTO)
                    })
                }
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
          .backgroundColor(this.currentTheme.surfaceColor)
        }
        .margin({ top: 16 })
        
        // 虚拟机设置
        ListItemGroup({ header: '虚拟机' }) {
          ListItem() {
            Row() {
              Text('默认虚拟机路径')
                .fontSize(16)
                .fontColor(this.currentTheme.primaryTextColor)
                .layoutWeight(1)
              
              Text('~/VirtualMachines')
                .fontSize(14)
                .fontColor(this.currentTheme.secondaryTextColor)
              
              Image($r('app.media.ic_arrow_right'))
                .width(16)
                .height(16)
                .fillColor(this.currentTheme.tertiaryTextColor)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          }
          .backgroundColor(this.currentTheme.surfaceColor)
          .onClick(() => {
            // 选择虚拟机存储路径
          })
          
          ListItem() {
            Row() {
              Text('默认内存大小')
                .fontSize(16)
                .fontColor(this.currentTheme.primaryTextColor)
                .layoutWeight(1)
              
              Text('2GB')
                .fontSize(14)
                .fontColor(this.currentTheme.secondaryTextColor)
              
              Image($r('app.media.ic_arrow_right'))
                .width(16)
                .height(16)
                .fillColor(this.currentTheme.tertiaryTextColor)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          }
          .backgroundColor(this.currentTheme.surfaceColor)
          .onClick(() => {
            // 设置默认内存大小
          })
        }
        .margin({ top: 16 })
        
        // 关于
        ListItemGroup({ header: '关于' }) {
          ListItem() {
            Row() {
              Text('版本信息')
                .fontSize(16)
                .fontColor(this.currentTheme.primaryTextColor)
                .layoutWeight(1)
              
              Text('v1.0.0')
                .fontSize(14)
                .fontColor(this.currentTheme.secondaryTextColor)
              
              Image($r('app.media.ic_arrow_right'))
                .width(16)
                .height(16)
                .fillColor(this.currentTheme.tertiaryTextColor)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          }
          .backgroundColor(this.currentTheme.surfaceColor)
          .onClick(() => {
            // 显示版本信息
          })
        }
        .margin({ top: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(this.currentTheme.backgroundColor)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.currentTheme.backgroundColor)
  }
}