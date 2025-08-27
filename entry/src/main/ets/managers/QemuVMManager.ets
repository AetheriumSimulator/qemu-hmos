/**
 * QEMU虚拟机管理器
 * 使用Worker线程替代fork/exec方式
 */

import worker from '@ohos.worker'

interface QemuWorkerMessage {
  command: 'start_vm' | 'stop_vm' | 'pause_vm' | 'resume_vm' | 'get_status'
  vmConfig?: any
  vmId?: string
}

interface QemuWorkerResponse {
  success: boolean
  message: string
  vmId?: string
  status?: string
  data?: any
}

export class QemuVMManager {
  private static instance: QemuVMManager
  private worker: worker.ThreadWorker | null = null
  private vmStatusCallbacks: Map<string, (status: string) => void> = new Map()
  
  static getInstance(): QemuVMManager {
    if (!QemuVMManager.instance) {
      QemuVMManager.instance = new QemuVMManager()
    }
    return QemuVMManager.instance
  }
  
  private constructor() {
    this.initWorker()
  }
  
  private initWorker() {
    try {
      // 创建Worker线程
      this.worker = new worker.ThreadWorker('entry/ets/workers/qemu_worker.ts')
      
      // 监听Worker消息
      this.worker.onmessage = (event) => {
        const response = event.data as QemuWorkerResponse
        this.handleWorkerResponse(response)
      }
      
      // Worker错误处理
      this.worker.onerror = (error) => {
        console.error('[QemuVMManager] Worker错误:', error)
      }
      
      console.info('[QemuVMManager] Worker初始化成功')
    } catch (error) {
      console.error('[QemuVMManager] Worker初始化失败:', error)
    }
  }
  
  private handleWorkerResponse(response: QemuWorkerResponse) {
    console.info('[QemuVMManager] 收到Worker响应:', JSON.stringify(response))
    
    // 如果是状态更新，调用相应的回调
    if (response.vmId && response.status) {
      const callback = this.vmStatusCallbacks.get(response.vmId)
      if (callback) {
        callback(response.status)
      }
    }
  }
  
  /**
   * 启动虚拟机
   */
  async startVM(vmConfig: any): Promise<{ success: boolean; vmId?: string; message: string }> {
    return new Promise((resolve) => {
      if (!this.worker) {
        resolve({ success: false, message: 'Worker未初始化' })
        return
      }
      
      const message: QemuWorkerMessage = {
        command: 'start_vm',
        vmConfig: vmConfig
      }
      
      // 发送启动命令
      this.worker.postMessage(message)
      
      // 设置响应处理（简化版，实际应该用Promise链）
      const originalHandler = this.worker.onmessage
      this.worker.onmessage = (event) => {
        const response = event.data as QemuWorkerResponse
        if (response.success && response.vmId) {
          resolve({
            success: true,
            vmId: response.vmId,
            message: response.message
          })
        } else {
          resolve({
            success: false,
            message: response.message
          })
        }
        // 恢复原始处理器
        this.worker!.onmessage = originalHandler
      }
    })
  }
  
  /**
   * 停止虚拟机
   */
  async stopVM(vmId: string): Promise<{ success: boolean; message: string }> {
    return new Promise((resolve) => {
      if (!this.worker) {
        resolve({ success: false, message: 'Worker未初始化' })
        return
      }
      
      const message: QemuWorkerMessage = {
        command: 'stop_vm',
        vmId: vmId
      }
      
      this.worker.postMessage(message)
      
      const originalHandler = this.worker.onmessage
      this.worker.onmessage = (event) => {
        const response = event.data as QemuWorkerResponse
        resolve({
          success: response.success,
          message: response.message
        })
        this.worker!.onmessage = originalHandler
      }
    })
  }
  
  /**
   * 暂停虚拟机
   */
  async pauseVM(vmId: string): Promise<{ success: boolean; message: string }> {
    return this.sendVMCommand('pause_vm', vmId)
  }
  
  /**
   * 恢复虚拟机
   */
  async resumeVM(vmId: string): Promise<{ success: boolean; message: string }> {
    return this.sendVMCommand('resume_vm', vmId)
  }
  
  /**
   * 获取虚拟机状态
   */
  async getVMStatus(vmId: string): Promise<{ success: boolean; status?: string; data?: any; message: string }> {
    return new Promise((resolve) => {
      if (!this.worker) {
        resolve({ success: false, message: 'Worker未初始化' })
        return
      }
      
      const message: QemuWorkerMessage = {
        command: 'get_status',
        vmId: vmId
      }
      
      this.worker.postMessage(message)
      
      const originalHandler = this.worker.onmessage
      this.worker.onmessage = (event) => {
        const response = event.data as QemuWorkerResponse
        resolve({
          success: response.success,
          status: response.status,
          data: response.data,
          message: response.message
        })
        this.worker!.onmessage = originalHandler
      }
    })
  }
  
  /**
   * 注册虚拟机状态变化回调
   */
  onVMStatusChange(vmId: string, callback: (status: string) => void) {
    this.vmStatusCallbacks.set(vmId, callback)
  }
  
  /**
   * 移除虚拟机状态回调
   */
  removeVMStatusCallback(vmId: string) {
    this.vmStatusCallbacks.delete(vmId)
  }
  
  private async sendVMCommand(command: string, vmId: string): Promise<{ success: boolean; message: string }> {
    return new Promise((resolve) => {
      if (!this.worker) {
        resolve({ success: false, message: 'Worker未初始化' })
        return
      }
      
      const message: QemuWorkerMessage = {
        command: command as any,
        vmId: vmId
      }
      
      this.worker.postMessage(message)
      
      const originalHandler = this.worker.onmessage
      this.worker.onmessage = (event) => {
        const response = event.data as QemuWorkerResponse
        resolve({
          success: response.success,
          message: response.message
        })
        this.worker!.onmessage = originalHandler
      }
    })
  }
  
  /**
   * 销毁Worker
   */
  destroy() {
    if (this.worker) {
      this.worker.terminate()
      this.worker = null
    }
    this.vmStatusCallbacks.clear()
  }
}