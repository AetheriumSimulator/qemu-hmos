import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import display from '@ohos.display';
import hilog from '@ohos.hilog';
import { StoragePaths } from '../utils/StoragePaths';
import { initBreakpointStorage, updateBreakpointStorage } from '../utils/BreakpointSystem';
import { MicrophoneManager } from '../managers/MicrophoneManager';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  private microphoneAbilityId: number = 0;
  private displayDensity: number = 2; // 默认 density
  
  onCreate(want: Want, launchParam: object): void {
    hilog.info(0x0000, 'EntryAbility', 'onCreate');
    this.microphoneAbilityId = MicrophoneManager.getInstance().registerAbility(this.context, 'EntryAbility');
    
    // 初始化 AppStorage 存储窗口状态
    AppStorage.setOrCreate<boolean>('showCustomTitleBar', true);
    AppStorage.setOrCreate<number>('safeAreaTop', 0);
    AppStorage.setOrCreate<string>('windowMode', 'unknown');
    AppStorage.setOrCreate<string>('launchShortcutId', '');
    
    // 处理从桌面快捷方式启动的场景
    const sid = want && want.parameters && typeof want.parameters['shortcutId'] === 'string'
      ? String(want.parameters['shortcutId'])
      : '';
    if (sid) {
      hilog.info(0x0000, 'EntryAbility', '通过快捷方式启动, shortcutId=%{public}s', sid);
      AppStorage.set<string>('launchShortcutId', sid);
    }
    
    // 初始化断点系统
    initBreakpointStorage();
  }
  
  onNewWant(want: Want, launchParam: object): void {
    hilog.info(0x0000, 'EntryAbility', 'onNewWant');
    const sid = want && want.parameters && typeof want.parameters['shortcutId'] === 'string'
      ? String(want.parameters['shortcutId'])
      : '';
    if (sid) {
      hilog.info(0x0000, 'EntryAbility', 'onNewWant 收到快捷方式, shortcutId=%{public}s', sid);
      AppStorage.set<string>('launchShortcutId', sid);
    }
  }
  
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, 'EntryAbility', 'onWindowStageCreate');
    if (this.microphoneAbilityId === 0) {
      this.microphoneAbilityId = MicrophoneManager.getInstance().registerAbility(this.context, 'EntryAbility');
    }
    const microphoneAbilityId = this.microphoneAbilityId;
    
    // 初始化公共目录
    StoragePaths.initPublicDirs(this.context).catch((e: Error): void => {
      hilog.error(0x0000, 'EntryAbility', '初始化公共目录失败: %{public}s', e.message);
    });
    
    // 获取主窗口
    try {
    windowStage.getMainWindow().then((win: window.Window): void => {
      if (this.microphoneAbilityId !== microphoneAbilityId) return;
      this.mainWindow = win;
      MicrophoneManager.getInstance().attachWindow(microphoneAbilityId, win);
      hilog.info(0x0000, 'EntryAbility', '获取主窗口成功');
      
      // 获取显示器信息（用于计算真实的 density）
      try {
        const displayInfo = display.getDefaultDisplaySync();
        // density = densityDPI / 160
        const dpi = displayInfo.densityDPI ?? 320;
        this.displayDensity = dpi / 160;
        hilog.info(0x0000, 'EntryAbility', '显示器 densityDPI=%{public}d density=%{public}f', dpi, this.displayDensity);
      } catch (e) {
        hilog.warn(0x0000, 'EntryAbility', '获取显示器信息失败，使用默认 density: %{public}s', (e as Error).message);
        this.displayDensity = 2;
      }
      
      // 获取初始窗口状态
      this.updateWindowState(win);
      
      // 初始化断点（获取窗口尺寸，px 转 vp）
      const windowRect = win.getWindowProperties().windowRect;
      const widthVp = windowRect.width / this.displayDensity;
      const heightVp = windowRect.height / this.displayDensity;
      hilog.info(0x0000, 'EntryAbility', '窗口尺寸: %{public}dx%{public}d px = %{public}fx%{public}f vp',
        windowRect.width, windowRect.height, widthVp, heightVp);
      updateBreakpointStorage(widthVp, heightVp);
      
      // 监听窗口状态变化
      win.on('windowStatusChange', (statusType: window.WindowStatusType): void => {
        hilog.info(0x0000, 'EntryAbility', '窗口状态变化: %{public}d', statusType);
        this.handleWindowStatusChange(statusType);
        
        // 窗口状态变化时，重新获取窗口尺寸并更新断点
        try {
          const windowRect = win.getWindowProperties().windowRect;
          const widthVp = windowRect.width / this.displayDensity;
          const heightVp = windowRect.height / this.displayDensity;
          hilog.info(0x0000, 'EntryAbility', '状态变化后窗口尺寸: %{public}fx%{public}f vp', widthVp, heightVp);
          updateBreakpointStorage(widthVp, heightVp);
        } catch (e) {
          hilog.warn(0x0000, 'EntryAbility', '状态变化后更新断点失败: %{public}s', (e as Error).message);
        }
      });
      
      // 监听窗口尺寸变化并更新断点
      win.on('windowSizeChange', (size: window.Size): void => {
        hilog.info(0x0000, 'EntryAbility', '窗口尺寸变化: %{public}dx%{public}d px', size.width, size.height);
        // 更新断点信息（px 转 vp，使用真实的 density）
        const widthVp = size.width / this.displayDensity;
        const heightVp = size.height / this.displayDensity;
        hilog.info(0x0000, 'EntryAbility', '窗口尺寸: %{public}fx%{public}f vp', widthVp, heightVp);
        updateBreakpointStorage(widthVp, heightVp);
      });

      // 监听避让区变化（悬浮窗/自由多窗顶部控制条）
      try {
        win.on('avoidAreaChange', (): void => {
          try {
            const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
            const safeTop = avoidArea.topRect.height;
            AppStorage.set<number>('safeAreaTop', safeTop);

            const rect = win.getWindowProperties().windowRect;
            const widthVp = rect.width / this.displayDensity;
            const heightVp = rect.height / this.displayDensity;
            updateBreakpointStorage(widthVp, heightVp);
            hilog.info(0x0000, 'EntryAbility', 'avoidAreaChange safeTop=%{public}d vp=%{public}fx%{public}f', safeTop, widthVp, heightVp);
          } catch (e) {
            hilog.warn(0x0000, 'EntryAbility', '处理 avoidAreaChange 失败: %{public}s', (e as Error).message);
          }
        });
      } catch (e) {
        hilog.warn(0x0000, 'EntryAbility', '注册 avoidAreaChange 失败: %{public}s', (e as Error).message);
      }
      
    }).catch((err: Error): void => {
      MicrophoneManager.getInstance().windowFailed(microphoneAbilityId);
      hilog.error(0x0000, 'EntryAbility', '获取主窗口失败: %{public}s', err.message);
    });
    } catch (_) {
      MicrophoneManager.getInstance().windowFailed(microphoneAbilityId);
    }
    
    // 加载内容
    try {
    windowStage.loadContent('pages/Index', (err, data) => {
      if (err.code) {
        MicrophoneManager.getInstance().windowFailed(microphoneAbilityId);
        hilog.error(0x0000, 'EntryAbility', '加载内容失败: %{public}d, %{public}s', err.code, err.message);
        return;
      }
      MicrophoneManager.getInstance().contentReady(microphoneAbilityId);
      hilog.info(0x0000, 'EntryAbility', '内容加载成功');
    });
    } catch (_) {
      MicrophoneManager.getInstance().windowFailed(microphoneAbilityId);
    }
  }
  
  // 更新窗口状态
  private updateWindowState(win: window.Window): void {
    try {
      // 获取当前窗口状态
      const statusType = win.getWindowStatus();
      hilog.info(0x0000, 'EntryAbility', '当前窗口状态: %{public}d', statusType);
      this.handleWindowStatusChange(statusType);
      
      // 获取安全区域
      const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const safeAreaTop = avoidArea.topRect.height;
      hilog.info(0x0000, 'EntryAbility', '安全区域顶部: %{public}d', safeAreaTop);
      AppStorage.set<number>('safeAreaTop', safeAreaTop);
      
    } catch (e) {
      hilog.error(0x0000, 'EntryAbility', '更新窗口状态失败: %{public}s', (e as Error).message);
    }
  }
  
  // 处理窗口状态变化
  private handleWindowStatusChange(statusType: window.WindowStatusType): void {
    // FLOATING = 自由多窗模式 → 隐藏系统标题栏，显示自定义标题栏
    // FULL_SCREEN = 全屏模式 → 不显示自定义标题栏
    // SPLIT_SCREEN = 分屏模式 → 显示自定义标题栏
    
    switch (statusType) {
      case window.WindowStatusType.FLOATING:
        // 自由多窗模式 - 隐藏系统标题栏，显示自定义标题栏
        hilog.info(0x0000, 'EntryAbility', '自由多窗模式 - 尝试隐藏系统标题栏');
        this.hideSystemDecorAndShowCustom();
        AppStorage.set<string>('windowMode', 'floating');
        break;
        
      case window.WindowStatusType.FULL_SCREEN:
        // 全屏模式 - 不显示自定义标题栏
        hilog.info(0x0000, 'EntryAbility', '全屏模式 - 不显示自定义标题栏');
        AppStorage.set<boolean>('showCustomTitleBar', false);
        AppStorage.set<string>('windowMode', 'fullscreen');
        break;
        
      case window.WindowStatusType.SPLIT_SCREEN:
        // 分屏模式 - 显示自定义标题栏
        hilog.info(0x0000, 'EntryAbility', '分屏模式 - 显示自定义标题栏');
        this.hideSystemDecorAndShowCustom();
        AppStorage.set<string>('windowMode', 'split');
        break;
        
      default:
        // 未知状态 - 默认显示自定义标题栏
        hilog.info(0x0000, 'EntryAbility', '未知窗口状态: %{public}d - 显示自定义标题栏', statusType);
        AppStorage.set<boolean>('showCustomTitleBar', true);
        AppStorage.set<string>('windowMode', 'unknown');
        break;
    }
  }
  
  // 隐藏系统标题栏并显示自定义标题栏
  private hideSystemDecorAndShowCustom(): void {
    if (!this.mainWindow) {
      AppStorage.set<boolean>('showCustomTitleBar', true);
      return;
    }
    
    try {
      // 尝试隐藏系统窗口装饰（标题栏）
      // API: setWindowDecorVisible(false) - 同步方法
      this.mainWindow.setWindowDecorVisible(false);
      hilog.info(0x0000, 'EntryAbility', '系统标题栏已隐藏');
      
      // 设置自定义标题栏高度（让系统三键区域对齐）
      this.mainWindow.setWindowDecorHeight(50);
      hilog.info(0x0000, 'EntryAbility', '标题栏高度已设置为 50');
      
      AppStorage.set<boolean>('showCustomTitleBar', true);
    } catch (e) {
      hilog.warn(0x0000, 'EntryAbility', '隐藏系统标题栏失败: %{public}s', (e as Error).message);
      // 隐藏失败，可能 API 不支持，仍然显示自定义标题栏
      AppStorage.set<boolean>('showCustomTitleBar', true);
    }
  }
  

  onDestroy(): void {
    MicrophoneManager.getInstance().removeAbility(this.microphoneAbilityId);
    this.microphoneAbilityId = 0;
    hilog.info(0x0000, 'EntryAbility', 'onDestroy');
  }

  onWindowStageDestroy(): void {
    MicrophoneManager.getInstance().removeAbility(this.microphoneAbilityId);
    this.microphoneAbilityId = 0;
    hilog.info(0x0000, 'EntryAbility', 'onWindowStageDestroy');
    // 清理监听器
    if (this.mainWindow) {
      this.mainWindow.off('windowStatusChange');
      this.mainWindow.off('windowSizeChange');
    }
    this.mainWindow = null;
  }

  onForeground(): void {
    MicrophoneManager.getInstance().foreground(this.microphoneAbilityId, true);
    hilog.info(0x0000, 'EntryAbility', 'onForeground');
  }

  onBackground(): void {
    MicrophoneManager.getInstance().foreground(this.microphoneAbilityId, false);
    hilog.info(0x0000, 'EntryAbility', 'onBackground');
  }
}
