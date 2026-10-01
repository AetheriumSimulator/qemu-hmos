import hilog from '@ohos.hilog';
import { OneDriveManager, type OfficeApp, type OneDriveConfig } from '../utils/OneDriveManager';
import { NetworkManager } from '../utils/NetworkManager';

@Entry
@Component
struct OfficeApps {
  @State officeApps: OfficeApp[] = [];
  @State oneDriveConfig: OneDriveConfig | null = null;
  @State isLoading: boolean = false;
  @State errorMessage: string = '';
  @State selectedVM: string = '';
  @State showConfigDialog: boolean = false;
  @State networkDiagnostics: string[] = [];

  private oneDriveManager: OneDriveManager = OneDriveManager.getInstance();
  private networkManager: NetworkManager = NetworkManager.getInstance();

  aboutToAppear() {
    this.loadOfficeApps();
    this.loadOneDriveConfig();
    this.loadNetworkDiagnostics();
  }

  /**
   * 加载 Office 应用列表
   */
  private loadOfficeApps() {
    this.officeApps = this.oneDriveManager.getOfficeApps();
  }

  /**
   * 加载 OneDrive 配置
   */
  private loadOneDriveConfig() {
    this.oneDriveConfig = this.oneDriveManager.getConfig();
  }

  /**
   * 加载网络诊断信息
   */
  private loadNetworkDiagnostics() {
    this.networkDiagnostics = this.networkManager.getNetworkDiagnostics();
  }

  /**
   * 启动 Office 应用
   */
  private async startOfficeApp(app: OfficeApp) {
    if (!this.selectedVM) {
      this.errorMessage = '请先选择虚拟机';
      return;
    }

    try {
      this.isLoading = true;
      this.errorMessage = '';

      const success = await this.oneDriveManager.startOfficeApp(this.selectedVM, app.name);
      
      if (success) {
        hilog.info(0x0000, 'OFFICE_APP', '启动 %{public}s 成功', app.displayName);
      } else {
        this.errorMessage = `启动 ${app.displayName} 失败`;
      }
    } catch (error) {
      this.errorMessage = `启动失败: ${error}`;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 安装 Office 套件
   */
  private async installOffice() {
    if (!this.selectedVM) {
      this.errorMessage = '请先选择虚拟机';
      return;
    }

    try {
      this.isLoading = true;
      this.errorMessage = '';

      const success = await this.oneDriveManager.installOfficeInGuest(this.selectedVM);
      
      if (success) {
        hilog.info(0x0000, 'OFFICE_INSTALL', 'Office 安装成功');
        this.errorMessage = ''; // 清除错误信息
      } else {
        this.errorMessage = 'Office 安装失败';
      }
    } catch (error) {
      this.errorMessage = `安装失败: ${error}`;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 检查 OneDrive 状态
   */
  private async checkOneDriveStatus() {
    if (!this.selectedVM) {
      this.errorMessage = '请先选择虚拟机';
      return;
    }

    try {
      this.isLoading = true;
      this.errorMessage = '';

      const status = await this.oneDriveManager.checkOneDriveStatus(this.selectedVM);
      
      switch (status) {
        case 'connected':
          this.errorMessage = 'OneDrive 已连接';
          break;
        case 'disconnected':
          this.errorMessage = 'OneDrive 未连接';
          break;
        case 'error':
          this.errorMessage = 'OneDrive 连接错误';
          break;
      }
    } catch (error) {
      this.errorMessage = `状态检查失败: ${error}`;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 获取应用图标
   */
  private getAppIcon(app: OfficeApp): string {
    // 这里应该返回实际的图标路径
    return 'app_icon.png';
  }

  /**
   * 获取应用颜色
   */
  private getAppColor(app: OfficeApp): string {
    const colors: Record<string, string> = {
      'word': '#2B579A',
      'excel': '#217346',
      'powerpoint': '#D24726',
      'outlook': '#0078D4',
      'teams': '#6264A7',
      'onedrive': '#0078D4'
    };
    return colors[app.name] || '#666666';
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('Microsoft 365 集成')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1);

        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ic_settings'))
            .width(20)
            .height(20)
        }
        .width(40)
        .height(40)
        .backgroundColor('#F5F5F5')
        .onClick(() => {
          this.showConfigDialog = true;
        });
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 20 });

      // 虚拟机选择
      Row() {
        Text('选择虚拟机:')
          .fontSize(16)
          .fontColor('#666666')
          .margin({ right: 12 });

        Select([
          { value: 'Win11-ARM' },
          { value: 'Win11-x64' },
          { value: 'Ubuntu-ARM' }
        ])
          .selected(0)
          .onSelect((index: number) => {
            const vms = ['Win11-ARM', 'Win11-x64', 'Ubuntu-ARM'];
            this.selectedVM = vms[index];
          })
          .layoutWeight(1);
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 20 });

      // 状态信息
      if (this.oneDriveConfig) {
        Row() {
          Text(`集成档位: ${this.oneDriveConfig.tier}`)
            .fontSize(14)
            .fontColor('#666666')
            .margin({ right: 16 });

          Text(`状态: ${this.oneDriveConfig.enabled ? '已启用' : '未启用'}`)
            .fontSize(14)
            .fontColor(this.oneDriveConfig.enabled ? '#00C853' : '#FF5722');
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 20 });
      }

      // 操作按钮
      Row() {
        Button('安装 Office')
          .backgroundColor('#0078D4')
          .fontColor(Color.White)
          .borderRadius(8)
          .onClick(() => this.installOffice())
          .layoutWeight(1)
          .margin({ right: 8 });

        Button('检查状态')
          .backgroundColor('#F5F5F5')
          .fontColor('#666666')
          .borderRadius(8)
          .onClick(() => this.checkOneDriveStatus())
          .layoutWeight(1)
          .margin({ left: 8 });
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 20 });

      // Office 应用网格
      Grid() {
        ForEach(this.officeApps, (app: OfficeApp) => {
          GridItem() {
            Column() {
              // 应用图标
              Circle({ width: 60, height: 60 })
                .fill(this.getAppColor(app))
                .margin({ bottom: 12 });

              // 应用名称
              Text(app.displayName)
                .fontSize(14)
                .fontColor('#1A1A1A')
                .textAlign(TextAlign.Center)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ bottom: 8 });

              // 启动按钮
              Button('启动')
                .width('100%')
                .height(32)
                .fontSize(12)
                .backgroundColor(this.getAppColor(app))
                .fontColor(Color.White)
                .borderRadius(16)
                .onClick(() => this.startOfficeApp(app));
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .shadow({
              radius: 8,
              color: '#1A000000',
              offsetX: 0,
              offsetY: 2
            });
          }
        });
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsGap(16)
      .columnsGap(16)
      .width('100%')
      .padding({ left: 20, right: 20 });

      // 网络诊断信息
      if (this.networkDiagnostics.length > 0) {
        Column() {
          Text('网络诊断')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .margin({ bottom: 12 });

          ForEach(this.networkDiagnostics, (diagnostic: string) => {
            Text(diagnostic)
              .fontSize(14)
              .fontColor('#666666')
              .margin({ bottom: 4 });
          });
        }
        .width('100%')
        .padding(20)
        .backgroundColor('#F8F9FA')
        .borderRadius(12)
        .margin({ top: 20, left: 20, right: 20 });
      }

      // 错误信息
      if (this.errorMessage) {
        Text(this.errorMessage)
          .fontSize(14)
          .fontColor('#FF5722')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding(16)
          .backgroundColor('#FFEBEE')
          .borderRadius(8)
          .margin({ top: 20, left: 20, right: 20 });
      }

      // 加载指示器
      if (this.isLoading) {
        Row() {
          LoadingProgress()
            .width(20)
            .height(20)
            .margin({ right: 8 });

          Text('处理中...')
            .fontSize(14)
            .fontColor('#666666');
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .padding(20);
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5');

    // 配置对话框
    if (this.showConfigDialog) {
      this.buildConfigDialog();
    }
  }

  @Builder
  buildConfigDialog() {
    Column() {
      Column() {
        Row() {
          Text('OneDrive 配置')
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
            this.showConfigDialog = false;
          });
        }
        .width('100%')
        .margin({ bottom: 24 });

        // 集成档位选择
        Row() {
          Text('集成档位:')
            .fontSize(16)
            .fontColor('#666666')
            .width(100);

          Select([
            { value: '档位1: 来宾内安装' },
            { value: '档位2: 共享文件夹' },
            { value: '档位3: 高级共享' }
          ])
            .selected((this.oneDriveConfig?.tier || 1) - 1)
            .onSelect((index: number) => {
              if (this.oneDriveConfig) {
                this.oneDriveConfig.tier = (index + 1) as 1 | 2 | 3;
              }
            })
            .layoutWeight(1);
        }
        .width('100%')
        .margin({ bottom: 20 });

        // 启用开关
        Row() {
          Text('启用 OneDrive:')
            .fontSize(16)
            .fontColor('#666666')
            .width(100);

          Toggle({ type: ToggleType.Switch, isOn: this.oneDriveConfig?.enabled || false })
            .onChange((isOn: boolean) => {
              if (this.oneDriveConfig) {
                this.oneDriveConfig.enabled = isOn;
              }
            })
            .layoutWeight(1);
        }
        .width('100%')
        .margin({ bottom: 20 });

        // 自动安装开关
        Row() {
          Text('自动安装:')
            .fontSize(16)
            .fontColor('#666666')
            .width(100);

          Toggle({ type: ToggleType.Switch, isOn: this.oneDriveConfig?.autoInstall || false })
            .onChange((isOn: boolean) => {
              if (this.oneDriveConfig) {
                this.oneDriveConfig.autoInstall = isOn;
              }
            })
            .layoutWeight(1);
        }
        .width('100%')
        .margin({ bottom: 24 });

        // 保存按钮
        Button('保存配置')
          .width('100%')
          .height(48)
          .backgroundColor('#0078D4')
          .fontColor(Color.White)
          .borderRadius(8)
          .onClick(() => {
            if (this.oneDriveConfig) {
              this.oneDriveManager.updateConfig(this.oneDriveConfig);
            }
            this.showConfigDialog = false;
          });
      }
      .width('100%')
      .padding(24)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .shadow({
        radius: 16,
        color: '#1A000000',
        offsetX: 0,
        offsetY: 8
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding(20);
  }
}
