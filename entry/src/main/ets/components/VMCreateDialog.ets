import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

// 虚拟机配置接口
interface VMCreateConfig {
  name: string;
  osType: string;
  isoPath: string;
  diskSize: number; // GB
  memory: number; // MB
}

@CustomDialog
export struct VMCreateDialog {
  @State vmConfig: VMCreateConfig = {
    name: '',
    osType: 'Windows 11',
    isoPath: '',
    diskSize: 64,
    memory: 4096
  };
  @State isIsoSelected: boolean = false;
  @State createButtonEnabled: boolean = false;
  
  controller: CustomDialogController;
  onConfirm?: (config: VMCreateConfig) => void;
  onCancel?: () => void;

  aboutToAppear() {
    this.updateCreateButtonState();
  }

  // 更新创建按钮状态
  updateCreateButtonState() {
    this.createButtonEnabled = this.vmConfig.name.trim() !== '' && 
                              this.vmConfig.isoPath !== '' && 
                              this.vmConfig.diskSize > 0 && 
                              this.vmConfig.memory > 0;
  }

  // 选择ISO文件
  selectISOFile() {
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.maxSelectNumber = 1;
      documentSelectOptions.fileSuffixFilters = ['.iso'];
      
      const documentViewPicker = new picker.DocumentViewPicker();
      documentViewPicker.select(documentSelectOptions).then((documentSelectResult) => {
        if (documentSelectResult && documentSelectResult.length > 0) {
          // 保存选择的ISO文件路径
          this.vmConfig.isoPath = documentSelectResult[0];
          this.isIsoSelected = true;
          this.updateCreateButtonState();
          console.log('Selected ISO file:', this.vmConfig.isoPath);
        }
      }).catch((err: BusinessError) => {
        console.error('选择ISO文件失败:', err);
      });
    } catch (error) {
      console.error('打开文件选择器失败:', error);
    }
  }

  // 创建虚拟机
  createVM() {
    if (this.createButtonEnabled && this.onConfirm) {
      this.onConfirm(this.vmConfig);
    }
    this.controller.close();
  }

  // 取消创建
  cancelCreate() {
    if (this.onCancel) {
      this.onCancel();
    }
    this.controller.close();
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('创建新虚拟机')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        
        Button() {
          Image($r('sys.media.ohos_ic_public_cancel'))
            .width(24)
            .height(24)
            .fillColor('#666666')
        }
        .type(ButtonType.Circle)
        .backgroundColor(Color.Transparent)
        .width(32)
        .height(32)
        .onClick(() => this.cancelCreate())
      }
      .width('100%')
      .padding({ bottom: 24 })

      // 配置表单
      Column({ space: 20 }) {
        // 虚拟机名称
        Column({ space: 8 }) {
          Row() {
            Text('虚拟机名称')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            Text('*')
              .fontSize(16)
              .fontColor('#FF4D4F')
          }
          
          TextInput({ placeholder: '请输入虚拟机名称' })
            .width('100%')
            .height(48)
            .borderRadius(8)
            .backgroundColor('#F5F5F5')
            .onChange((value: string) => {
              this.vmConfig.name = value;
              this.updateCreateButtonState();
            })
        }
        .alignItems(HorizontalAlign.Start)

        // 操作系统类型
        Column({ space: 8 }) {
          Text('操作系统类型')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          
          Select([{ value: 'Windows 11' }, { value: 'Windows 10' }, { value: 'Ubuntu' }, { value: 'CentOS' }])
            .selected(0)
            .value('Windows 11')
            .font({ size: 16 })
            .selectedOptionFont({ size: 16 })
            .optionFont({ size: 16 })
            .width('100%')
            .height(48)
            .borderRadius(8)
            .backgroundColor('#F5F5F5')
            .onSelect((index: number, value?: string) => {
              if (value) {
                this.vmConfig.osType = value;
              }
            })
        }
        .alignItems(HorizontalAlign.Start)

        // ISO文件选择
        Column({ space: 8 }) {
          Row() {
            Text('ISO镜像文件')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            Text('*')
              .fontSize(16)
              .fontColor('#FF4D4F')
          }
          
          Button() {
            Row() {
              Text('📁')
                .fontSize(20)
                .margin({ right: 8 })
              
              Text(this.isIsoSelected ? '已选择ISO文件' : '点击选择ISO文件')
                .fontSize(14)
                .fontColor(this.isIsoSelected ? '#007DFF' : '#666666')
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
              
              if (this.isIsoSelected) {
                Text('✓')
                  .fontSize(16)
                  .fontColor('#4CAF50')
              }
            }
            .width('100%')
          }
          .type(ButtonType.Normal)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
          .width('100%')
          .height(48)
          .onClick(() => this.selectISOFile())
          
          if (this.isIsoSelected && this.vmConfig.isoPath) {
            Text(`文件路径: ${this.vmConfig.isoPath}`)
              .fontSize(12)
              .fontColor('#666666')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)

        // 磁盘大小设置
        Column({ space: 8 }) {
          Text('虚拟磁盘大小')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          
          Row() {
            Slider({
              value: this.vmConfig.diskSize,
              min: 20,
              max: 500,
              step: 1
            })
              .width('70%')
              .trackColor('#E5E5E5')
              .selectedColor('#007DFF')
              .blockColor('#007DFF')
              .onChange((value: number) => {
                this.vmConfig.diskSize = Math.round(value);
                this.updateCreateButtonState();
              })
            
            Text(`${this.vmConfig.diskSize} GB`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .width('30%')
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)

        // 内存大小设置
        Column({ space: 8 }) {
          Text('内存大小')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          
          Row() {
            Slider({
              value: this.vmConfig.memory,
              min: 1024,
              max: 16384,
              step: 512
            })
              .width('70%')
              .trackColor('#E5E5E5')
              .selectedColor('#007DFF')
              .blockColor('#007DFF')
              .onChange((value: number) => {
                this.vmConfig.memory = Math.round(value);
                this.updateCreateButtonState();
              })
            
            Text(`${this.vmConfig.memory} MB`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .width('30%')
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)

      // 底部按钮
      Row({ space: 12 }) {
        Button('取消')
          .type(ButtonType.Normal)
          .backgroundColor('#F5F5F5')
          .fontColor('#666666')
          .borderRadius(8)
          .layoutWeight(1)
          .height(48)
          .onClick(() => this.cancelCreate())
        
        Button('创建虚拟机')
          .type(ButtonType.Normal)
          .backgroundColor(this.createButtonEnabled ? '#007DFF' : '#CCCCCC')
          .fontColor(Color.White)
          .borderRadius(8)
          .layoutWeight(1)
          .height(48)
          .enabled(this.createButtonEnabled)
          .onClick(() => this.createVM())
      }
      .width('100%')
      .padding({ top: 24 })
    }
    .width('100%')
    .height('80%')
    .padding(24)
    .backgroundColor(Color.White)
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}