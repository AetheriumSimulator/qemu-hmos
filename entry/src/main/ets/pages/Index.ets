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

  @Builder
  buildSidebarItem(label: string, icon: Resource, idx: number) {
    // 紧凑的图标+下方文字，减少纵向间距，弱化对主题色依赖，自动适配深/浅色
    Column() {
      Image(icon)
        .width(22)
        .height(22)
      Text(label)
        .fontSize(10)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .margin({ top: 2 })
    }
    .width('100%')
    .height(44)
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .borderRadius(10)
    .backgroundColor(this.currentIndex === idx ? 'rgba(26,115,232,0.12)' : 'transparent')
    .margin({ bottom: 2 })
    .alignItems(HorizontalAlign.Center)
    .onClick(() => this.currentIndex = idx)
  }

  build() {
    if (this.isWide) {
      // 左窄栏（紧凑图标列），右内容区
      Row() {
        // 左侧导航（紧凑）
        Column() {
          this.buildSidebarItem('虚拟机', $r('app.media.vm_tab'), 0)
          this.buildSidebarItem('应用',   $r('app.media.apps_tab'), 1)
          this.buildSidebarItem('我的',   $r('app.media.mine_tab'), 2)
        }
        .width(72)
        .padding({ top: 8, bottom: 8, left: 4, right: 4 })
        .height('100%')
        .alignItems(HorizontalAlign.Center)

        // 右侧内容区
        Column() {
          if (this.currentIndex === 0) { VMsPage() }
          if (this.currentIndex === 1) { AppsPage() }
          if (this.currentIndex === 2) { MinePage() }
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      // 不强制背景色，跟随系统深/浅模式
    } else {
      // 窄屏：保留底部Tabs
      Tabs({ index: this.currentIndex, barPosition: BarPosition.End, controller: this.tabsController }) {
        TabContent() { VMsPage() }
        .tabBar({ icon: $r('app.media.vm_tab'), text: '虚拟机' })

        TabContent() { AppsPage() }
        .tabBar({ icon: $r('app.media.apps_tab'), text: '应用' })

        TabContent() { MinePage() }
        .tabBar({ icon: $r('app.media.mine_tab'), text: '我的' })
      }
      .onChange((index: number) => this.currentIndex = index)
      .width('100%')
      .height('100%')
    }
  }
}
