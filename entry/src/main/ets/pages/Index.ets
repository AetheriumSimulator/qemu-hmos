import { VMsPage } from './VMs';
import { AppsPage } from './Apps';
import { MinePage } from './Mine';
import display from '@ohos.display';

interface DisplayLike { width: number; densityDPI?: number }

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State isWide: boolean = false;
  private tabsController: TabsController = new TabsController();

  aboutToAppear() {
    try {
      const d: DisplayLike = display.getDefaultDisplaySync() as DisplayLike;
      let widthVp: number = d.width;
      if (d.densityDPI !== undefined && d.densityDPI > 0) {
        widthVp = Math.round(d.width * 160 / d.densityDPI);
      }
      this.isWide = widthVp >= 840;
    } catch (e) {
      this.isWide = false;
    }
  }

  private buildSidebarItem(label: string, icon: Resource, idx: number) {
    Row() {
      Image(icon).width(28).height(28).margin({ right: 12 })
      Text(label).fontSize(16)
        .fontWeight(this.currentIndex === idx ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.currentIndex === idx ? '#1a73e8' : '#1f1f1f')
    }
    .height(60)
    .width('100%')
    .padding({ left: 16, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.currentIndex === idx ? '#E8F0FE' : 'transparent')
    .margin({ bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.currentIndex = idx)
  }

  build() {
    if (this.isWide) {
      // 回退到稳定的自定义侧边栏（图标+文字），保证显示正常
      Row() {
        // 左侧导航
        Column() {
          this.buildSidebarItem('虚拟机', $r('app.media.vm_tab'), 0)
          this.buildSidebarItem('应用',   $r('app.media.apps_tab'), 1)
          this.buildSidebarItem('我的',   $r('app.media.mine_tab'), 2)
        }
        .width(240)
        .padding({ top: 12, bottom: 12, left: 12, right: 12 })
        .backgroundColor('#FFFFFF')
        .height('100%')

        // 右侧内容区
        Column() {
          if (this.currentIndex === 0) { VMsPage() }
          if (this.currentIndex === 1) { AppsPage() }
          if (this.currentIndex === 2) { MinePage() }
        }
        .width('1fr')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F7F8FA')
    } else {
      // 窄屏：保留底部Tabs
      Tabs({ index: this.currentIndex, barPosition: BarPosition.End, controller: this.tabsController }) {
        TabContent() { VMsPage() }
        .tabBar({ icon: $r('app.media.vm_tab') })

        TabContent() { AppsPage() }
        .tabBar({ icon: $r('app.media.apps_tab') })

        TabContent() { MinePage() }
        .tabBar({ icon: $r('app.media.mine_tab') })
      }
      .onChange((index: number) => this.currentIndex = index)
      .width('100%')
      .height('100%')
    }
  }
}
