// RDP输入处理工具类

// 手势类型枚举
enum GestureType {
  SINGLE_TAP = 'single_tap',
  DOUBLE_TAP = 'double_tap',
  LONG_PRESS = 'long_press',
  PINCH = 'pinch',
  PAN = 'pan',
  SWIPE = 'swipe'
}

// 输入事件类型
interface InputEvent {
  type: 'mouse' | 'keyboard' | 'gesture'
  x?: number
  y?: number
  button?: number
  keyCode?: number
  scanCode?: number
  flags?: number
  gestureType?: GestureType
  data?: any
}

// 手势识别器
class GestureRecognizer {
  private lastTapTime: number = 0
  private tapCount: number = 0
  private longPressTimer: number | null = null
  private isPinching: boolean = false
  private lastPinchDistance: number = 0
  private panStartX: number = 0
  private panStartY: number = 0
  private isPanning: boolean = false
  
  // 识别手势
  recognizeGesture(event: TouchEvent): GestureType | null {
    const currentTime = Date.now()
    
    if (event.type === 0) { // TouchType.Down
      if (event.touches.length === 1) {
        // 单指按下
        this.handleSingleTouchDown(event, currentTime)
      } else if (event.touches.length === 2) {
        // 双指按下，可能是缩放手势
        this.handlePinchStart(event)
      }
    } else if (event.type === 1) { // TouchType.Up
      return this.handleTouchUp(event, currentTime)
    } else if (event.type === 2) { // TouchType.Move
      return this.handleTouchMove(event)
    }
    
    return null
  }
  
  private handleSingleTouchDown(event: TouchEvent, currentTime: number) {
    const touch = event.touches[0]
    this.panStartX = touch.x
    this.panStartY = touch.y
    
    // 检测双击
    if (currentTime - this.lastTapTime < 300) {
      this.tapCount++
    } else {
      this.tapCount = 1
    }
    this.lastTapTime = currentTime
    
    // 设置长按定时器
    this.longPressTimer = setTimeout(() => {
      // 触发长按事件
    }, 500)
  }
  
  private handleTouchUp(event: TouchEvent, currentTime: number): GestureType | null {
    if (this.longPressTimer) {
      clearTimeout(this.longPressTimer)
      this.longPressTimer = null
    }
    
    if (this.isPinching) {
      this.isPinching = false
      return null
    }
    
    if (this.isPanning) {
      this.isPanning = false
      return GestureType.PAN
    }
    
    // 检测点击类型
    if (this.tapCount === 1) {
      return GestureType.SINGLE_TAP
    } else if (this.tapCount >= 2) {
      this.tapCount = 0
      return GestureType.DOUBLE_TAP
    }
    
    return null
  }
  
  private handleTouchMove(event: TouchEvent): GestureType | null {
    if (event.touches.length === 2) {
      return this.handlePinchMove(event)
    } else if (event.touches.length === 1) {
      return this.handlePanMove(event)
    }
    
    return null
  }
  
  private handlePinchStart(event: TouchEvent) {
    if (event.touches.length >= 2) {
      const touch1 = event.touches[0]
      const touch2 = event.touches[1]
      this.lastPinchDistance = this.calculateDistance(touch1.x, touch1.y, touch2.x, touch2.y)
      this.isPinching = true
    }
  }
  
  private handlePinchMove(event: TouchEvent): GestureType | null {
    if (this.isPinching && event.touches.length >= 2) {
      const touch1 = event.touches[0]
      const touch2 = event.touches[1]
      const currentDistance = this.calculateDistance(touch1.x, touch1.y, touch2.x, touch2.y)
      
      if (Math.abs(currentDistance - this.lastPinchDistance) > 10) {
        this.lastPinchDistance = currentDistance
        return GestureType.PINCH
      }
    }
    
    return null
  }
  
  private handlePanMove(event: TouchEvent): GestureType | null {
    const touch = event.touches[0]
    const deltaX = Math.abs(touch.x - this.panStartX)
    const deltaY = Math.abs(touch.y - this.panStartY)
    
    if (deltaX > 10 || deltaY > 10) {
      this.isPanning = true
      return GestureType.PAN
    }
    
    return null
  }
  
  private calculateDistance(x1: number, y1: number, x2: number, y2: number): number {
    return Math.sqrt(Math.pow(x2 - x1, 2) + Math.pow(y2 - y1, 2))
  }
}

// 虚拟键盘管理器
class VirtualKeyboardManager {
  private isVisible: boolean = false
  private currentLayout: 'qwerty' | 'numeric' | 'symbols' = 'qwerty'
  private onKeyPress: ((keyCode: number, scanCode: number) => void) | null = null
  
  constructor(onKeyPress: (keyCode: number, scanCode: number) => void) {
    this.onKeyPress = onKeyPress
  }
  
  // 显示虚拟键盘
  show(layout: 'qwerty' | 'numeric' | 'symbols' = 'qwerty') {
    this.isVisible = true
    this.currentLayout = layout
  }
  
  // 隐藏虚拟键盘
  hide() {
    this.isVisible = false
  }
  
  // 切换键盘布局
  switchLayout(layout: 'qwerty' | 'numeric' | 'symbols') {
    this.currentLayout = layout
  }
  
  // 处理虚拟按键
  handleVirtualKey(key: string) {
    const keyCode = this.getKeyCodeFromString(key)
    const scanCode = this.convertKeyCodeToScanCode(keyCode)
    
    if (this.onKeyPress) {
      // 发送按下事件
      this.onKeyPress(keyCode, scanCode)
      // 延迟发送释放事件
      setTimeout(() => {
        if (this.onKeyPress) {
          this.onKeyPress(keyCode, scanCode | 0x8000)
        }
      }, 50)
    }
  }
  
  private getKeyCodeFromString(key: string): number {
    const keyMap: Record<string, number> = {
      'a': 65, 'b': 66, 'c': 67, 'd': 68, 'e': 69, 'f': 70, 'g': 71, 'h': 72,
      'i': 73, 'j': 74, 'k': 75, 'l': 76, 'm': 77, 'n': 78, 'o': 79, 'p': 80,
      'q': 81, 'r': 82, 's': 83, 't': 84, 'u': 85, 'v': 86, 'w': 87, 'x': 88,
      'y': 89, 'z': 90,
      '0': 48, '1': 49, '2': 50, '3': 51, '4': 52, '5': 53, '6': 54, '7': 55,
      '8': 56, '9': 57,
      ' ': 32, 'Enter': 13, 'Backspace': 8, 'Tab': 9, 'Shift': 16, 'Ctrl': 17,
      'Alt': 18, 'Escape': 27, 'Delete': 46
    }
    
    return keyMap[key] || 0
  }
  
  private convertKeyCodeToScanCode(keyCode: number): number {
    const keyMap: Record<number, number> = {
      8: 0x0E,   // Backspace
      9: 0x0F,   // Tab
      13: 0x1C,  // Enter
      16: 0x2A,  // Shift
      17: 0x1D,  // Ctrl
      18: 0x38,  // Alt
      20: 0x3A,  // Caps Lock
      27: 0x01,  // Escape
      32: 0x39,  // Space
      46: 0x53,  // Delete
      // 数字键 0-9
      48: 0x0B, 49: 0x02, 50: 0x03, 51: 0x04, 52: 0x05,
      53: 0x06, 54: 0x07, 55: 0x08, 56: 0x09, 57: 0x0A,
      // 字母键 A-Z
      65: 0x1E, 66: 0x30, 67: 0x2E, 68: 0x20, 69: 0x12,
      70: 0x21, 71: 0x22, 72: 0x23, 73: 0x17, 74: 0x24,
      75: 0x25, 76: 0x26, 77: 0x32, 78: 0x31, 79: 0x18,
      80: 0x19, 81: 0x10, 82: 0x13, 83: 0x1F, 84: 0x14,
      85: 0x16, 86: 0x2F, 87: 0x11, 88: 0x2D, 89: 0x15,
      90: 0x2C
    }
    
    return keyMap[keyCode] || 0x00
  }
  
  // 获取当前键盘状态
  getState() {
    return {
      isVisible: this.isVisible,
      currentLayout: this.currentLayout
    }
  }
}

// RDP输入处理器主类
export class RDPInputHandler {
  private gestureRecognizer: GestureRecognizer
  private virtualKeyboard: VirtualKeyboardManager
  private onInputEvent: ((event: InputEvent) => void) | null = null
  private isRightClickMode: boolean = false
  private isScrollMode: boolean = false
  
  constructor(onInputEvent: (event: InputEvent) => void) {
    this.onInputEvent = onInputEvent
    this.gestureRecognizer = new GestureRecognizer()
    this.virtualKeyboard = new VirtualKeyboardManager((keyCode, scanCode) => {
      this.handleVirtualKeyPress(keyCode, scanCode)
    })
  }
  
  // 处理触摸事件
  handleTouchEvent(event: TouchEvent) {
    const gestureType = this.gestureRecognizer.recognizeGesture(event)
    
    if (gestureType) {
      this.handleGesture(gestureType, event)
    } else {
      // 普通触摸事件处理
      this.handleBasicTouch(event)
    }
  }
  
  // 处理手势
  private handleGesture(gestureType: GestureType, event: TouchEvent) {
    const touch = event.touches[0]
    
    switch (gestureType) {
      case GestureType.SINGLE_TAP:
        this.sendMouseClick(touch.x, touch.y, 1) // 左键单击
        break
      case GestureType.DOUBLE_TAP:
        this.sendMouseDoubleClick(touch.x, touch.y)
        break
      case GestureType.LONG_PRESS:
        this.sendMouseClick(touch.x, touch.y, 2) // 右键单击
        break
      case GestureType.PINCH:
        this.handlePinchGesture(event)
        break
      case GestureType.PAN:
        this.handlePanGesture(event)
        break
    }
  }
  
  // 处理基本触摸
  private handleBasicTouch(event: TouchEvent) {
    const touch = event.touches[0]
    const x = Math.floor(touch.x)
    const y = Math.floor(touch.y)
    
    let buttons = 0
    let flags = 0
    
    if (event.type === 0) { // TouchType.Down
      buttons = this.isRightClickMode ? 2 : 1
      flags = 0x8000
    } else if (event.type === 1) { // TouchType.Up
      buttons = 0
      flags = 0x0000
    } else if (event.type === 2) { // TouchType.Move
      buttons = this.isRightClickMode ? 2 : 1
      flags = 0x0800
    }
    
    this.sendInputEvent({
      type: 'mouse',
      x: x,
      y: y,
      button: buttons,
      flags: flags
    })
  }
  
  // 发送鼠标单击
  private sendMouseClick(x: number, y: number, button: number) {
    // 按下
    this.sendInputEvent({
      type: 'mouse',
      x: Math.floor(x),
      y: Math.floor(y),
      button: button,
      flags: 0x8000
    })
    
    // 释放
    setTimeout(() => {
      this.sendInputEvent({
        type: 'mouse',
        x: Math.floor(x),
        y: Math.floor(y),
        button: 0,
        flags: 0x0000
      })
    }, 50)
  }
  
  // 发送鼠标双击
  private sendMouseDoubleClick(x: number, y: number) {
    this.sendMouseClick(x, y, 1)
    setTimeout(() => {
      this.sendMouseClick(x, y, 1)
    }, 100)
  }
  
  // 处理缩放手势
  private handlePinchGesture(event: TouchEvent) {
    if (event.touches.length >= 2) {
      // 模拟鼠标滚轮缩放
      const centerX = (event.touches[0].x + event.touches[1].x) / 2
      const centerY = (event.touches[0].y + event.touches[1].y) / 2
      
      this.sendInputEvent({
        type: 'mouse',
        x: Math.floor(centerX),
        y: Math.floor(centerY),
        button: 4, // 滚轮
        flags: 0x0400 // 滚轮标志
      })
    }
  }
  
  // 处理拖拽手势
  private handlePanGesture(event: TouchEvent) {
    if (this.isScrollMode) {
      // 滚动模式
      const touch = event.touches[0]
      this.sendInputEvent({
        type: 'mouse',
        x: Math.floor(touch.x),
        y: Math.floor(touch.y),
        button: 4, // 滚轮
        flags: 0x0400
      })
    } else {
      // 普通拖拽
      this.handleBasicTouch(event)
    }
  }
  
  // 处理虚拟按键
  private handleVirtualKeyPress(keyCode: number, scanCode: number) {
    this.sendInputEvent({
      type: 'keyboard',
      keyCode: keyCode,
      scanCode: scanCode
    })
  }
  
  // 发送输入事件
  private sendInputEvent(event: InputEvent) {
    if (this.onInputEvent) {
      this.onInputEvent(event)
    }
  }
  
  // 切换右键模式
  toggleRightClickMode() {
    this.isRightClickMode = !this.isRightClickMode
  }
  
  // 切换滚动模式
  toggleScrollMode() {
    this.isScrollMode = !this.isScrollMode
  }
  
  // 显示虚拟键盘
  showVirtualKeyboard(layout: 'qwerty' | 'numeric' | 'symbols' = 'qwerty') {
    this.virtualKeyboard.show(layout)
  }
  
  // 隐藏虚拟键盘
  hideVirtualKeyboard() {
    this.virtualKeyboard.hide()
  }
  
  // 获取虚拟键盘状态
  getVirtualKeyboardState() {
    return this.virtualKeyboard.getState()
  }
  
  // 获取输入模式状态
  getInputModeState() {
    return {
      isRightClickMode: this.isRightClickMode,
      isScrollMode: this.isScrollMode
    }
  }
}