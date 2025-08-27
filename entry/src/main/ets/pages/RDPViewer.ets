// RDP远程桌面查看器页面
import { RDPDisplay } from '../components/RDPDisplay'
import router from '@ohos.router'

@Entry
@Component
struct RDPViewer {
  @State vmId: string = ''
  @State vmName: string = ''
  @State rdpHost: string = 'localhost'
  @State rdpPort: number = 3389
  @State isFullscreen: boolean = false
  @State showSettings: boolean = false
  @State connectionQuality: string = 'auto'
  @State colorDepth: number = 16
  @State enableAudio: boolean = true
  @State enableClipboard: boolean = true
  
  aboutToAppear() {
    // 获取路由参数
    const params = router.getParams() as any
    if (params) {
      this.vmId = params.vmId || ''
      this.vmName = params.vmName || '未知虚拟机'
      this.rdpHost = params.rdpHost || 'localhost'
      this.rdpPort = params.rdpPort || 3389
    }
  }
  
  // 返回虚拟机列表
  private goBack() {
    router.back()
  }
  
  // 切换全屏模式
  private toggleFullscreen() {
    this.isFullscreen = !this.isFullscreen
  }
  
  // 显示设置面板
  private showSettingsPanel() {
    this.showSettings = true
  }
  
  // 隐藏设置面板
  private hideSettingsPanel() {
    this.showSettings = false
  }
  
  // 应用设置
  private applySettings() {
    console.log('应用RDP设置:', {
      connectionQuality: this.connectionQuality,
      colorDepth: this.colorDepth,
      enableAudio: this.enableAudio,
      enableClipboard: this.enableClipboard
    })
    this.hideSettingsPanel()
  }
  
  build() {
    Stack() {
      Column() {
        // 顶部工具栏（非全屏模式）
        if (!this.isFullscreen) {
          Row() {
            Button('返回')
              .onClick(() => {
                this.goBack()
              })
              .margin({ right: 8 })
            
            Text(this.vmName)
              .fontSize(16)
              .fontWeight(500)
              .flexGrow(1)
            
            Button('设置')
              .onClick(() => {
                this.showSettingsPanel()
              })
              .margin({ right: 8 })
            
            Button(this.isFullscreen ? '退出全屏' : '全屏')
              .onClick(() => {
                this.toggleFullscreen()
              })
          }
          .width('100%')
          .height(56)
          .padding({ horizontal: 16 })
          .backgroundColor('#F8F9FA')
          .justifyContent(2)
          .alignItems(1)
        }
        
        // RDP显示区域
        RDPDisplay({
          vmId: this.vmId,
          rdpHost: this.rdpHost,
          rdpPort: this.rdpPort
        })
          .width('100%')
          .flexGrow(1)
      }
      .width('100%')
      .height('100%')
      
      // 全屏模式下的浮动控制按钮
      if (this.isFullscreen) {
        Row() {
          Button('退出全屏')
            .onClick(() => {
              this.toggleFullscreen()
            })
            .backgroundColor('#00000080')
            .fontColor('#FFFFFF')
            .borderRadius(4)
        }
        .position({ x: 16, y: 16 })
      }
      
      // 设置面板
      if (this.showSettings) {
        Column() {
          // 设置标题
          Row() {
            Text('RDP连接设置')
              .fontSize(18)
              .fontWeight(600)
              .flexGrow(1)
            
            Button('×')
              .onClick(() => {
                this.hideSettingsPanel()
              })
              .backgroundColor('transparent')
              .fontColor('#666666')
              .fontSize(20)
          }
          .width('100%')
          .padding({ horizontal: 16, vertical: 12 })
          .borderBottom({ width: 1, color: '#E0E0E0' })
          
          // 设置内容
          Column() {
            // 连接质量设置
            Row() {
              Text('连接质量:')
                .fontSize(14)
                .width(80)
              
              Row() {
                Button('自动')
                  .backgroundColor(this.connectionQuality === 'auto' ? '#007DFF' : '#F1F3F5')
                  .fontColor(this.connectionQuality === 'auto' ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.connectionQuality = 'auto'
                  })
                  .margin({ right: 8 })
                
                Button('高质量')
                  .backgroundColor(this.connectionQuality === 'high' ? '#007DFF' : '#F1F3F5')
                  .fontColor(this.connectionQuality === 'high' ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.connectionQuality = 'high'
                  })
                  .margin({ right: 8 })
                
                Button('低延迟')
                  .backgroundColor(this.connectionQuality === 'low_latency' ? '#007DFF' : '#F1F3F5')
                  .fontColor(this.connectionQuality === 'low_latency' ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.connectionQuality = 'low_latency'
                  })
              }
              .flexGrow(1)
            }
            .width('100%')
            .margin({ bottom: 16 })
            
            // 颜色深度设置
            Row() {
              Text('颜色深度:')
                .fontSize(14)
                .width(80)
              
              Row() {
                Button('16位')
                  .backgroundColor(this.colorDepth === 16 ? '#007DFF' : '#F1F3F5')
                  .fontColor(this.colorDepth === 16 ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.colorDepth = 16
                  })
                  .margin({ right: 8 })
                
                Button('24位')
                  .backgroundColor(this.colorDepth === 24 ? '#007DFF' : '#F1F3F5')
                  .fontColor(this.colorDepth === 24 ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.colorDepth = 24
                  })
                  .margin({ right: 8 })
                
                Button('32位')
                  .backgroundColor(this.colorDepth === 32 ? '#007DFF' : '#F1F3F5')
                  .fontColor(this.colorDepth === 32 ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.colorDepth = 32
                  })
              }
              .flexGrow(1)
            }
            .width('100%')
            .margin({ bottom: 16 })
            
            // 音频设置
            Row() {
              Text('启用音频:')
                .fontSize(14)
                .width(80)
              
              // Toggle开关暂时用按钮替代
              Button(this.enableAudio ? '开启' : '关闭')
                .backgroundColor(this.enableAudio ? '#007DFF' : '#F1F3F5')
                .fontColor(this.enableAudio ? '#FFFFFF' : '#333333')
                .onClick(() => {
                  this.enableAudio = !this.enableAudio
                })
            }
            .width('100%')
            .margin({ bottom: 16 })
            
            // 剪贴板设置
            Row() {
              Text('启用剪贴板:')
                .fontSize(14)
                .width(80)
              
              // Toggle开关暂时用按钮替代
              Button(this.enableClipboard ? '开启' : '关闭')
                .backgroundColor(this.enableClipboard ? '#007DFF' : '#F1F3F5')
                .fontColor(this.enableClipboard ? '#FFFFFF' : '#333333')
                .onClick(() => {
                  this.enableClipboard = !this.enableClipboard
                })
            }
            .width('100%')
            .margin({ bottom: 24 })
            
            // 应用按钮
            Button('应用设置')
              .width('100%')
              .onClick(() => {
                this.applySettings()
              })
          }
          .padding(16)
        }
        .width('90%')
        .maxWidth(400)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .shadow({ radius: 10, color: '#00000020' })
        .position({ x: '5%', y: '10%' })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}