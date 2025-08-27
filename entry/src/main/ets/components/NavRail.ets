/**
 * 左侧导航 Rail 组件
 * 三项：虚拟机 / Apps / 我的
 */

export interface NavItem {
  id: string
  icon: string  // 图标字符或路径
  label: string
  isActive: boolean
}

@Component
export struct NavRail {
  @State navItems: NavItem[] = [
    { id: 'vms', icon: '💻', label: '虚拟机', isActive: true },
    { id: 'apps', icon: '📱', label: 'Apps', isActive: false },
    { id: 'mine', icon: '👤', label: '我的', isActive: false }
  ]
  
  onNavItemClick?: (itemId: string) => void

  build() {
    Column() {
      ForEach(this.navItems, (item: NavItem) => {
        Column() {
          // 图标
          Text(item.icon)
            .fontSize(20)
            .fontColor(item.isActive ? '#007AFF' : '#8E8E93')
            .margin({ bottom: 4 })
          
          // 文字标签
          Text(item.label)
            .fontSize(12)
            .fontColor(item.isActive ? '#007AFF' : '#8E8E93')
            .fontWeight(item.isActive ? FontWeight.Medium : FontWeight.Normal)
        }
        .width(64)
        .height(64)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(item.isActive ? 'rgba(0, 122, 255, 0.1)' : 'transparent')
        .borderRadius(12)
        .margin({ bottom: 8 })
        .onClick(() => {
          // 更新选中状态
          this.navItems.forEach(navItem => {
            navItem.isActive = navItem.id === item.id
          })
          
          // 回调通知父组件
          if (this.onNavItemClick) {
            this.onNavItemClick(item.id)
          }
        })
      })
    }
    .width(72)
    .height('100%')
    .backgroundColor('#F2F2F7')
    .padding({ top: 16, bottom: 16 })
    .justifyContent(FlexAlign.Start)
  }
}