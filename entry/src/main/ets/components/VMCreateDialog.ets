import { VMCreateConfig } from '../pages/VMs';

@Component
export struct VMCreateDialog {
  @State name: string = '';
  @State osType: string = 'windows';
  @State isoPath: string = '';
  @State diskSize: number = 64;
  @State memory: number = 6144;
  @State cpuCount: number = 4;
  
  onConfirm: (config: VMCreateConfig) => void = () => {};
  onCancel: () => void = () => {};

  build() {
    Column() {
      Text('创建虚拟机')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })
      
      TextInput({ placeholder: '虚拟机名称' })
        .onChange((value: string) => { this.name = value; })
        .margin({ bottom: 16 })
      
      Row() {
        Text('操作系统:').fontSize(16).width(80)
        Select([
          { value: 'windows' },
          { value: 'linux' }
        ])
          .onSelect((index: number) => { 
            this.osType = index === 0 ? 'windows' : 'linux'; 
          })
      }.width('100%').margin({ bottom: 16 })
      
      TextInput({ placeholder: 'ISO镜像路径（可选）' })
        .onChange((value: string) => { this.isoPath = value; })
        .margin({ bottom: 16 })
      
      Row() {
        Text('磁盘大小:').fontSize(16).width(80)
        Text(`${this.diskSize}GB`).fontSize(14).width(60)
      }.width('100%').margin({ bottom: 16 })
      
      Slider({
        value: this.diskSize,
        min: 10,
        max: 500,
        step: 10
      })
        .onChange((value: number) => { this.diskSize = value; })
        .margin({ bottom: 16 })
      
      Row() {
        Text('内存:').fontSize(16).width(80)
        Text(`${this.memory}MB`).fontSize(14).width(80)
      }.width('100%').margin({ bottom: 16 })
      
      Slider({
        value: this.memory,
        min: 1024,
        max: 32768,
        step: 1024
      })
        .onChange((value: number) => { this.memory = value; })
        .margin({ bottom: 16 })
      
      Row() {
        Text('CPU核心:').fontSize(16).width(80)
        Text(`${this.cpuCount}`).fontSize(14).width(40)
      }.width('100%').margin({ bottom: 16 })
      
      Slider({
        value: this.cpuCount,
        min: 1,
        max: 16,
        step: 1
      })
        .onChange((value: number) => { this.cpuCount = value; })
        .margin({ bottom: 16 })
      
      Row() {
        Button('取消').onClick(() => { this.onCancel(); }).layoutWeight(1).margin({ right: 8 })
        Button('创建')
          .onClick(() => {
            if (this.name.trim()) {
              const config: VMCreateConfig = {
                name: this.name,
                osType: this.osType,
                isoPath: this.isoPath,
                diskSize: this.diskSize,
                memory: this.memory,
                cpuCount: this.cpuCount
              };
              this.onConfirm(config);
            }
          }).layoutWeight(1).margin({ left: 8 })
      }.width('100%')
    }
    .width('90%').padding(24).backgroundColor(Color.White).borderRadius(16)
  }
}