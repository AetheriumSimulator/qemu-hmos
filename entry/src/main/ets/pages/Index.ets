import display from '@ohos.display'
import ThemeManager from '../common/ThemeManager.ets'
import { MinePage } from './Mine.ets'
import { AppsPage } from './Apps.ets'
import { VMsPage } from './VMs.ets'
import qemu from 'libqemu_hmos.so'

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

@Entry
@Component
struct Index {
  @State currentIndex: number = 0
  @State isWide: boolean = false
  @State napiTestResult: string = ''
  private controller: TabsController = new TabsController()

  aboutToAppear() {
    let displayInfo = display.getDefaultDisplaySync()
    this.isWide = displayInfo.width > 600
  }

  private testNAPI() {
    try {
      const version = qemu.version;
      const jitEnabled = qemu.enableJit;
      const kvmSupported = qemu.kvmSupported;
      
      this.napiTestResult = `QEMU版本: ${version}\nJIT支持: ${jitEnabled}\nKVM支持: ${kvmSupported}`;
      
      // 测试启动VM
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
      const startResult = qemu.startVm(configJson);
      
      this.napiTestResult += `\n启动结果: ${startResult}`;
      
      if (startResult === true) {
        setTimeout(() => {
          const stopResult = qemu.stopVm('test-vm');
          this.napiTestResult += `\n停止结果: ${stopResult}`;
        }, 2000);
      }
      
    } catch (error) {
      this.napiTestResult = `NAPI测试出错: ${error}`;
    }
  }

  @Builder TabBuilder(title: string, targetIndex: number, selectedImg: string, normalImg: string) {
    Column() {
      Image(this.currentIndex === targetIndex ? selectedImg : normalImg)
        .size({ width: 25, height: 25 })
      Text(title)
        .fontColor(this.currentIndex === targetIndex ? '#1698CE' : '#6B6B6B')
    }
    .width('100%')
    .height(50)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.currentIndex = targetIndex
      this.controller.changeIndex(this.currentIndex)
    })
  }

  build() {
    Column() {
      // NAPI测试区域
      Row() {
        Button('测试NAPI')
          .onClick(() => {
            this.testNAPI();
          })
          .margin({ right: 10 })
        
        Text(this.napiTestResult)
          .fontSize(12)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#f0f0f0')
      
      Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
        TabContent() {
          VMsPage()
        }.tabBar(this.TabBuilder('虚拟机', 0, 'app.media.ic_public_contacts_filled', 'app.media.ic_public_contacts'))

        TabContent() {
          AppsPage()
        }.tabBar(this.TabBuilder('应用', 1, 'app.media.ic_public_app_filled', 'app.media.ic_public_app'))

        TabContent() {
          MinePage()
        }.tabBar(this.TabBuilder('我的', 2, 'app.media.ic_public_contacts_filled', 'app.media.ic_public_contacts'))
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barWidth(360)
      .barHeight(56)
      .animationDuration(400)
      .onChange((index: number) => {
        this.currentIndex = index
      })
      .width('90%')
      .backgroundColor('#F1F3F5')
    }
    .width('100%')
    .height('100%')
  }
}
