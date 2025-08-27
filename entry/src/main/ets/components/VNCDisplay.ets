// 注意：在HarmonyOS中，ArkUI组件和装饰器是全局可用的
// socket和BusinessError模块在实际运行时会被正确解析
import socket from '@ohos.net.socket'
import { BusinessError } from '@ohos.base'

export interface VNCDisplayOptions {
  vmId: string
  vncPort: number
  width?: number
  height?: number
}

/**
 * VNC连接状态枚举
 */
export enum VNCConnectionState {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  ERROR = 'error'
}

/**
 * VNC连接管理类
 */
export class VNCConnection {
  private tcpSocket: socket.TCPSocket | null = null
  private connectionState: VNCConnectionState = VNCConnectionState.DISCONNECTED
  private host: string = ''
  private port: number = 0
  private onStateChanged?: (state: VNCConnectionState) => void
  private onDataReceived?: (data: ArrayBuffer) => void
  private onError?: (error: string) => void

  constructor(callbacks?: {
    onStateChanged?: (state: VNCConnectionState) => void
    onDataReceived?: (data: ArrayBuffer) => void
    onError?: (error: string) => void
  }) {
    if (callbacks) {
      this.onStateChanged = callbacks.onStateChanged
      this.onDataReceived = callbacks.onDataReceived
      this.onError = callbacks.onError
    }
  }

  /**
   * 连接到VNC服务器
   */
  async connect(host: string, port: number): Promise<void> {
    if (this.connectionState === VNCConnectionState.CONNECTING ||
        this.connectionState === VNCConnectionState.CONNECTED) {
      throw new Error('Already connecting or connected')
    }

    this.host = host
    this.port = port
    this.setState(VNCConnectionState.CONNECTING)

    try {
      // 创建TCP Socket连接
      this.tcpSocket = socket.constructTCPSocketInstance()
      
      // 设置事件监听
      this.setupSocketEvents()

      // 绑定本地地址（系统自动分配端口）
      await this.tcpSocket.bind({
        address: '0.0.0.0',
        port: 0,
        family: 1
      })

      // 连接到VNC服务器
      await this.tcpSocket.connect({
        address: {
          address: host,
          port: port,
          family: 1
        },
        timeout: 10000 // 10秒超时
      })

    } catch (error) {
      this.setState(VNCConnectionState.ERROR)
      const errorMsg = `Failed to connect to VNC server: ${error}`
      this.onError?.(errorMsg)
      throw new Error(errorMsg)
    }
  }

  /**
   * 断开VNC连接
   */
  async disconnect(): Promise<void> {
    if (this.tcpSocket) {
      try {
        await this.tcpSocket.close()
      } catch (error) {
        console.error('Error closing socket:', error)
      }
      
      // 移除事件监听
      this.removeSocketEvents()
      this.tcpSocket = null
    }
    
    this.setState(VNCConnectionState.DISCONNECTED)
  }

  /**
   * 发送数据到VNC服务器
   */
  async sendData(data: ArrayBuffer): Promise<void> {
    if (this.connectionState !== VNCConnectionState.CONNECTED || !this.tcpSocket) {
      throw new Error('Not connected to VNC server')
    }

    try {
      await this.tcpSocket.send({ data: data })
    } catch (error) {
      const errorMsg = `Failed to send data: ${error}`
      this.onError?.(errorMsg)
      throw new Error(errorMsg)
    }
  }

  /**
   * 获取当前连接状态
   */
  getState(): VNCConnectionState {
    return this.connectionState
  }

  /**
   * 设置连接状态并通知回调
   */
  private setState(state: VNCConnectionState): void {
    this.connectionState = state
    this.onStateChanged?.(state)
  }

  /**
   * 设置Socket事件监听
   */
  private setupSocketEvents(): void {
    if (!this.tcpSocket) return

    // 连接成功事件
    this.tcpSocket.on('connect', () => {
      console.log('VNC Socket connected')
      this.setState(VNCConnectionState.CONNECTED)
    })

    // 接收数据事件
    this.tcpSocket.on('message', (value) => {
      console.log('VNC data received')
      this.onDataReceived?.(value.message)
    })

    // 连接关闭事件
    this.tcpSocket.on('close', () => {
      console.log('VNC Socket closed')
      this.setState(VNCConnectionState.DISCONNECTED)
    })

    // 错误事件
    this.tcpSocket.on('error', (error) => {
      console.error('VNC Socket error:', error)
      this.setState(VNCConnectionState.ERROR)
      this.onError?.(`Socket error: ${error}`)
    })
  }

  /**
   * 移除Socket事件监听
   */
  private removeSocketEvents(): void {
    if (!this.tcpSocket) return

    this.tcpSocket.off('connect')
    this.tcpSocket.off('message')
    this.tcpSocket.off('close')
    this.tcpSocket.off('error')
  }

  /**
   * 重新连接
   */
  async reconnect(): Promise<void> {
    await this.disconnect()
    await this.connect(this.host, this.port)
  }
}

@Component
export struct VNCDisplay {
  @Prop vmId: string = ''
  @Prop vncPort: number = 5900
  @State canvasWidth: number = 800
  @State canvasHeight: number = 600
  @State isConnected: boolean = false
  @State connectionStatus: string = '未连接'
  @State errorMessage: string = ''
  
  private vncConnection: VNCConnection | null = null
  
  aboutToAppear() {
    this.initVNCConnection()
  }
  
  aboutToDisappear() {
    this.disconnect()
  }
  
  private initVNCConnection() {
    try {
      this.vncConnection = new VNCConnection({
        onStateChanged: (state: VNCConnectionState) => {
          switch (state) {
            case VNCConnectionState.CONNECTING:
              this.connectionStatus = '连接中...'
              break
            case VNCConnectionState.CONNECTED:
              this.connectionStatus = '已连接'
              this.isConnected = true
              this.errorMessage = ''
              break
            case VNCConnectionState.DISCONNECTED:
              this.connectionStatus = '未连接'
              this.isConnected = false
              break
            case VNCConnectionState.ERROR:
              this.connectionStatus = '连接错误'
              this.isConnected = false
              break
          }
        },
        onDataReceived: (data: ArrayBuffer) => {
          this.handleVNCData(data)
        },
        onError: (error: string) => {
          this.errorMessage = error
        }
      })
      
      // 自动连接
      this.connect()
    } catch (error) {
      console.error('初始化VNC连接失败:', error)
      this.errorMessage = `初始化失败: ${error}`
    }
  }
  
  private async connect() {
    if (!this.vncConnection) {
      return
    }

    try {
      // 连接到本地VNC服务器
      await this.vncConnection.connect('127.0.0.1', this.vncPort)
    } catch (error) {
      console.error('VNC连接失败:', error)
      this.errorMessage = `连接失败: ${error}`
    }
  }
  
  private async disconnect() {
    if (this.vncConnection) {
      try {
        await this.vncConnection.disconnect()
      } catch (error) {
        console.error('断开VNC连接失败:', error)
      }
    }
  }
  
  private handleVNCData(data: ArrayBuffer) {
    // TODO: 实现VNC协议数据处理和画面渲染
    console.log('收到VNC数据:', data.byteLength, '字节')
  }
  
  private async sendMouseEvent(x: number, y: number, buttonMask: number) {
    if (this.vncConnection && this.isConnected) {
      try {
        // 创建VNC鼠标事件数据
        const buffer = new ArrayBuffer(6)
        const view = new DataView(buffer)
        view.setUint8(0, 5) // PointerEvent message type
        view.setUint8(1, buttonMask) // Button mask
        view.setUint16(2, x, false) // X position (big-endian)
        view.setUint16(4, y, false) // Y position (big-endian)
        
        await this.vncConnection.sendData(buffer)
      } catch (error) {
        console.error('发送鼠标事件失败:', error)
      }
    }
  }
  
  // 重新连接
  reconnect() {
    this.disconnect()
    setTimeout(() => {
      this.initVNCConnection()
    }, 1000)
  }
  
  build() {
    Column() {
      // 连接状态显示
      Row() {
        Text(`状态: ${this.connectionStatus}`)
          .fontSize(14)
          .fontColor(this.isConnected ? '#00FF00' : '#FF0000')
        
        Blank()
        
        if (!this.isConnected) {
          Button('连接')
            .fontSize(12)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.connect()
            })
        }
        
        if (this.isConnected) {
          Button('断开')
            .fontSize(12)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.disconnect()
            })
        }
      }
      .width('100%')
      .padding(8)
      
      // 错误信息显示
      if (this.errorMessage) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor('#FF0000')
          .padding(8)
      }
      
      // VNC显示区域
      Stack() {
        // 黑色背景表示VNC画面区域
        Rect()
          .width(this.canvasWidth)
          .height(this.canvasHeight)
          .fill('#000000')
          .stroke('#808080')
          .strokeWidth(1)
        
        // 显示虚拟机ID和端口信息
        if (!this.isConnected) {
          Column() {
            Text(`虚拟机: ${this.vmId}`)
              .fontSize(16)
              .fontColor('#FFFFFF')
            Text(`VNC端口: ${this.vncPort}`)
              .fontSize(14)
              .fontColor('#808080')
              .margin({ top: 8 })
          }
        }
      }
      .width(this.canvasWidth)
      .height(this.canvasHeight)
      .onTouch((event) => {
        if (this.isConnected && event.touches && event.touches.length > 0) {
          const touch = event.touches[0]
          let buttonMask = 0
          
          if (event.type === 0) { // TouchType.Down
            buttonMask = 1 // 左键按下
          }
          
          this.sendMouseEvent(Math.floor(touch.x), Math.floor(touch.y), buttonMask)
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}