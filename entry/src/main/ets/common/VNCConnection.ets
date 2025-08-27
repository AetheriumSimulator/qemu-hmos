import socket from '@ohos.net.socket';
import { BusinessError } from '@ohos.base';

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
 * VNC连接事件回调接口
 */
export interface VNCConnectionCallbacks {
  onStateChanged?: (state: VNCConnectionState) => void;
  onDataReceived?: (data: ArrayBuffer) => void;
  onError?: (error: string) => void;
}

/**
 * VNC连接管理类
 */
export class VNCConnection {
  private tcpSocket: socket.TCPSocket | null = null;
  private connectionState: VNCConnectionState = VNCConnectionState.DISCONNECTED;
  private callbacks: VNCConnectionCallbacks = {};
  private host: string = '';
  private port: number = 0;

  constructor(callbacks?: VNCConnectionCallbacks) {
    if (callbacks) {
      this.callbacks = callbacks;
    }
  }

  /**
   * 连接到VNC服务器
   * @param host VNC服务器地址
   * @param port VNC服务器端口
   */
  async connect(host: string, port: number): Promise<void> {
    if (this.connectionState === VNCConnectionState.CONNECTING ||
        this.connectionState === VNCConnectionState.CONNECTED) {
      throw new Error('Already connecting or connected');
    }

    this.host = host;
    this.port = port;
    this.setState(VNCConnectionState.CONNECTING);

    try {
      // 创建TCP Socket连接
      this.tcpSocket = socket.constructTCPSocketInstance();
      
      // 设置事件监听
      this.setupSocketEvents();

      // 绑定本地地址（系统自动分配端口）
      await this.tcpSocket.bind({
        address: '0.0.0.0',
        port: 0,
        family: 1
      });

      // 连接到VNC服务器
      await this.tcpSocket.connect({
        address: {
          address: host,
          port: port,
          family: 1
        },
        timeout: 10000 // 10秒超时
      });

    } catch (error) {
      this.setState(VNCConnectionState.ERROR);
      const errorMsg = `Failed to connect to VNC server: ${error}`;
      this.callbacks.onError?.(errorMsg);
      throw new Error(errorMsg);
    }
  }

  /**
   * 断开VNC连接
   */
  async disconnect(): Promise<void> {
    if (this.tcpSocket) {
      try {
        await this.tcpSocket.close();
      } catch (error) {
        console.error('Error closing socket:', error);
      }
      
      // 移除事件监听
      this.removeSocketEvents();
      this.tcpSocket = null;
    }
    
    this.setState(VNCConnectionState.DISCONNECTED);
  }

  /**
   * 发送数据到VNC服务器
   * @param data 要发送的数据
   */
  async sendData(data: ArrayBuffer): Promise<void> {
    if (this.connectionState !== VNCConnectionState.CONNECTED || !this.tcpSocket) {
      throw new Error('Not connected to VNC server');
    }

    try {
      await this.tcpSocket.send({ data: data });
    } catch (error) {
      const errorMsg = `Failed to send data: ${error}`;
      this.callbacks.onError?.(errorMsg);
      throw new Error(errorMsg);
    }
  }

  /**
   * 获取当前连接状态
   */
  getState(): VNCConnectionState {
    return this.connectionState;
  }

  /**
   * 设置连接状态并通知回调
   */
  private setState(state: VNCConnectionState): void {
    this.connectionState = state;
    this.callbacks.onStateChanged?.(state);
  }

  /**
   * 设置Socket事件监听
   */
  private setupSocketEvents(): void {
    if (!this.tcpSocket) return;

    // 连接成功事件
    this.tcpSocket.on('connect', () => {
      console.log('VNC Socket connected');
      this.setState(VNCConnectionState.CONNECTED);
    });

    // 接收数据事件
    this.tcpSocket.on('message', (value) => {
      console.log('VNC data received');
      this.callbacks.onDataReceived?.(value.message);
    });

    // 连接关闭事件
    this.tcpSocket.on('close', () => {
      console.log('VNC Socket closed');
      this.setState(VNCConnectionState.DISCONNECTED);
    });

    // 错误事件
    this.tcpSocket.on('error', (error) => {
      console.error('VNC Socket error:', error);
      this.setState(VNCConnectionState.ERROR);
      this.callbacks.onError?.(`Socket error: ${error}`);
    });
  }

  /**
   * 移除Socket事件监听
   */
  private removeSocketEvents(): void {
    if (!this.tcpSocket) return;

    this.tcpSocket.off('connect');
    this.tcpSocket.off('message');
    this.tcpSocket.off('close');
    this.tcpSocket.off('error');
  }

  /**
   * 重新连接
   */
  async reconnect(): Promise<void> {
    await this.disconnect();
    await this.connect(this.host, this.port);
  }
}

/**
 * VNC协议相关的工具函数
 */
export class VNCProtocol {
  /**
   * 创建VNC握手消息
   */
  static createHandshakeMessage(): ArrayBuffer {
    // VNC协议版本字符串 "RFB 003.008\n"
    const versionString = "RFB 003.008\n";
    const buffer = new ArrayBuffer(versionString.length);
    const view = new Uint8Array(buffer);
    
    for (let i = 0; i < versionString.length; i++) {
      view[i] = versionString.charCodeAt(i);
    }
    
    return buffer;
  }

  /**
   * 解析VNC服务器版本响应
   */
  static parseServerVersion(data: ArrayBuffer): string {
    const view = new Uint8Array(data);
    let version = '';
    
    for (let i = 0; i < view.length; i++) {
      version += String.fromCharCode(view[i]);
    }
    
    return version.trim();
  }

  /**
   * 创建鼠标事件消息
   */
  static createMouseEvent(x: number, y: number, buttonMask: number): ArrayBuffer {
    const buffer = new ArrayBuffer(6);
    const view = new DataView(buffer);
    
    view.setUint8(0, 5); // PointerEvent message type
    view.setUint8(1, buttonMask); // Button mask
    view.setUint16(2, x, false); // X position (big-endian)
    view.setUint16(4, y, false); // Y position (big-endian)
    
    return buffer;
  }

  /**
   * 创建键盘事件消息
   */
  static createKeyEvent(key: number, down: boolean): ArrayBuffer {
    const buffer = new ArrayBuffer(8);
    const view = new DataView(buffer);
    
    view.setUint8(0, 4); // KeyEvent message type
    view.setUint8(1, down ? 1 : 0); // Down flag
    view.setUint16(2, 0, false); // Padding
    view.setUint32(4, key, false); // Key (big-endian)
    
    return buffer;
  }
}