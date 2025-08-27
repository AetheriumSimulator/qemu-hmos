/**
 * 主题管理器 - 统一管理应用主题
 * 支持深色模式和浅色模式切换
 */

import { AppStorage } from '@kit.ArkUI'

export enum ThemeMode {
  LIGHT = 'light',
  DARK = 'dark',
  AUTO = 'auto'
}

export interface AppTheme {
  // 背景色
  backgroundColor: string | number
  surfaceColor: string | number
  cardColor: string | number
  
  // 文本色
  primaryTextColor: string | number
  secondaryTextColor: string | number
  tertiaryTextColor: string | number
  
  // 品牌色
  brandColor: string | number
  brandColorPressed: string | number
  brandColorDisabled: string | number
  
  // 功能色
  successColor: string | number
  warningColor: string | number
  errorColor: string | number
  
  // 分割线和边框
  dividerColor: string | number
  borderColor: string | number
  
  // 阴影
  shadowColor: string | number
}

// 浅色主题
export const LightTheme: AppTheme = {
  backgroundColor: '#F1F3F5',
  surfaceColor: '#FFFFFF',
  cardColor: '#FFFFFF',
  
  primaryTextColor: '#182431',
  secondaryTextColor: '#99182431',
  tertiaryTextColor: '#66182431',
  
  brandColor: '#007DFF',
  brandColorPressed: '#0A59F7',
  brandColorDisabled: '#66007DFF',
  
  successColor: '#13CE66',
  warningColor: '#FF8F1F',
  errorColor: '#FA2A2D',
  
  dividerColor: '#33182431',
  borderColor: '#33182431',
  
  shadowColor: '#1A000000'
}

// 深色主题
export const DarkTheme: AppTheme = {
  backgroundColor: '#0D1117',
  surfaceColor: '#161B22',
  cardColor: '#21262D',
  
  primaryTextColor: '#E6EDF3',
  secondaryTextColor: '#99E6EDF3',
  tertiaryTextColor: '#66E6EDF3',
  
  brandColor: '#409EFF',
  brandColorPressed: '#337ECC',
  brandColorDisabled: '#66409EFF',
  
  successColor: '#67C23A',
  warningColor: '#E6A23C',
  errorColor: '#F56C6C',
  
  dividerColor: '#33E6EDF3',
  borderColor: '#33E6EDF3',
  
  shadowColor: '#1A000000'
}

class ThemeManager {
  private static instance: ThemeManager
  private currentTheme: AppTheme = LightTheme
  private themeMode: ThemeMode = ThemeMode.LIGHT
  private listeners: Array<(theme: AppTheme) => void> = []
  
  static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager()
    }
    return ThemeManager.instance
  }
  
  getCurrentTheme(): AppTheme {
    return this.currentTheme
  }
  
  getThemeMode(): ThemeMode {
    return this.themeMode
  }
  
  setThemeMode(mode: ThemeMode): void {
    this.themeMode = mode
    this.updateTheme()
  }
  
  private updateTheme(): void {
    let newTheme: AppTheme
    
    switch (this.themeMode) {
      case ThemeMode.LIGHT:
        newTheme = LightTheme
        break
      case ThemeMode.DARK:
        newTheme = DarkTheme
        break
      case ThemeMode.AUTO:
        // 根据系统设置自动切换
        newTheme = this.getSystemTheme()
        break
      default:
        newTheme = LightTheme
    }
    
    this.currentTheme = newTheme
    this.notifyListeners()
  }
  
  private getSystemTheme(): AppTheme {
    try {
      // 通过AppStorage获取系统配置
      const systemColorMode = AppStorage.get<number>('systemColorMode') || 0
      // 0: 浅色模式, 1: 深色模式
      return systemColorMode === 1 ? DarkTheme : LightTheme
    } catch (error) {
      console.error('获取系统主题失败:', error)
      return LightTheme
    }
  }
  
  // 监听系统主题变化
  initSystemThemeListener(): void {
    if (this.themeMode === ThemeMode.AUTO) {
      // 监听系统配置变化
      AppStorage.setOrCreate('systemColorMode', 0)
      AppStorage.link('systemColorMode')
      
      // 当系统主题变化时更新主题
      const callback = () => {
        if (this.themeMode === ThemeMode.AUTO) {
          this.updateTheme()
        }
      }
      
      // 这里可以添加系统配置变化监听
      // 由于HarmonyOS的限制，需要在EntryAbility中监听配置变化
    }
  }
  
  addThemeChangeListener(listener: (theme: AppTheme) => void): void {
    this.listeners.push(listener)
  }
  
  removeThemeChangeListener(listener: (theme: AppTheme) => void): void {
    const index = this.listeners.indexOf(listener)
    if (index > -1) {
      this.listeners.splice(index, 1)
    }
  }
  
  private notifyListeners(): void {
    this.listeners.forEach(listener => {
      listener(this.currentTheme)
    })
  }
}

export default ThemeManager.getInstance()