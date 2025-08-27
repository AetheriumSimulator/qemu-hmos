import { VNCDisplay, VNCDisplayOptions } from '../components/VNCDisplay'
import router from '@ohos.router'

interface VMInfo {
  id: string
  name: string
  vncPort: number
}

@Entry
@Component
struct VNCViewer {
  @State vmInfo: VMInfo | null = null
  @State isFullscreen: boolean = false
  @State showControls: boolean = true
  @State vncOptions: VNCDisplayOptions = {
    host: '127.0.0.1',
    port: 5900,
    onConnected: () => {
      console.info('VNC连接成功')
    },
    onDisconnected: () => {
      console.info('VNC连接断开')
    },
    onError: (error: string) => {
      console.error('VNC连接错误:', error)
    }
  }
  
  aboutToAppear() {
    // 获取路由参数
    const params = router.getParams() as Record<string, Object>
    if (params && params['vmInfo']) {
      this.vmInfo = params['vmInfo'] as VMInfo
      // 更新VNC连接参数
      this.vncOptions = {
        ...this.vncOptions,
        port: this.vmInfo.vncPort || 5900
      }
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
  
  // 切换控制栏显示
  private toggleControls() {
    this.showControls = !this.showControls
  }
  
  build() {
    Column() {
      // 顶部控制栏
      if (this.showControls && !this.isFullscreen) {
        Row() {
          // 返回按钮
          Text('← 返回')
            .fontSize(16)
            .padding(10)
            .onClick(() => {
              this.goBack()
            })
          
          Blank()
          
          // 虚拟机名称
          Text(this.vmInfo?.name || '虚拟机显示')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
          
          Blank()
          
          // 全屏按钮
          Text('全屏')
            .fontSize(16)
            .padding(10)
            .onClick(() => {
              this.toggleFullscreen()
            })
        }
        .width('100%')
        .height(50)
        .backgroundColor('#f8f8f8')
        .border({ width: { bottom: 1 }, color: '#e0e0e0' })
      }
      
      // VNC显示区域
      Stack() {
        VNCDisplay({ options: this.vncOptions })
        
        // 全屏模式下的控制按钮
        if (this.isFullscreen) {
          Row() {
            Text('退出全屏')
              .fontSize(14)
              .fontColor('#ffffff')
              .padding(8)
              .backgroundColor('rgba(0,0,0,0.7)')
              .borderRadius(4)
              .onClick(() => {
                this.toggleFullscreen()
              })
          }
          .position({ x: 10, y: 10 })
        }
        
        // 控制栏切换按钮（非全屏模式）
        if (!this.isFullscreen) {
          Text(this.showControls ? '隐藏控制' : '显示控制')
            .fontSize(12)
            .fontColor('#ffffff')
            .padding(6)
            .backgroundColor('rgba(0,0,0,0.5)')
            .borderRadius(3)
            .position({ x: 10, y: '90%' })
            .onClick(() => {
              this.toggleControls()
            })
        }
      }
      .layoutWeight(1)
      
      // 底部控制栏
      if (this.showControls && !this.isFullscreen) {
        Row() {
          Text('Ctrl')
            .fontSize(14)
            .padding(8)
            .margin(4)
            .backgroundColor('#e0e0e0')
            .borderRadius(4)
            .onClick(() => {
              // 发送Ctrl键
              console.info('发送Ctrl键')
            })
          
          Text('Alt')
            .fontSize(14)
            .padding(8)
            .margin(4)
            .backgroundColor('#e0e0e0')
            .borderRadius(4)
            .onClick(() => {
              // 发送Alt键
              console.info('发送Alt键')
            })
          
          Text('Tab')
            .fontSize(14)
            .padding(8)
            .margin(4)
            .backgroundColor('#e0e0e0')
            .borderRadius(4)
            .onClick(() => {
              // 发送Tab键
              console.info('发送Tab键')
            })
          
          Blank()
          
          Text('重连')
            .fontSize(14)
            .padding(8)
            .margin(4)
            .backgroundColor('#007AFF')
            .fontColor('#ffffff')
            .borderRadius(4)
            .onClick(() => {
              // 重新连接VNC
              console.info('重新连接VNC')
            })
        }
        .width('100%')
        .height(60)
        .backgroundColor('#f8f8f8')
        .border({ width: { top: 1 }, color: '#e0e0e0' })
        .padding({ left: 10, right: 10 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}