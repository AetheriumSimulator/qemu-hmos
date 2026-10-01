// @ts-nocheck
import { VMListPanel, VMListItem } from '../components/VMListPanel'
import { EmptyState } from '../components/EmptyState'
import promptAction from '@ohos.promptAction'
import router from '@ohos.router'
import qemu from 'qemu_hmos'

/**
 * 虚拟机概览信息组件
 */
@Component
struct VMOverviewPanel {
  @Prop vm: VMListItem
  @Prop onStart: () => void
  @Prop onStop: () => void
  @Prop onDelete: () => void
  @Prop onConnect: () => void

  build() {
    Scroll() {
      Column() {
        // 标题和状态
        Row() {
          Column() {
            Text(this.vm.name)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
            Text(this.vm.os)
              .fontSize(14)
              .fontColor('#666666')
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          // 状态指示器
          Row() {
            Circle()
              .width(12)
              .height(12)
              .fill(this.getStatusColor())
            Text(this.getStatusText())
              .fontSize(14)
              .fontColor(this.getStatusColor())
              .margin({ left: 6 })
          }
          .padding({ horizontal: 12, vertical: 6 })
          .backgroundColor(this.getStatusColor() + '20')
          .borderRadius(16)
        }
        .width('100%')
        .padding(20)

        Divider().color('#E0E0E0')

        // 操作按钮
        Row() {
          if (this.vm.status === 'stopped') {
            Button('启动')
              .type(ButtonType.Normal)
              .backgroundColor('#4CAF50')
              .fontColor(Color.White)
              .borderRadius(8)
              .onClick(() => this.onStart?.())
          } else if (this.vm.status === 'running') {
            Button('停止')
              .type(ButtonType.Normal)
              .backgroundColor('#f44336')
              .fontColor(Color.White)
              .borderRadius(8)
              .onClick(() => this.onStop?.())

            Button('连接')
              .type(ButtonType.Normal)
              .backgroundColor('#2196F3')
              .fontColor(Color.White)
              .borderRadius(8)
              .margin({ left: 12 })
              .onClick(() => this.onConnect?.())
          }

          Blank()

          Button('删除')
            .type(ButtonType.Normal)
            .backgroundColor('#FF5722')
            .fontColor(Color.White)
            .borderRadius(8)
            .onClick(() => this.onDelete?.())
        }
        .width('100%')
        .padding(20)

        Divider().color('#E0E0E0')

        // 虚拟机信息
        Column() {
          Text('虚拟机信息')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .margin({ bottom: 16 })

          this.InfoRow('ID', this.vm.id)
          this.InfoRow('操作系统', this.vm.os)
          this.InfoRow('状态', this.getStatusText())
          this.InfoRow('收藏', this.vm.isStarred ? '是' : '否')
        }
        .width('100%')
        .padding(20)
        .alignItems(HorizontalAlign.Start)

        Divider().color('#E0E0E0')

        // Windows 11 兼容性检查（如果是 Windows VM）
        if (this.vm.os.includes('Windows')) {
          Column() {
            Text('Windows 11 兼容性')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 16 })

            this.CompatibilityRow('TPM 2.0', qemu.isTpmAvailable?.(this.vm.name) ?? true)
            this.CompatibilityRow('UEFI 固件', qemu.isUefiAvailable?.() ?? true)
            this.CompatibilityRow('Secure Boot', true) // 默认支持
          }
          .width('100%')
          .padding(20)
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#666666')
        .width(100)
      Text(value)
        .fontSize(14)
        .fontColor('#333333')
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  @Builder
  CompatibilityRow(feature: string, available: boolean) {
    Row() {
      Text(feature)
        .fontSize(14)
        .fontColor('#666666')
        .width(120)
      Row() {
        Image(available ? $r('app.media.ic_check') : $r('app.media.ic_close'))
          .width(16)
          .height(16)
        Text(available ? '可用' : '不可用')
          .fontSize(14)
          .fontColor(available ? '#4CAF50' : '#f44336')
          .margin({ left: 4 })
      }
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  private getStatusColor(): string {
    switch (this.vm.status) {
      case 'running':
        return '#4CAF50'
      case 'stopped':
        return '#9E9E9E'
      case 'starting':
      case 'stopping':
        return '#FF9800'
      default:
        return '#9E9E9E'
    }
  }

  private getStatusText(): string {
    switch (this.vm.status) {
      case 'running':
        return '运行中'
      case 'stopped':
        return '已停止'
      case 'starting':
        return '启动中'
      case 'stopping':
        return '停止中'
      default:
        return '未知'
    }
  }
}

/**
 * 创建虚拟机对话框
 */
@CustomDialog
struct VMCreateDialog {
  controller: CustomDialogController
  onConfirm: (name: string, os: string, memory: number, disk: number) => void = () => {}

  @State vmName: string = ''
  @State selectedOS: string = 'Windows 11 ARM'
  @State memory: number = 4096
  @State diskSize: number = 64

  private osOptions: string[] = [
    'Windows 11 ARM',
    'Windows 10 ARM',
    'Ubuntu 24.04',
    'Debian 12',
    '其他 Linux'
  ]

  build() {
    Column() {
      Text('创建新虚拟机')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      // 虚拟机名称
      Column() {
        Text('虚拟机名称')
          .fontSize(14)
          .fontColor('#666666')
          .margin({ bottom: 8 })
        TextInput({ placeholder: '请输入虚拟机名称', text: this.vmName })
          .onChange((value: string) => { this.vmName = value })
          .width('100%')
          .height(44)
      }
      .width('100%')
      .margin({ bottom: 16 })
      .alignItems(HorizontalAlign.Start)

      // 操作系统
      Column() {
        Text('操作系统')
          .fontSize(14)
          .fontColor('#666666')
          .margin({ bottom: 8 })
        Select(this.osOptions.map(os => ({ value: os })))
          .selected(0)
          .value(this.selectedOS)
          .onSelect((index: number) => {
            this.selectedOS = this.osOptions[index]
          })
          .width('100%')
      }
      .width('100%')
      .margin({ bottom: 16 })
      .alignItems(HorizontalAlign.Start)

      // 内存大小
      Column() {
        Text(`内存: ${this.memory} MB`)
          .fontSize(14)
          .fontColor('#666666')
          .margin({ bottom: 8 })
        Slider({
          value: this.memory,
          min: 1024,
          max: 16384,
          step: 1024
        })
          .onChange((value: number) => { this.memory = value })
          .width('100%')
      }
      .width('100%')
      .margin({ bottom: 16 })
      .alignItems(HorizontalAlign.Start)

      // 磁盘大小
      Column() {
        Text(`磁盘: ${this.diskSize} GB`)
          .fontSize(14)
          .fontColor('#666666')
          .margin({ bottom: 8 })
        Slider({
          value: this.diskSize,
          min: 32,
          max: 256,
          step: 8
        })
          .onChange((value: number) => { this.diskSize = value })
          .width('100%')
      }
      .width('100%')
      .margin({ bottom: 24 })
      .alignItems(HorizontalAlign.Start)

      // 按钮
      Row() {
        Button('取消')
          .type(ButtonType.Normal)
          .backgroundColor('#E0E0E0')
          .fontColor('#333333')
          .borderRadius(8)
          .onClick(() => {
            this.controller.close()
          })

        Button('创建')
          .type(ButtonType.Normal)
          .backgroundColor('#2196F3')
          .fontColor(Color.White)
          .borderRadius(8)
          .margin({ left: 16 })
          .onClick(() => {
            if (this.vmName.trim().length === 0) {
              promptAction.showToast({ message: '请输入虚拟机名称' })
              return
            }
            this.onConfirm(this.vmName, this.selectedOS, this.memory, this.diskSize)
            this.controller.close()
          })
      }
      .justifyContent(FlexAlign.End)
      .width('100%')
    }
    .padding(24)
    .width(400)
  }
}

/**
 * 新虚拟机管理页面：左侧列表面板 + 右侧内容区
 */
@Entry
@Component
export struct VMManagementPage {
  @State vmList: VMListItem[] = [
    { id: '1', name: 'Windows 11 ARM', os: 'Windows 11', status: 'stopped', isStarred: true },
    { id: '2', name: 'Ubuntu 24.04', os: 'Ubuntu', status: 'running', isStarred: false }
  ]
  @State selectedId: string = ''
  @State isLoading: boolean = false

  private createDialogController: CustomDialogController = new CustomDialogController({
    builder: VMCreateDialog({
      onConfirm: (name: string, os: string, memory: number, disk: number) => {
        this.createVM(name, os, memory, disk)
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  })

  /**
   * 创建新虚拟机
   */
  private async createVM(name: string, os: string, memory: number, disk: number): Promise<void> {
    this.isLoading = true

    try {
      // 生成唯一 ID
      const id = `vm_${Date.now()}`

      // 如果是 Windows 11，设置 TPM 和 UEFI
      if (os.includes('Windows 11')) {
        await qemu.setupTpm?.(name)
        await qemu.setupUefi?.(name)
        await qemu.enableSecureBoot?.(name, true)
      }

      // 添加到列表
      const newVM: VMListItem = {
        id,
        name,
        os,
        status: 'stopped',
        isStarred: false
      }

      this.vmList = [...this.vmList, newVM]
      this.selectedId = id

      promptAction.showToast({ message: `虚拟机 "${name}" 创建成功` })
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error)
      promptAction.showToast({ message: `创建失败: ${errorMsg}` })
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 启动虚拟机
   */
  private async startVM(vm: VMListItem): Promise<void> {
    this.isLoading = true

    try {
      const success = qemu.startVm?.({
        name: vm.name,
        accel: qemu.kvmSupported?.() ? 'kvm' : 'tcg,thread=multi',
        display: 'vnc=127.0.0.1:1',
        nographic: false
      })

      if (success) {
        // 更新状态
        this.vmList = this.vmList.map(v =>
          v.id === vm.id ? { ...v, status: 'running' } : v
        )
        promptAction.showToast({ message: `虚拟机 "${vm.name}" 已启动` })
      } else {
        promptAction.showToast({ message: '启动失败' })
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error)
      promptAction.showToast({ message: `启动失败: ${errorMsg}` })
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 停止虚拟机
   */
  private async stopVM(vm: VMListItem): Promise<void> {
    this.isLoading = true

    try {
      const success = qemu.stopVm?.(vm.name)

      if (success) {
        // 更新状态
        this.vmList = this.vmList.map(v =>
          v.id === vm.id ? { ...v, status: 'stopped' } : v
        )
        promptAction.showToast({ message: `虚拟机 "${vm.name}" 已停止` })
      } else {
        promptAction.showToast({ message: '停止失败' })
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error)
      promptAction.showToast({ message: `停止失败: ${errorMsg}` })
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 删除虚拟机
   */
  private async deleteVM(vm: VMListItem): Promise<void> {
    if (vm.status === 'running') {
      promptAction.showToast({ message: '请先停止虚拟机' })
      return
    }

    // 确认对话框
    promptAction.showDialog({
      title: '确认删除',
      message: `确定要删除虚拟机 "${vm.name}" 吗？此操作不可撤销。`,
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '删除', color: '#f44336' }
      ]
    }).then(result => {
      if (result.index === 1) {
        // 从列表中移除
        this.vmList = this.vmList.filter(v => v.id !== vm.id)
        if (this.selectedId === vm.id) {
          this.selectedId = ''
        }
        promptAction.showToast({ message: `虚拟机 "${vm.name}" 已删除` })
      }
    })
  }

  /**
   * 连接到虚拟机
   */
  private connectToVM(vm: VMListItem): void {
    router.pushUrl({
      url: 'pages/VNCNativeViewer',
      params: {
        vmName: vm.name,
        vncHost: '127.0.0.1',
        vncPort: 5901
      }
    })
  }

  /**
   * 获取选中的虚拟机
   */
  private getSelectedVM(): VMListItem | undefined {
    return this.vmList.find(vm => vm.id === this.selectedId)
  }

  build() {
    Row() {
      // 左侧列表面板
      VMListPanel({
        onVMSelect: (id: string) => {
          this.selectedId = id
        },
        onCreateVM: () => {
          this.createDialogController.open()
        }
      })

      // 右侧内容区
      if (!this.selectedId) {
        EmptyState({
          title: '还没有选中的虚拟机',
          subtitle: '请选择左侧列表中的虚拟机，或点击右下角创建',
          onActionClick: () => {
            this.createDialogController.open()
          }
        })
        .layoutWeight(1)
      } else {
        Column() {
          if (this.isLoading) {
            Row() {
              LoadingProgress()
                .width(32)
                .height(32)
              Text('处理中...')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ left: 12 })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          } else {
            VMOverviewPanel({
              vm: this.getSelectedVM() as VMListItem,
              onStart: () => {
                const vm = this.getSelectedVM()
                if (vm) this.startVM(vm)
              },
              onStop: () => {
                const vm = this.getSelectedVM()
                if (vm) this.stopVM(vm)
              },
              onDelete: () => {
                const vm = this.getSelectedVM()
                if (vm) this.deleteVM(vm)
              },
              onConnect: () => {
                const vm = this.getSelectedVM()
                if (vm) this.connectToVM(vm)
              }
            })
          }
        }
        .width('100%')
        .height('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }
}
