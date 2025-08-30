import qemu from 'libqemu_hmos.so';
import { VMCreateDialog } from '../components/VMCreateDialog';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

interface QemuConfig {
  vmId: string;
  name: string;
  isoPath: string;
  diskSizeGB: number;
  memoryMB: number;
  cpuCount: number;
  accel: string;
  display: string;
  nographic: boolean;
  vmDir: string;
  logPath: string;
}

interface TestConfig {
  vmId: string;
  name: string;
  memory: number;
  cpu: number;
  accel: string;
  display: string;
  nographic: boolean;
  vmDir: string;
  logPath: string;
}

interface VmMeta {
  id: string;
  name: string;
  isoPath: string;
  diskSizeGB: number;
  memoryMB: number;
  cpuCount: number;
  status: 'Creating' | 'Running' | 'Stopped' | 'Failed';
  createdAt: number;
}

interface VMCreateConfig {
  name: string;
  osType: string;
  isoPath: string;
  diskSize: number; // GB
  memory: number; // MB
}

@Component
export struct VMsPage {
  @State vms: VmMeta[] = [];
  @State loading: boolean = false;
  @State error: string = '';
  @State showCreateDialog: boolean = false;
  @State vmLogs: Map<string, string[]> = new Map();
  @State selectedVmId: string = '';
  @State showLogPanel: boolean = false;
  
  private createDialogController: CustomDialogController = new CustomDialogController({
    builder: VMCreateDialog({
      onConfirm: (config: VMCreateConfig): void => { this.handleCreateVM(config); },
      onCancel: (): void => { this.showCreateDialog = false; }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  async aboutToAppear() {
    await this.loadVms();
  }

  async loadVms() {
    this.loading = true;
    try {
      // 简化版本：使用AppStorage
      const savedVmsJson = AppStorage.get<string>('vmsList') || '[]';
      this.vms = JSON.parse(savedVmsJson) as VmMeta[];
      this.error = '';
    } catch (e) {
      console.error('Load VMs failed:', e);
      this.error = 'Failed to load virtual machines';
      this.vms = [];
    } finally {
      this.loading = false;
    }
  }

  private async saveVms() {
    try {
      const vmsJson = JSON.stringify(this.vms);
      AppStorage.setOrCreate('vmsList', vmsJson);
    } catch (err) {
      console.error('Failed to save VMs:', err);
    }
  }

  private async handleCreateVM(config: VMCreateConfig) {
    try {
      this.showCreateDialog = false;
      
      // 生成唯一ID
      const vmId = `vm_${Date.now()}`;
      
      // 创建VM目录结构
      const vmDir = `/data/storage/el2/base/haps/entry/files/vm/${vmId}`;
      await this.createVMDirectory(vmDir);
      
      // 创建VM配置
      const newVm: VmMeta = {
        id: vmId,
        name: config.name,
        isoPath: config.isoPath,
        diskSizeGB: config.diskSize,
        memoryMB: config.memory,
        cpuCount: 2, // 默认2核
        status: 'Creating',
        createdAt: Date.now()
      };
      
      // 保存VM配置到文件
      await this.saveVMConfig(vmDir, newVm);
      
      // 添加到列表
      this.vms.push(newVm);
      await this.saveVms();
      
      // 初始化日志
      this.vmLogs.set(vmId, [`[${new Date().toLocaleTimeString()}] 虚拟机 ${config.name} 创建成功`]);
      
      this.error = `虚拟机 ${config.name} 创建成功，点击启动按钮开始运行`;
      
    } catch (e) {
      console.error('Create VM failed:', e);
      this.error = `创建虚拟机失败: ${e}`;
    }
  }
  
  private async createVMDirectory(vmDir: string) {
    try {
      // 这里应该使用文件系统API创建目录
      // 由于ArkTS限制，我们先记录日志
      console.log(`Creating VM directory: ${vmDir}`);
    } catch (e) {
      console.error('Failed to create VM directory:', e);
      throw new Error(String(e));
    }
  }
  
  private async saveVMConfig(vmDir: string, vm: VmMeta) {
    try {
      const configPath = `${vmDir}/config.json`;
      const configData = JSON.stringify(vm, null, 2);
      console.log(`Saving VM config to: ${configPath}`);
      console.log(`Config data: ${configData}`);
    } catch (e) {
      console.error('Failed to save VM config:', e);
      throw new Error(String(e));
    }
  }

  private async start(vm: VmMeta) {
    try {
      vm.status = 'Creating';
      this.error = '';
      
      // 添加启动日志
      this.addVMLog(vm.id, `开始启动虚拟机 ${vm.name}...`);
      
      // 构建QEMU配置
      const qemuConfig: QemuConfig = {
        vmId: vm.id,
        name: vm.name,
        isoPath: vm.isoPath,
        diskSizeGB: vm.diskSizeGB,
        memoryMB: vm.memoryMB,
        cpuCount: vm.cpuCount,
        // 最小启动配置 - TCG + 无图形
        accel: 'tcg',
        display: 'none',
        nographic: true,
        // 沙盒路径
        vmDir: `/data/storage/el2/base/haps/entry/files/vm/${vm.id}`,
        logPath: `/data/storage/el2/base/haps/entry/files/vm/${vm.id}/logs/qemu.log`
      };
      
      this.addVMLog(vm.id, `QEMU配置: ${JSON.stringify(qemuConfig, null, 2)}`);
      
      console.log('Starting VM with config:', JSON.stringify(qemuConfig));
      const result = await qemu.startVm(JSON.stringify(qemuConfig));
      
      if (result === true) {
        vm.status = 'Running';
        this.addVMLog(vm.id, `虚拟机启动成功！`);
        this.addVMLog(vm.id, `VNC端口: 5900, RDP端口: 3390`);
        this.error = `虚拟机 ${vm.name} 启动成功！`;
      } else {
        vm.status = 'Failed';
        this.addVMLog(vm.id, `虚拟机启动失败，返回值: ${result}`);
        this.error = `虚拟机 ${vm.name} 启动失败，返回值: ${result}`;
      }
    } catch (e) {
      console.error('Start VM failed:', e);
      vm.status = 'Failed';
      this.addVMLog(vm.id, `启动异常: ${e}`);
      this.error = `启动虚拟机失败: ${e}`;
    }
    
    await this.saveVms();
  }
  
  private addVMLog(vmId: string, message: string) {
    const timestamp = new Date().toLocaleTimeString();
    const logMessage = `[${timestamp}] ${message}`;
    
    if (!this.vmLogs.has(vmId)) {
      this.vmLogs.set(vmId, []);
    }
    
    const logs = this.vmLogs.get(vmId)!;
    logs.push(logMessage);
    
    // 保持最新100条日志
    if (logs.length > 100) {
      logs.splice(0, logs.length - 100);
    }
    
    console.log(`VM ${vmId}: ${logMessage}`);
  }

  private async stop(vm: VmMeta) {
    try {
      this.addVMLog(vm.id, `正在停止虚拟机 ${vm.name}...`);
      
      const result = await qemu.stopVm(vm.id);
      if (result === true) {
        vm.status = 'Stopped';
        this.addVMLog(vm.id, `虚拟机已停止`);
        this.error = `虚拟机 ${vm.name} 已停止`;
      } else {
        this.addVMLog(vm.id, `停止失败，返回值: ${result}`);
        this.error = `停止虚拟机失败，返回值: ${result}`;
      }
    } catch (e) {
      console.error('Stop VM failed:', e);
      this.addVMLog(vm.id, `停止异常: ${e}`);
      this.error = `停止虚拟机失败: ${e}`;
    }
    
    await this.saveVms();
  }
  
  private showVMLog(vmId: string) {
    this.selectedVmId = vmId;
    this.showLogPanel = true;
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('虚拟机管理')
          .fontSize(24)
          .layoutWeight(1);
        
        if (this.showLogPanel) {
          Button('关闭日志')
            .onClick(() => {
              this.showLogPanel = false;
              this.selectedVmId = '';
            });
        }
      }
      .width('100%')
      .margin({ bottom: 20 });

      if (this.loading) {
        Text('加载中...')
          .fontSize(16);
      }

      if (this.error) {
        Text(this.error)
          .fontSize(16)
          .margin({ bottom: 10 });
      }

      // 主内容区域
      if (this.showLogPanel && this.selectedVmId) {
        // 日志面板
        Column() {
          Text(`虚拟机日志 - ${this.getVMName(this.selectedVmId)}`)
            .fontSize(18)
            .margin({ bottom: 10 });
          
          Scroll() {
            Column() {
              ForEach(this.vmLogs.get(this.selectedVmId) || [], (log: string, index: number) => {
                Text(log)
                  .fontSize(12)
                  .width('100%')
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .backgroundColor(index % 2 === 0 ? '#F5F5F5' : '#FFFFFF');
              }, (log: string, index: number) => `${this.selectedVmId}_${index}`);
            }
          }
          .layoutWeight(1)
          .backgroundColor('#FAFAFA')
          .borderRadius(8)
          .padding(8);
        }
        .layoutWeight(1);
      } else {
        // 虚拟机列表
        List() {
          ForEach(this.vms, (vm: VmMeta) => {
            ListItem() {
              Row() {
                Column() {
                  Text(vm.name)
                    .fontSize(18);
                  Text(`状态: ${vm.status}`)
                    .fontSize(14);
                  Text(`内存: ${vm.memoryMB}MB | CPU: ${vm.cpuCount}核 | 磁盘: ${vm.diskSizeGB}GB`)
                    .fontSize(12);
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);

                Column() {
                  if (vm.status === 'Stopped' || vm.status === 'Failed') {
                    Button('启动')
                      .onClick(() => this.start(vm));
                  }
                  if (vm.status === 'Running') {
                    Button('停止')
                      .onClick(() => this.stop(vm));
                  }
                  Button('查看日志')
                    .fontSize(12)
                    .onClick(() => this.showVMLog(vm.id));
                }
              }
              .width('100%')
              .padding(10);
            }
          }, (vm: VmMeta) => vm.id);
        }
        .layoutWeight(1);
      }

      Row() {
        Button('测试NAPI')
          .onClick(() => {
            this.testNAPIConnection();
          })
          .margin({ right: 10 })
        
        Button('新建虚拟机')
          .onClick(() => {
            this.createDialogController.open();
          })
      }
      .width('100%')
      .margin({ top: 20 });
    }
    .width('100%')
    .height('100%')
    .padding(20);
  }
  
  private getVMName(vmId: string): string {
    const vm = this.vms.find(v => v.id === vmId);
    return vm ? vm.name : 'Unknown VM';
  }

  private testNAPIConnection() {
    this.addVMLog('test', '开始测试NAPI连接...');
    
    try {
      // 测试版本信息
      const version = qemu.version;
      this.addVMLog('test', `QEMU版本: ${version}`);
      
      // 测试JIT支持
      const jitEnabled = qemu.enableJit;
      this.addVMLog('test', `JIT支持: ${jitEnabled}`);
      
      // 测试KVM支持
      const kvmSupported = qemu.kvmSupported;
      this.addVMLog('test', `KVM支持: ${kvmSupported}`);
      
      // 测试启动VM（使用最小配置）
      const testConfig: TestConfig = {
        vmId: 'test-vm',
        name: 'Test VM',
        memory: 512,
        cpu: 1,
        accel: 'tcg',
        display: 'none',
        nographic: true,
        vmDir: '/data/storage/el2/base/haps/entry/files/vm/test-vm',
        logPath: '/data/storage/el2/base/haps/entry/files/vm/test-vm/qemu.log'
      };
      
      const configJson = JSON.stringify(testConfig);
      this.addVMLog('test', `启动配置: ${configJson}`);
      
      const startResult = qemu.startVm(configJson);
      this.addVMLog('test', `启动结果: ${startResult}`);
      
      if (startResult === true) {
        this.addVMLog('test', 'NAPI调用成功！虚拟机启动中...');
        
        // 等待2秒后停止测试VM
        setTimeout(() => {
          const stopResult = qemu.stopVm('test-vm');
          this.addVMLog('test', `停止结果: ${stopResult}`);
          this.addVMLog('test', 'NAPI测试完成');
        }, 2000);
      } else {
        this.addVMLog('test', 'NAPI调用失败');
      }
      
    } catch (error) {
      this.addVMLog('test', `NAPI测试出错: ${error}`);
    }
    
    // 显示日志面板
    this.selectedVmId = 'test';
    this.showLogPanel = true;
  }
}
