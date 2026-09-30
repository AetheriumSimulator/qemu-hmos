/**
 * 命令面板组件 - VS Code 风格
 * 
 * 功能：
 * - 直接输入：搜索虚拟机，选中跳转
 * - 输入 / 前缀：进入命令模式
 * - /vm.run <vm名> <命令>：在 VM 中执行命令
 * - Ctrl+Alt+C 全局快捷键打开
 */
import hilog from '@ohos.hilog'

// 搜索结果项类型
type ResultType = 'vm' | 'command' | 'history'

// 搜索结果
interface SearchResult {
  type: ResultType
  id: string
  title: string
  subtitle?: string
  icon: Resource
  action: () => void
}

// 命令定义
interface CommandDef {
  id: string
  name: string
  desc: string
  icon: Resource
  shortcut?: string
  execute: (args: string[]) => void
}

// VM 信息（外部传入）
export interface VMInfo {
  id: string
  name: string
  status: string  // running | stopped | paused
  osType: string  // Windows | Linux
}

// 历史记录项
interface HistoryItem {
  type: 'vm' | 'command'
  value: string
  timestamp: number
}

@Component
export struct CommandPalette {
  // 状态
  @State displayText: string = ''       // TextInput 实际显示的文本（不包含 /）
  @State results: SearchResult[] = []
  @State selectedIndex: number = 0
  @State isCommandMode: boolean = false
  @State placeholder: string = '搜索虚拟机或输入 / 执行指令...'
  @State commandHistory: HistoryItem[] = []
  // 动画状态
  @State panelOpacity: number = 0
  @State slashTranslateX: number = 60   // 斜杠从右向左滑动的位移（60为隐藏位置）
  @State slashOpacity: number = 0       // 斜杠淡入
  @State resultListHeight: number = 400 // 结果列表高度（默认完全展开）
  @State isTransitioning: boolean = false  // 正在切换模式
  
  // 外部传入的数据
  @Prop vmList: VMInfo[] = []
  
  // 回调
  onClose?: () => void
  onNavigateToVm?: (vmId: string) => void
  onExecuteInVm?: (vmName: string, command: string) => void
  onCreateVm?: () => void
  onStartVm?: (vmId: string) => void
  onStopVm?: (vmId: string) => void
  onOpenVnc?: (vmId: string) => void
  onOpenConsole?: (vmId: string) => void
  onExportLogs?: () => void
  onOpenSettings?: () => void
  
  // 命令列表
  private commands: CommandDef[] = []
  
  aboutToAppear(): void {
    this.initCommands()
    this.updateResults()
    // 初始化动画状态
    this.slashTranslateX = 60
    this.slashOpacity = 0
    this.resultListHeight = 400  // 初始化为完整高度（非命令模式）
    // 触发淡入动画
    setTimeout((): void => {
      animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
        this.panelOpacity = 1
      })
    }, 10)
  }
  
  private initCommands(): void {
    this.commands = [
      {
        id: 'vm.create',
        name: '创建虚拟机',
        desc: '创建新的虚拟机',
        icon: $r('sys.symbol.plus_circle'),
        execute: (): void => {
          if (this.onCreateVm) this.onCreateVm()
          this.close()
        }
      },
      {
        id: 'vm.start',
        name: '启动虚拟机',
        desc: '启动选中的虚拟机 (用法: /vm.start <虚拟机名>)',
        icon: $r('sys.symbol.play_fill'),
        execute: (args: string[]): void => {
          const vmName = args.join(' ')
          const vm = this.findVmByName(vmName)
          if (vm && this.onStartVm) {
            this.onStartVm(vm.id)
          } else if (!vm && vmName) {
            this.showError(`找不到虚拟机: ${vmName}`)
          }
          this.close()
        }
      },
      {
        id: 'vm.stop',
        name: '停止虚拟机',
        desc: '停止运行中的虚拟机 (用法: /vm.stop <虚拟机名>)',
        icon: $r('sys.symbol.square_fill'),
        execute: (args: string[]): void => {
          const vmName = args.join(' ')
          const vm = this.findVmByName(vmName)
          if (vm && this.onStopVm) {
            this.onStopVm(vm.id)
          } else if (!vm && vmName) {
            this.showError(`找不到虚拟机: ${vmName}`)
          }
          this.close()
        }
      },
      {
        id: 'vm.vnc',
        name: '打开 VNC',
        desc: '打开虚拟机的 VNC 查看器 (用法: /vm.vnc <虚拟机名>)',
        icon: $r('sys.symbol.display'),
        execute: (args: string[]): void => {
          const vmName = args.join(' ')
          const vm = this.findVmByName(vmName)
          if (vm && this.onOpenVnc) {
            this.onOpenVnc(vm.id)
          } else if (!vm && vmName) {
            this.showError(`找不到虚拟机: ${vmName}`)
          }
          this.close()
        }
      },
      {
        id: 'vm.console',
        name: '打开控制台 (TTL)',
        desc: '打开 VM 的串口控制台 (用法: /vm.console <虚拟机名>)',
        icon: $r('sys.symbol.doc_plaintext_and_pencil'),
        execute: (args: string[]): void => {
          const vmName = args.join(' ')
          const vm = this.findVmByName(vmName)
          if (vm && this.onOpenConsole) {
            this.onOpenConsole(vm.id)
          } else if (!vm && vmName) {
            this.showError(`找不到虚拟机: ${vmName}`)
          }
          this.close()
        }
      },
      {
        id: 'vm.run',
        name: '在虚拟机中执行命令',
        desc: '用法: /vm.run <虚拟机名> <命令>',
        icon: $r('sys.symbol.chevron_right'),
        shortcut: 'Ctrl+Shift+R',
        execute: (args: string[]): void => {
          if (args.length < 2) {
            this.showError('用法: /vm.run <虚拟机名> <命令>')
            return
          }
          // 第一个参数是虚拟机名，其余是命令
          const vmName = args[0]
          const command = args.slice(1).join(' ')
          const vm = this.findVmByName(vmName)
          if (vm) {
            if (vm.status !== 'running') {
              this.showError(`虚拟机 ${vmName} 未运行`)
              return
            }
            if (this.onExecuteInVm) {
              this.onExecuteInVm(vmName, command)
              this.addHistory('command', `/vm.run ${vmName} ${command}`)
            }
          } else {
            this.showError(`找不到虚拟机: ${vmName}`)
          }
          this.close()
        }
      },
      {
        id: 'app.logs',
        name: '导出日志',
        desc: '导出所有虚拟机日志',
        icon: $r('sys.symbol.doc_text'),
        execute: (): void => {
          if (this.onExportLogs) this.onExportLogs()
          this.close()
        }
      },
      {
        id: 'app.settings',
        name: '设置',
        desc: '打开应用设置',
        icon: $r('sys.symbol.gearshape'),
        shortcut: 'Ctrl+,',
        execute: (): void => {
          if (this.onOpenSettings) this.onOpenSettings()
          this.close()
        }
      },
      {
        id: 'app.reload',
        name: '刷新虚拟机列表',
        desc: '重新加载虚拟机列表',
        icon: $r('sys.symbol.arrow_clockwise'),
        shortcut: 'Ctrl+R',
        execute: (): void => {
          hilog.info(0x0000, 'CMD', '刷新虚拟机列表')
          this.close()
        }
      },
      {
        id: 'help',
        name: '帮助',
        desc: '查看命令帮助',
        icon: $r('sys.symbol.questionmark_circle'),
        shortcut: 'F1',
        execute: (): void => {
          hilog.info(0x0000, 'CMD', '显示帮助')
          this.close()
        }
      }
    ]
  }
  
  private findVmByName(name: string): VMInfo | undefined {
    if (!name) return undefined
    const lowerName = name.toLowerCase()
    return this.vmList.find((vm): boolean => 
      vm.name.toLowerCase() === lowerName || 
      vm.name.toLowerCase().includes(lowerName)
    )
  }
  
  private showError(msg: string): void {
    hilog.error(0x0000, 'CMD', msg)
    // TODO: 显示错误提示
  }
  
  private addHistory(type: 'vm' | 'command', value: string): void {
    const item: HistoryItem = { type, value, timestamp: Date.now() }
    this.commandHistory = [item, ...this.commandHistory.filter((h): boolean => h.value !== value)].slice(0, 20)
  }
  
  private close(): void {
    // 触发淡出动画
    animateTo({ duration: 150, curve: Curve.EaseIn }, (): void => {
      this.panelOpacity = 0
    })
    // 动画结束后执行关闭
    setTimeout((): void => {
      this.displayText = ''
      this.results = []
      this.selectedIndex = 0
      this.isCommandMode = false
      if (this.onClose) this.onClose()
    }, 150)
  }

  // 处理 backspace 退出命令模式（带动画）
  private handleBackspace(): void {
    if (this.isCommandMode && this.displayText === '') {
      this.exitCommandModeWithAnimation()
    }
  }
  
  // 退出命令模式的动画
  private exitCommandModeWithAnimation(): void {
    this.isTransitioning = true
    // 动画：斜杠从左滑到右，淡出
    animateTo({
      duration: 200,
      curve: Curve.EaseIn
    }, (): void => {
      this.slashTranslateX = 60
      this.slashOpacity = 0
    })
    // 结果列表收起动画
    animateTo({
      duration: 200,
      curve: Curve.EaseIn
    }, (): void => {
      this.resultListHeight = 0
    })
    // 动画结束后切换状态并展开新结果
    setTimeout((): void => {
      this.displayText = ''
      this.isCommandMode = false
      this.placeholder = '搜索虚拟机或输入 / 执行命令...'
      this.updateResults()
      // 切换到搜索模式后，展开结果列表
      animateTo({
        duration: 200,
        curve: Curve.EaseOut
      }, (): void => {
        this.resultListHeight = 400
      })
      setTimeout((): void => {
        this.isTransitioning = false
      }, 200)
    }, 200)
  }
  
  private updateResults(): void {
    const query = this.displayText.trim()
    
    // 根据当前模式更新结果
    if (this.isCommandMode) {
      this.placeholder = '输入命令...'
      this.searchCommands(query)
    } else {
      this.placeholder = '搜索虚拟机或输入 / 执行命令...'
      this.searchAll(query)
    }
    
    this.selectedIndex = 0
  }
  
  private searchAll(query: string): void {
    const results: SearchResult[] = []
    const lowerQuery = query.toLowerCase()
    
    // 搜索虚拟机
    for (const vm of this.vmList) {
      if (!query || vm.name.toLowerCase().includes(lowerQuery)) {
        results.push({
          type: 'vm',
          id: vm.id,
          title: vm.name,
          subtitle: `${vm.osType} · ${vm.status === 'running' ? '运行中' : '已停止'}`,
          icon: vm.osType === 'Windows' ? $r('sys.symbol.display') : $r('sys.symbol.chevron_right'),
          action: (): void => {
            this.addHistory('vm', vm.name)
            if (this.onNavigateToVm) this.onNavigateToVm(vm.id)
            this.close()
          }
        })
      }
    }
    
    // 如果没有搜索词，显示常用命令
    if (!query) {
      results.push({
        type: 'command',
        id: 'vm.create',
        title: '创建虚拟机',
        subtitle: '输入 / 查看更多命令',
        icon: $r('sys.symbol.plus_circle'),
        action: (): void => {
          if (this.onCreateVm) this.onCreateVm()
          this.close()
        }
      })
    }
    
    this.results = results
  }
  
  private searchCommands(query: string): void {
    const results: SearchResult[] = []
    const lowerQuery = query.toLowerCase()
    
    // 解析命令和参数
    const parts = query.split(' ')
    const cmdPart = parts[0]
    const args = parts.slice(1)
    
    // 精确匹配命令
    const exactCmd = this.commands.find((c): boolean => c.id === cmdPart)
    if (exactCmd && args.length > 0) {
      // 如果是带参数的命令，显示参数提示
      results.push({
        type: 'command',
        id: exactCmd.id,
        title: `/${exactCmd.id} ${args.join(' ')}`,
        subtitle: exactCmd.desc,
        icon: exactCmd.icon,
        action: (): void => {
          exactCmd.execute(args)
        }
      })
      
      // 如果命令需要 VM 名，显示 VM 补全
        if (['vm.start', 'vm.stop', 'vm.vnc', 'vm.run'].includes(exactCmd.id)) {
        const vmQuery = args[0]?.toLowerCase() || ''
        for (const vm of this.vmList) {
          if (!vmQuery || vm.name.toLowerCase().includes(vmQuery)) {
            const newArgs = [vm.name, ...args.slice(1)]
            results.push({
              type: 'vm',
              id: vm.id,
              title: `/${exactCmd.id} ${vm.name}${args.length > 1 ? ' ' + args.slice(1).join(' ') : ''}`,
              subtitle: `${vm.osType} · ${vm.status === 'running' ? '运行中' : '已停止'}`,
              icon: vm.osType === 'Windows' ? $r('sys.symbol.display') : $r('sys.symbol.chevron_right'),
              action: (): void => {
                exactCmd.execute(newArgs)
              }
            })
          }
        }
      }
    } else {
      // 模糊搜索命令
      for (const cmd of this.commands) {
        if (!cmdPart || cmd.id.includes(cmdPart) || cmd.name.includes(lowerQuery)) {
          results.push({
            type: 'command',
            id: cmd.id,
            title: `/${cmd.id}`,
            subtitle: cmd.desc + (cmd.shortcut ? ` (${cmd.shortcut})` : ''),
            icon: cmd.icon,
            action: (): void => {
              if (cmd.id === 'vm.run' || cmd.id === 'vm.start' || cmd.id === 'vm.stop' || cmd.id === 'vm.vnc') {
                // 需要参数的命令，不直接执行，而是补全（displayText 不含 /）
                this.displayText = `${cmd.id} `
                this.updateResults()
              } else {
                cmd.execute([])
              }
            }
          })
        }
      }
    }
    
    this.results = results
  }
  
  private executeSelected(): void {
    if (this.results.length > 0 && this.selectedIndex < this.results.length) {
      this.results[this.selectedIndex].action()
    }
  }
  
  private moveSelection(delta: number): void {
    const newIndex = this.selectedIndex + delta
    if (newIndex >= 0 && newIndex < this.results.length) {
      this.selectedIndex = newIndex
    }
  }

  build() {
    Stack() {
      // 遮罩层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000066')
        .opacity(this.panelOpacity)
        .onClick((): void => { this.close() })
      
      // 命令面板
      Column() {
        // 输入框
        Row() {
          // 左侧图标区域 - 固定宽度，用于显示搜索图标或斜杠
          Stack() {
            // 搜索图标（非命令模式显示）
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(18)
              .fontColor([$r('app.color.text_tertiary')])
              .opacity(this.isCommandMode ? 0 : 1)
              .animation({ duration: 200, curve: Curve.EaseOut })
            
            // 斜杠图标（命令模式显示，带滑入动画）
            if (this.isCommandMode || this.isTransitioning) {
              Text('/')
                .fontSize(18)
                .fontColor($r('app.color.accent'))
                .fontWeight(FontWeight.Bold)
                .opacity(this.slashOpacity)
                .translate({ x: this.slashTranslateX })
            }
          }
          .width(26)
          .height(26)
          .margin({ right: 8 })
          
          TextInput({ 
            text: this.displayText, 
            placeholder: this.placeholder 
          })
            .layoutWeight(1)
            .height(40)
            .backgroundColor(Color.Transparent)
            .fontSize(15)
            .caretColor($r('app.color.accent'))
            .defaultFocus(true)
            .onChange((value: string): void => {
              const wasCommandMode = this.isCommandMode
              
              // 检测是否刚输入 /（触发进入命令模式动画）
              if (!wasCommandMode && value === '/') {
                // 进入命令模式，清空 displayText（/ 由左侧图标显示）
                this.displayText = ''
                this.isCommandMode = true
                this.isTransitioning = true
                this.placeholder = '输入命令...'
                
                // 初始状态：斜杠在右边，透明
                this.slashTranslateX = 60
                this.slashOpacity = 0
                
                // 动画：斜杠从右滑到左，淡入
                animateTo({ 
                  duration: 250, 
                  curve: Curve.EaseOut 
                }, (): void => {
                  this.slashTranslateX = 0
                  this.slashOpacity = 1
                })
                
                // 结果列表展开动画
                this.resultListHeight = 0  // 初始高度为 0
                animateTo({
                  duration: 300,
                  curve: Curve.EaseOut,
                  delay: 50
                }, (): void => {
                  this.resultListHeight = 400
                })
                
                // 延长过渡状态持续时间
                setTimeout((): void => { this.isTransitioning = false }, 400)
                
                // 搜索命令
                this.searchCommands('')
                this.selectedIndex = 0
                return
              }
              
              // 检测 backspace 退出命令模式
              if (this.isCommandMode && value === '' && !this.isTransitioning) {
                this.exitCommandModeWithAnimation()
                return
              }
              
              // 正常更新 displayText
              this.displayText = value
              this.updateResults()
            })
            .onSubmit((): void => {
              this.executeSelected()
            })
          
          // 快捷键提示
          Text('Ctrl+Alt+C')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.sidebar_background'))
            .borderRadius(4)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.card_background'))
        
        Divider().color($r('app.color.divider'))
        
        // 结果列表（带展开动画）
        if (this.results.length > 0) {
          Scroll() {
            Column() {
              ForEach(this.results, (item: SearchResult, index: number) => {
                Row() {
                  // 图标
                  Row() {
                    SymbolGlyph(item.icon)
                      .fontSize(18)
                      .fontColor([index === this.selectedIndex ? $r('app.color.accent') : $r('app.color.text_secondary')])
                  }
                  .width(36)
                  .height(36)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(index === this.selectedIndex ? '#0A84FF1A' : Color.Transparent)
                  .borderRadius(8)
                  .margin({ right: 12 })
                  
                  // 标题和副标题
                  Column() {
                    Text(item.title)
                      .fontSize(14)
                      .fontColor(index === this.selectedIndex ? $r('app.color.accent') : $r('app.color.text_primary'))
                      .fontWeight(index === this.selectedIndex ? FontWeight.Medium : FontWeight.Normal)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (item.subtitle) {
                      Text(item.subtitle)
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ top: 2 })
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  
                  // 类型标签
                  if (item.type === 'vm') {
                    Text('VM')
                      .fontSize(10)
                      .fontColor($r('app.color.text_tertiary'))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .backgroundColor($r('app.color.sidebar_background'))
                      .borderRadius(4)
                  } else if (item.type === 'command') {
                    SymbolGlyph($r('sys.symbol.arrow_right'))
                      .fontSize(14)
                      .fontColor([$r('app.color.text_tertiary')])
                  }
                }
                .width('100%')
                .height(56)
                .padding({ left: 12, right: 12 })
                .backgroundColor(index === this.selectedIndex ? $r('app.color.sidebar_background') : Color.Transparent)
                .borderRadius(8)
                .onClick((): void => {
                  item.action()
                })
                .onHover((isHover: boolean): void => {
                  if (isHover) this.selectedIndex = index
                })
              })
            }
            .padding(8)
          }
          .constraintSize({ maxHeight: this.resultListHeight })
          .clip(true)
          .backgroundColor($r('app.color.card_background'))
        } else {
          // 空状态
          Column() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(32)
              .fontColor([$r('app.color.text_tertiary')])
              .margin({ bottom: 12 })
            Text(this.isCommandMode ? '没有匹配的命令' : '没有找到虚拟机')
              .fontSize(14)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.isCommandMode ? '输入 /help 查看所有命令' : '输入 / 开始执行命令')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 4 })
          }
          .width('100%')
          .height(120)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.card_background'))
        }
        
        // 底部提示栏
        Row() {
          Row() {
            Text('↑↓')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 4, right: 4, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(4)
            Text('选择')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 4 })
          }
          .margin({ right: 16 })
          
          Row() {
            Text('↵')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(4)
            Text('执行')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 4 })
          }
          .margin({ right: 16 })
          
          Row() {
            Text('Esc')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 4, right: 4, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(4)
            Text('关闭')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 4 })
          }
          
          Blank()
          
          Text(`${this.results.length} 个结果`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .height(36)
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.sidebar_background'))
      }
      .width(560)
      .borderRadius(12)
      .shadow({
        radius: 32,
        color: '#00000044',
        offsetX: 0,
        offsetY: 12
      })
      .clip(true)
      .margin({ top: 80 })
      .opacity(this.panelOpacity)
      .scale({ x: 0.98 + 0.02 * this.panelOpacity, y: 0.98 + 0.02 * this.panelOpacity })
    }
    .width('100%')
    .height('100%')
  }
}

