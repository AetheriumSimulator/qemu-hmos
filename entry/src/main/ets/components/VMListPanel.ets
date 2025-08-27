/**
 * 虚拟机列表面板组件
 */

import { VMConfig } from './VMCreateDialog'

export interface VMListItem {
  id: string
  name: string
  os: string
  status: 'running' | 'stopped' | 'paused' | 'error'
  isStarred: boolean
}

@Component
export struct VMListPanel {
  @State vmList: VMListItem[] = []
  @State searchText: string = ''
  @State selectedVMId: string = ''
  
  onVMSelect?: (vmId: string) => void
  onCreateVM?: () => void

  build() {
    Column() {
      // 顶部工具区
      Column() {
        Row() {
          // 汉堡菜单按钮
          Text('☰')
            .fontSize(16)
            .fontColor('#8E8E93')
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
            .onClick(() => {
              console.info('汉堡菜单点击')
            })
          
          Blank()
          
          // 右侧占位图标
          Text('⋯')
            .fontSize(16)
            .fontColor('#8E8E93')
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
            .onClick(() => {
              console.info('更多选项点击')
            })
        }
        .width('100%')
        .margin({ bottom: 12 })
        
        // 搜索框
        TextInput({ placeholder: '搜索虚拟机的名字' })
          .width('100%')
          .height(40)
          .borderRadius(20)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E5E5EA' })
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => {
            this.searchText = value
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16 })
      .backgroundColor('#F2F2F7')
      
      // 虚拟机列表
      List() {
        ForEach(this.getFilteredVMs(), (vm: VMListItem) => {
          ListItem() {
            Row() {
              // 左侧收藏星标
              Text(vm.isStarred ? '⭐' : '☆')
                .fontSize(16)
                .fontColor(vm.isStarred ? '#007AFF' : '#C7C7CC')
                .margin({ right: 12 })
                .onClick(() => {
                  vm.isStarred = !vm.isStarred
                })
              
              // 虚拟机名称
              Column() {
                Text(vm.name)
                  .fontSize(16)
                  .fontColor('#000000')
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                
                Text(`${vm.os} • ${this.getStatusText(vm.status)}`)
                  .fontSize(12)
                  .fontColor('#8E8E93')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              
              // 状态指示器
              Circle({ width: 8, height: 8 })
                .fill(this.getStatusColor(vm.status))
            }
            .width('100%')
            .height(52)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.selectedVMId === vm.id ? '#EAF2FF' : '#FFFFFF')
            .borderRadius(12)
            .onClick(() => {
              this.selectedVMId = vm.id
              if (this.onVMSelect) {
                this.onVMSelect(vm.id)
              }
            })
          }
          .margin({ bottom: 8 })
        })
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#F2F2F7')
      
      // 右下角创建按钮 (悬浮)
      Stack() {
        Button('新建虚拟机')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#007AFF')
          .borderRadius(12)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .onClick(() => {
            if (this.onCreateVM) {
              this.onCreateVM()
            }
          })
      }
      .width('100%')
      .height(60)
      .alignContent(Alignment.BottomEnd)
      .padding({ right: 16, bottom: 16 })
    }
    .width(320)
    .height('100%')
    .backgroundColor('#F2F2F7')
  }
  
  private getFilteredVMs(): VMListItem[] {
    if (!this.searchText) {
      return this.vmList
    }
    return this.vmList.filter(vm => 
      vm.name.toLowerCase().includes(this.searchText.toLowerCase())
    )
  }
  
  private getStatusText(status: string): string {
    switch (status) {
      case 'running': return '运行中'
      case 'stopped': return '已停止'
      case 'paused': return '已暂停'
      case 'error': return '错误'
      default: return '未知'
    }
  }
  
  private getStatusColor(status: string): string {
    switch (status) {
      case 'running': return '#34C759'
      case 'stopped': return '#8E8E93'
      case 'paused': return '#FF9500'
      case 'error': return '#FF3B30'
      default: return '#8E8E93'
    }
  }
  
  // 公共方法：更新虚拟机列表
  updateVMList(vms: VMListItem[]) {
    this.vmList = vms
  }
  
  // 公共方法：设置选中项
  setSelectedVM(vmId: string) {
    this.selectedVMId = vmId
  }
}