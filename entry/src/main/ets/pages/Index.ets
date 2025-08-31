import hilog from '@ohos.hilog';

// QEMU配置接口
interface VMConfig {
  name: string;
  isoPath?: string;
  diskSizeGB?: number;
  memoryMB?: number;
  cpuCount?: number;
  accel?: string;
  display?: string;
  nographic?: boolean;
}

// QEMU API接口
interface QemuAPI {
  version(): string;
  enableJit(): boolean;
  kvmSupported(): boolean;
  startVm(config: VMConfig): boolean;
  stopVm(name: string): boolean;
  getVmLogs(name: string, startLine?: number): string[];
  getVmStatus(name: string): string;
}

// 模拟QEMU API实现类，用于开发阶段
class MockQemu implements QemuAPI {
  version(): string {
    return 'QEMU 8.0.0 (模拟版本)';
  }
  
  enableJit(): boolean {
    return true;
  }
  
  kvmSupported(): boolean {
    return false;
  }
  
  startVm(config: VMConfig): boolean {
    console.log('启动VM:', config);
    return true;
  }
  
  stopVm(name: string): boolean {
    console.log('停止VM:', name);
    return true;
  }
  
  getVmLogs(name: string, startLine: number = 0): string[] {
    return [`VM ${name} 的日志记录`];
  }
  
  getVmStatus(name: string): string {
    return 'stopped';
  }
}

// 创建qemu实例
const qemu: QemuAPI = new MockQemu();

// QEMU配置类
class QemuConfig {
  name: string = '';
  osType: string = 'Windows';
  diskSizeGB: number = 64;
  memoryMB: number = 6144;
  cpuCount: number = 4;
}

// VM元数据类
class VMMeta {
  id: string = '';
  name: string = '';
  osType: string = 'Windows';
  status: 'creating' | 'preparing' | 'running' | 'stopping' | 'stopped' | 'failed' | 'starting' = 'stopped';
  createdAt: number = Date.now();
  config: QemuConfig = new QemuConfig();
}

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State testResult: string = '正在检测系统能力...';
  @State vms: VMMeta[] = [];
  @State showCreateDialog: boolean = false;
  @State newVMName: string = '';
  @State newVMOS: string = 'Windows';
  @State newVMDiskSize: number = 64;
  @State newVMMemory: number = 6144;
  @State newVMCPU: number = 4;
  @State isLoading: boolean = false;
  @State errorMessage: string = '';

  aboutToAppear() {
    this.testQemuFunctions();
    this.loadSampleVMs();
  }

  // 测试QEMU NAPI功能
  async testQemuFunctions() {
    try {
      this.isLoading = true;
      this.errorMessage = '';
      
      // 测试版本信息
      const version: string = qemu.version();
      hilog.info(0x0000, 'QEMU_TEST', 'QEMU版本: %{public}s', version);
      
      // 测试JIT权限
      const jitEnabled: boolean = qemu.enableJit();
      hilog.info(0x0000, 'QEMU_TEST', 'JIT权限: %{public}s', jitEnabled ? '已启用' : '未启用');
      
      // 测试KVM支持
      const kvmSupported: boolean = qemu.kvmSupported();
      hilog.info(0x0000, 'QEMU_TEST', 'KVM支持: %{public}s', kvmSupported ? '支持' : '不支持');
      
      this.testResult = `QEMU ${version}\nJIT: ${jitEnabled ? '✓' : '✗'}\nKVM: ${kvmSupported ? '✓' : '✗'}`;
    } catch (error) {
      const errorMsg: string = error instanceof Error ? error.message : String(error);
      hilog.error(0x0000, 'QEMU_TEST', 'NAPI测试失败: %{public}s', errorMsg);
      this.testResult = 'NAPI测试失败，请检查模块加载';
      this.errorMessage = `NAPI错误: ${errorMsg}`;
    } finally {
      this.isLoading = false;
    }
  }

  // 加载示例VM数据
  loadSampleVMs() {
    this.vms = [
      {
        id: '1',
        name: 'Windows 11 开发环境',
        osType: 'Windows',
        status: 'stopped',
        createdAt: Date.now() - 86400000, // 1天前
        config: {
          name: 'Windows 11 开发环境',
          osType: 'Windows',
          diskSizeGB: 128,
          memoryMB: 8192,
          cpuCount: 4
        }
      },
      {
        id: '2',
        name: 'Ubuntu 22.04 服务器',
        osType: 'Linux',
        status: 'stopped',
        createdAt: Date.now() - 172800000, // 2天前
        config: {
          name: 'Ubuntu 22.04 服务器',
          osType: 'Linux',
          diskSizeGB: 64,
          memoryMB: 4096,
          cpuCount: 2
        }
      }
    ];
  }

  // 创建新VM
  async createVM() {
    if (!this.newVMName.trim()) {
      this.errorMessage = '请输入虚拟机名称';
      return;
    }

    try {
      this.isLoading = true;
      this.errorMessage = '';
      
      const newVM = new VMMeta();
      newVM.id = Date.now().toString();
      newVM.name = this.newVMName.trim();
      newVM.osType = this.newVMOS;
      newVM.status = 'creating';
      newVM.config = {
        name: this.newVMName.trim(),
        osType: this.newVMOS,
        diskSizeGB: this.newVMDiskSize,
        memoryMB: this.newVMMemory,
        cpuCount: this.newVMCPU
      };

      this.vms.push(newVM);
      
      // 模拟创建过程
      setTimeout(() => {
        newVM.status = 'stopped';
        this.showCreateDialog = false;
        this.resetCreateForm();
      }, 2000);

      hilog.info(0x0000, 'VM_CREATE', '创建VM: %{public}s', newVM.name);
    } catch (error) {
      const errorMsg: string = error instanceof Error ? error.message : String(error);
      hilog.error(0x0000, 'VM_CREATE', '创建VM失败: %{public}s', errorMsg);
      this.errorMessage = `创建失败: ${errorMsg}`;
    } finally {
      this.isLoading = false;
    }
  }

  // 启动VM
  async startVM(vm: VMMeta) {
    try {
      this.isLoading = true;
      this.errorMessage = '';
      
      vm.status = 'starting';
      hilog.info(0x0000, 'VM_START', '启动VM: %{public}s', vm.name);

      // 调用真正的NAPI启动VM
      const success: boolean = qemu.startVm({
        name: vm.name,
        diskSizeGB: vm.config.diskSizeGB,
        memoryMB: vm.config.memoryMB,
        cpuCount: vm.config.cpuCount,
        accel: qemu.kvmSupported() ? 'kvm' : 'tcg',
        display: 'vnc',
        nographic: false
      });

      if (success) {
        // 模拟启动过程
        setTimeout(() => {
          vm.status = 'running';
          hilog.info(0x0000, 'VM_START', 'VM启动成功: %{public}s', vm.name);
        }, 1000);
      } else {
        vm.status = 'failed';
        this.errorMessage = 'VM启动失败';
        hilog.error(0x0000, 'VM_START', 'VM启动失败: %{public}s', vm.name);
      }
    } catch (error) {
      vm.status = 'failed';
      const errorMsg: string = error instanceof Error ? error.message : String(error);
      this.errorMessage = `启动失败: ${errorMsg}`;
      hilog.error(0x0000, 'VM_START', 'VM启动异常: %{public}s', errorMsg);
    } finally {
      this.isLoading = false;
    }
  }

  // 停止VM
  async stopVM(vm: VMMeta) {
    try {
      this.isLoading = true;
      this.errorMessage = '';
      
      vm.status = 'stopping';
      hilog.info(0x0000, 'VM_STOP', '停止VM: %{public}s', vm.name);

      // 调用真正的NAPI停止VM
      const success: boolean = qemu.stopVm(vm.name);

      if (success) {
        // 模拟停止过程
        setTimeout(() => {
          vm.status = 'stopped';
          hilog.info(0x0000, 'VM_STOP', 'VM停止成功: %{public}s', vm.name);
        }, 1000);
      } else {
        this.errorMessage = 'VM停止失败';
        hilog.error(0x0000, 'VM_STOP', 'VM停止失败: %{public}s', vm.name);
      }
    } catch (error) {
      const errorMsg: string = error instanceof Error ? error.message : String(error);
      this.errorMessage = `停止失败: ${errorMsg}`;
      hilog.error(0x0000, 'VM_STOP', 'VM停止异常: %{public}s', errorMsg);
    } finally {
      this.isLoading = false;
    }
  }

  // 重置创建表单
  resetCreateForm() {
    this.newVMName = '';
    this.newVMOS = 'Windows';
    this.newVMDiskSize = 64;
    this.newVMMemory = 6144;
    this.newVMCPU = 4;
  }

  // 获取状态颜色
  getStatusColor(status: string): string {
    switch (status) {
      case 'running': return '#00C853';
      case 'starting': return '#FF9800';
      case 'stopping': return '#FF9800';
      case 'stopped': return '#9E9E9E';
      case 'failed': return '#F44336';
      case 'creating': return '#2196F3';
      case 'preparing': return '#2196F3';
      default: return '#9E9E9E';
    }
  }

  // 获取状态文本
  getStatusText(status: string): string {
    switch (status) {
      case 'running': return '运行中';
      case 'starting': return '启动中';
      case 'stopping': return '停止中';
      case 'stopped': return '已停止';
      case 'failed': return '启动失败';
      case 'creating': return '创建中';
      case 'preparing': return '准备中';
      default: return '未知状态';
    }
  }

  build() {
    Stack() {
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          Column() {
            // 顶部标题区域
            Row() {
              Column() {
                Text('虚拟机管理')
                  .fontSize(28)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .margin({ bottom: 4 });
                Text('QEMU功能测试')
                  .fontSize(14)
                  .fontColor('#666666')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);

              if (this.isLoading) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color('#007DFF');
              }
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 16, bottom: 20 });

            // QEMU功能测试卡片
    Column() {
              Text('系统能力检测')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .margin({ bottom: 12 });

              if (this.isLoading) {
      Row() {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color('#007DFF')
                    .margin({ right: 8 });
                  Text('正在检测...')
                    .fontSize(14)
                    .fontColor('#666666')
                }
                .margin({ bottom: 12 });
              }

              Text(this.testResult)
                .fontSize(13)
                .fontColor('#333333')
                .textAlign(TextAlign.Start)
                .backgroundColor('#F8F9FA')
                .padding(16)
                .borderRadius(12)
                .width('100%')
                .border({ width: 1, color: '#E8E8E8' });

              if (this.errorMessage) {
                Text(this.errorMessage)
                  .fontSize(12)
                  .fontColor('#F44336')
                  .margin({ top: 8 })
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .backgroundColor('#FFEBEE')
                  .borderRadius(8)
                  .width('100%');
              }
            }
            .padding(20)
            .backgroundColor(Color.White)
            .borderRadius(16)
            .margin({ left: 20, right: 20, bottom: 20 })
            .shadow({ radius: 8, color: '#00000008', offsetX: 0, offsetY: 2 });

            // 创建新虚拟机按钮
            Button('创建新虚拟机')
              .width('90%')
              .height(52)
              .backgroundColor('#007DFF')
              .fontColor(Color.White)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .borderRadius(26)
          .onClick(() => {
                this.showCreateDialog = true;
              })
              .margin({ bottom: 24 })
              .shadow({ radius: 12, color: '#007DFF40', offsetX: 0, offsetY: 4 });

            // VM列表
            if (this.vms.length > 0) {
              List() {
                ForEach(this.vms, (vm: VMMeta) => {
                  ListItem() {
                    Column() {
                      Row() {
                        Column() {
                          Text(vm.name)
                            .fontSize(16)
                            .fontWeight(FontWeight.Medium)
                            .fontColor('#1A1A1A');
                          Text(vm.osType)
          .fontSize(12)
                            .fontColor('#666666')
                            .margin({ top: 4 });
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start);

                        Column() {
                          Text(this.getStatusText(vm.status))
                            .fontSize(11)
                            .fontColor(Color.White)
                            .backgroundColor(this.getStatusColor(vm.status))
                            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                            .borderRadius(12);
                          Text(`${vm.config.cpuCount}核 ${vm.config.memoryMB / 1024}GB`)
                            .fontSize(10)
                            .fontColor('#999999')
                            .margin({ top: 6 });
                        }
                        .alignItems(HorizontalAlign.End);
                      }
                      .width('100%')
                      .margin({ bottom: 16 });

                      Row() {
                        Button(vm.status === 'running' ? '停止' : '启动')
                          .width(72)
                          .height(36)
                          .fontSize(13)
                          .backgroundColor(vm.status === 'running' ? '#FF9800' : '#00C853')
                          .fontColor(Color.White)
                          .borderRadius(18)
                          .onClick(() => {
                            if (vm.status === 'running') {
                              this.stopVM(vm);
                            } else {
                              this.startVM(vm);
                            }
                          })
                          .enabled(!this.isLoading && vm.status !== 'starting' && vm.status !== 'stopping');

                        Button('快照')
                          .width(72)
                          .height(36)
                          .fontSize(13)
                          .backgroundColor('#9C27B0')
                          .fontColor(Color.White)
                          .borderRadius(18)
                          .margin({ left: 12 })
                          .enabled(vm.status === 'running');

                        Button('删除')
                          .width(72)
                          .height(36)
                          .fontSize(13)
                          .backgroundColor('#F44336')
                          .fontColor(Color.White)
                          .borderRadius(18)
                          .margin({ left: 12 })
                          .enabled(vm.status === 'stopped');
                      }
                      .width('100%')
                      .justifyContent(FlexAlign.Start);
                    }
                    .padding(20)
                    .backgroundColor(Color.White)
                    .borderRadius(16)
                    .margin({ left: 20, right: 20, bottom: 16 })
                    .shadow({ radius: 8, color: '#00000008', offsetX: 0, offsetY: 2 });
                  }
                });
      }
      .width('100%')
              .layoutWeight(1);
            } else {
              // 空状态
              Column() {
                Circle()
                  .width(120)
                  .height(120)
                  .fill('#E8E8E8')
                  .margin({ bottom: 16 })
                  .opacity(0.6);

                Text('暂无虚拟机')
                  .fontSize(16)
                  .fontColor('#999999')
                  .margin({ bottom: 8 });

                Text('点击上方按钮创建第一个虚拟机')
                  .fontSize(14)
                  .fontColor('#CCCCCC');
              }
              .width('100%')
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center);
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#F5F7FA');
        }
        .tabBar('虚拟机')
        .backgroundColor('#F5F7FA');

        TabContent() {
          Column() {
            // 顶部标题
            Text('应用管理')
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
              .margin({ top: 100, bottom: 20 });

            // 功能卡片
            Column() {
              Text('功能特性')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .margin({ bottom: 16 });

              Row() {
                Column() {
                  Circle()
                    .width(48)
                    .height(48)
                    .fill('#007DFF')
                    .margin({ bottom: 8 });
                  Text('应用启动')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333');
                  Text('启动虚拟机应用')
                    .fontSize(12)
                    .fontColor('#666666')
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center);

                Column() {
                  Circle()
                    .width(48)
                    .height(48)
                    .fill('#00C853')
                    .margin({ bottom: 8 });
                  Text('远程窗口')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333');
                  Text('独立应用窗口')
                    .fontSize(12)
                    .fontColor('#666666')
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center);

                Column() {
                  Circle()
                    .width(48)
                    .height(48)
                    .fill('#FF9800')
                    .margin({ bottom: 8 });
                  Text('桌面集成')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333');
                  Text('鸿蒙桌面集成')
                    .fontSize(12)
                    .fontColor('#666666')
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center);
              }
              .width('100%')
              .margin({ bottom: 24 });

              Text('• 支持Windows和Linux应用程序')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ bottom: 8 });

              Text('• 远程应用窗口独立显示')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ bottom: 8 });

              Text('• 与鸿蒙系统深度集成')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ bottom: 8 });

              Text('• 支持应用快捷方式创建')
                .fontSize(14)
                .fontColor('#666666');
            }
            .padding(24)
            .backgroundColor(Color.White)
            .borderRadius(16)
            .margin({ left: 20, right: 20 })
            .shadow({ radius: 8, color: '#00000008', offsetX: 0, offsetY: 2 });
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#F5F7FA')
          .padding({ top: 20 });
        }
        .tabBar('应用')
        .backgroundColor('#F5F7FA');

        TabContent() {
          Column() {
            // 顶部标题
            Text('个人中心')
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
              .margin({ top: 100, bottom: 20 });

            // 功能卡片
            Column() {
              Text('系统功能')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .margin({ bottom: 16 });

              Row() {
                Column() {
                  Circle()
                    .width(48)
                    .height(48)
                    .fill('#9C27B0')
                    .margin({ bottom: 8 });
                  Text('镜像管理')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333');
                  Text('下载系统镜像')
                    .fontSize(12)
                    .fontColor('#666666')
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center);

                Column() {
                  Circle()
                    .width(48)
                    .height(48)
                    .fill('#607D8B')
                    .margin({ bottom: 8 });
                  Text('空间管理')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333');
                  Text('磁盘空间监控')
                    .fontSize(12)
                    .fontColor('#666666')
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center);

                Column() {
                  Circle()
                    .width(48)
                    .height(48)
                    .fill('#795548')
                    .margin({ bottom: 8 });
                  Text('系统设置')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333');
                  Text('应用配置选项')
                    .fontSize(12)
                    .fontColor('#666666')
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center);
              }
              .width('100%')
              .margin({ bottom: 24 });

              Text('• 支持断点续传下载')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ bottom: 8 });

              Text('• 实时空间占用统计')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ bottom: 8 });

              Text('• 高级QEMU参数配置')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ top: 8 });
            }
            .padding(24)
            .backgroundColor(Color.White)
            .borderRadius(16)
            .margin({ left: 20, right: 20 })
            .shadow({ radius: 8, color: '#00000008', offsetX: 0, offsetY: 2 });
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#F5F7FA')
          .padding({ top: 20 });
        }
        .tabBar('我的')
        .backgroundColor('#F5F7FA');
      }
      .barMode(BarMode.Fixed)
      .scrollable(false)
      .barHeight(64)
      .backgroundColor(Color.White)
      .border({ width: { top: 1 }, color: '#E8E8E8' });

      // VM创建对话框
      if (this.showCreateDialog) {
        Column() {
          Column() {
            Row() {
              Text('创建新虚拟机')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')
                .layoutWeight(1);

              Button({ type: ButtonType.Circle }) {
                Text('×')
                  .fontSize(18)
                  .fontColor('#666666')
              }
              .width(32)
              .height(32)
              .backgroundColor('#F5F5F5')
              .onClick(() => {
                this.showCreateDialog = false;
                this.resetCreateForm();
              });
            }
            .width('100%')
            .margin({ bottom: 24 });

            TextInput({ placeholder: '请输入虚拟机名称' })
              .width('100%')
              .height(48)
              .backgroundColor('#F8F9FA')
              .borderRadius(12)
              .margin({ bottom: 20 })
              .padding({ left: 16, right: 16 })
              .border({ width: 1, color: '#E8E8E8' })
              .onChange((value: string) => {
                this.newVMName = value;
              });

            Row() {
              Text('操作系统')
                .fontSize(14)
                .fontColor('#666666')
                .width(80);

              Select([
                { value: 'Windows' },
                { value: 'Linux' }
              ])
                .selected(0)
                .onSelect((index: number) => {
                  this.newVMOS = index === 0 ? 'Windows' : 'Linux';
                })
                .layoutWeight(1);
            }
            .width('100%')
            .margin({ bottom: 20 });

            Row() {
              Text('磁盘大小')
                .fontSize(14)
                .fontColor('#666666')
                .width(80);

              Select([
                { value: '32' },
                { value: '64' },
                { value: '128' },
                { value: '256' }
              ])
                .selected(1)
                .onSelect((index: number) => {
                  const sizes = [32, 64, 128, 256];
                  this.newVMDiskSize = sizes[index];
                })
                .layoutWeight(1);
            }
            .width('100%')
            .margin({ bottom: 20 });

            Row() {
              Text('内存大小')
                .fontSize(14)
                .fontColor('#666666')
                .width(80);

              Select([
                { value: '2048' },
                { value: '4096' },
                { value: '6144' },
                { value: '8192' }
              ])
                .selected(2)
                .onSelect((index: number) => {
                  const memories = [2048, 4096, 6144, 8192];
                  this.newVMMemory = memories[index];
                })
                .layoutWeight(1);
            }
            .width('100%')
            .margin({ bottom: 20 });

            Row() {
              Text('CPU核心')
                .fontSize(14)
                .fontColor('#666666')
                .width(80);

              Select([
                { value: '1' },
                { value: '2' },
                { value: '4' },
                { value: '8' }
              ])
                .selected(2)
                .onSelect((index: number) => {
                  const cpus = [1, 2, 4, 8];
                  this.newVMCPU = cpus[index];
                })
                .layoutWeight(1);
            }
            .width('100%')
            .margin({ bottom: 32 });

            Row() {
              Button('取消')
                .width(120)
                .height(44)
                .backgroundColor('#F5F5F5')
                .fontColor('#666666')
                .fontSize(16)
                .borderRadius(22)
                .onClick(() => {
                  this.showCreateDialog = false;
                  this.resetCreateForm();
                });

              Button('创建')
                .width(120)
                .height(44)
                .backgroundColor('#007DFF')
                .fontColor(Color.White)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .borderRadius(22)
                .margin({ left: 16 })
                .onClick(() => {
                  this.createVM();
                })
                .enabled(!this.isLoading);
            }
            .width('100%')
            .justifyContent(FlexAlign.Center);
          }
          .padding(24)
          .backgroundColor(Color.White)
          .borderRadius(20)
          .width('90%');
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.6)')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
      }
    }
    .width('100%')
    .height('100%');
  }
}
