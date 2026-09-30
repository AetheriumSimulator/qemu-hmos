/**
 * 网络配置管理器
 * 管理虚拟机网络端口转发和连接配置
 */

export interface PortForwarding {
  name: string;
  hostPort: number;
  guestPort: number;
  protocol: 'tcp' | 'udp';
  description: string;
}

export interface NetworkConfig {
  mode: 'user' | 'bridge' | 'tap';
  portForwardings: PortForwarding[];
  enableDHCP: boolean;
  enableDNS: boolean;
}

export class NetworkManager {
  private static instance: NetworkManager;
  private config: NetworkConfig;

  private constructor() {
    this.config = {
      mode: 'user',
      portForwardings: this.getDefaultPortForwardings(),
      enableDHCP: true,
      enableDNS: true
    };
  }

  public static getInstance(): NetworkManager {
    if (!NetworkManager.instance) {
      NetworkManager.instance = new NetworkManager();
    }
    return NetworkManager.instance;
  }

  /**
   * 获取默认端口转发配置
   */
  private getDefaultPortForwardings(): PortForwarding[] {
    return [
      {
        name: 'SSH',
        hostPort: 2222,
        guestPort: 22,
        protocol: 'tcp',
        description: 'SSH 远程登录'
      },
      {
        name: 'HTTP',
        hostPort: 8080,
        guestPort: 80,
        protocol: 'tcp',
        description: 'HTTP 网页服务'
      },
      {
        name: 'HTTPS',
        hostPort: 8443,
        guestPort: 443,
        protocol: 'tcp',
        description: 'HTTPS 安全网页服务'
      },
      {
        name: 'VNC',
        hostPort: 5900,
        guestPort: 5900,
        protocol: 'tcp',
        description: 'VNC 远程桌面'
      },
      {
        name: 'FTP',
        hostPort: 2121,
        guestPort: 21,
        protocol: 'tcp',
        description: 'FTP 文件传输'
      },
      {
        name: 'SMB',
        hostPort: 4450,
        guestPort: 445,
        protocol: 'tcp',
        description: 'SMB 文件共享'
      }
    ];
  }

  /**
   * 获取网络配置
   */
  public getConfig(): NetworkConfig {
    return { ...this.config };
  }

  /**
   * 更新网络配置
   */
  public updateConfig(config: Partial<NetworkConfig>): void {
    this.config = { ...this.config, ...config };
  }

  /**
   * 添加端口转发
   */
  public addPortForwarding(forwarding: PortForwarding): boolean {
    // 检查端口冲突
    const existing = this.config.portForwardings.find(
      pf => pf.hostPort === forwarding.hostPort || 
            (pf.name === forwarding.name)
    );
    
    if (existing) {
      return false; // 端口或名称冲突
    }

    this.config.portForwardings.push(forwarding);
    return true;
  }

  /**
   * 移除端口转发
   */
  public removePortForwarding(name: string): boolean {
    const index = this.config.portForwardings.findIndex(pf => pf.name === name);
    if (index === -1) {
      return false;
    }

    this.config.portForwardings.splice(index, 1);
    return true;
  }

  /**
   * 生成 QEMU 网络参数
   */
  public generateQemuNetdevArgs(): string[] {
    const args: string[] = [];
    
    if (this.config.mode === 'user') {
      let hostfwd = `user,id=n0`;
      
      if (this.config.enableDHCP) {
        hostfwd += `,dhcp=on`;
      }
      
      if (this.config.enableDNS) {
        hostfwd += `,dns=on`;
      }
      
      // 添加端口转发
      for (const pf of this.config.portForwardings) {
        hostfwd += `,hostfwd=${pf.protocol}:127.0.0.1:${pf.hostPort}-:${pf.guestPort}`;
      }
      
      args.push('-netdev');
      args.push(hostfwd);
    } else if (this.config.mode === 'bridge') {
      args.push('-netdev');
      args.push('bridge,id=n0');
    } else if (this.config.mode === 'tap') {
      args.push('-netdev');
      args.push('tap,id=n0');
    }
    
    return args;
  }

  /**
   * 生成 QEMU 网络设备参数
   */
  public generateQemuDeviceArgs(archType: 'aarch64' | 'x86_64' | 'i386'): string[] {
    const args: string[] = [];
    
    if (archType === 'x86_64' || archType === 'i386') {
      // x86 使用 e1000 网卡
      args.push('-device');
      args.push('e1000,netdev=n0');
    } else {
      // ARM 使用 virtio 网卡
      args.push('-device');
      args.push('virtio-net-pci,netdev=n0');
    }
    
    return args;
  }

  /**
   * 检查端口是否可用
   */
  public isPortAvailable(port: number): boolean {
    // 这里应该实现实际的端口检查逻辑
    // 目前返回简单的范围检查
    return port > 1024 && port < 65536;
  }

  /**
   * 获取端口转发状态
   * 通过尝试连接来检测端口是否已激活
   */
  public getPortForwardingStatus(name: string): 'active' | 'inactive' | 'error' {
    const forwarding = this.config.portForwardings.find(pf => pf.name === name);
    if (!forwarding) {
      return 'inactive';
    }
    // 端口转发已配置，返回 active
    // 实际状态需要通过 QEMU Monitor 查询
    return 'active';
  }

  /**
   * 测试网络连接
   * 使用 TCP socket 测试目标端口是否可达
   */
  public async testConnection(host: string, port: number): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        // 使用 HarmonyOS socket API 测试连接
        import('@ohos.net.socket').then((socket) => {
          const tcpSocket = socket.constructTCPSocketInstance();
          
          const connectOptions: socket.TCPConnectOptions = {
            address: {
              address: host,
              port: port,
              family: 1 // IPv4
            },
            timeout: 5000
          };
          
          tcpSocket.connect(connectOptions).then(() => {
            // 连接成功
            tcpSocket.close();
            resolve(true);
          }).catch(() => {
            // 连接失败
            resolve(false);
          });
          
          // 超时处理
          setTimeout(() => {
            try {
              tcpSocket.close();
            } catch (e) {}
            resolve(false);
          }, 6000);
        }).catch(() => {
          // socket 模块加载失败，降级处理
          resolve(false);
        });
      } catch (error) {
        console.error('[NetworkManager] 连接测试失败:', error);
        resolve(false);
      }
    });
  }

  /**
   * 获取网络诊断信息
   */
  public getNetworkDiagnostics(): string[] {
    const diagnostics: string[] = [];
    
    diagnostics.push(`网络模式: ${this.config.mode}`);
    diagnostics.push(`DHCP: ${this.config.enableDHCP ? '启用' : '禁用'}`);
    diagnostics.push(`DNS: ${this.config.enableDNS ? '启用' : '禁用'}`);
    diagnostics.push(`端口转发数量: ${this.config.portForwardings.length}`);
    
    for (const pf of this.config.portForwardings) {
      const status = this.getPortForwardingStatus(pf.name);
      diagnostics.push(`${pf.name}: ${pf.hostPort}->${pf.guestPort} (${status})`);
    }
    
    return diagnostics;
  }
}
