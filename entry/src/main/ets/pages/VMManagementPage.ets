// @ts-nocheck
import { VMListPanel, VMListItem } from '../components/VMListPanel.ets'
import { EmptyState } from '../components/EmptyState.ets'

/**
 * 新虚拟机管理页面：左侧列表面板 + 右侧内容区
 * 先使用示例数据，后续可接入 QemuVMManager
 */

@Entry
@Component
export struct VMManagementPage {
  @State vmList: VMListItem[] = [
    { id: '1', name: 'Windows 11 ARM', os: 'Windows 11', status: 'stopped', isStarred: true },
    { id: '2', name: 'Ubuntu 24.04', os: 'Ubuntu', status: 'running', isStarred: false }
  ]
  @State selectedId: string = ''

  build() {
    Row() {
      // 左侧列表面板
      VMListPanel({
        onVMSelect: (id: string) => {
          this.selectedId = id
        },
        onCreateVM: () => {
          // TODO: 打开创建虚拟机对话框
          console.info('打开创建虚拟机对话框')
        }
      })
      .bindThis(this)
      .bind("vmList", () => this.vmList)

      // 右侧内容区
      if (!this.selectedId) {
        EmptyState({
          title: '还没有选中的虚拟机',
          subtitle: '请选择左侧列表中的虚拟机，或点击右下角创建',
          onActionClick: () => {
            console.info('去创建虚拟机')
          }
        })
        .layoutWeight(1)
      } else {
        Column() {
          Text(`已选择: ${this.selectedId}`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .padding(20)
            .width('100%')
          // TODO: 这里后续替换为虚拟机概览信息组件
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