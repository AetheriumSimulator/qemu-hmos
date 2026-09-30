/**
 * OneDrive 文件管理器
 * 管理从 VM 的 OneDrive 到鸿蒙沙箱的文件传输
 * 
 * 数据流:
 * 云端 OneDrive ↔ VM 里的 OneDrive 客户端 ↔ 鸿蒙 App 沙箱
 * 
 * 两种传输方式:
 * 共享文件夹 - 用户在 VM 里手动复制到 virtio-9p 挂载点
 */

import fs from '@ohos.file.fs';

// OneDrive 同步状态
export enum OneDriveSyncStatus {
  IDLE = 'idle',
  SYNCING = 'syncing',
  COMPLETED = 'completed',
  ERROR = 'error'
}

// OneDrive 文件信息
export interface OneDriveFile {
  name: string;
  path: string;
  size: number;
  modifiedTime: Date;
  isDirectory: boolean;
  syncStatus: OneDriveSyncStatus;
}

// 传输模式
export enum TransferMode {
  SHARED_FOLDER = 'shared_folder'   // 通过 virtio-9p 共享文件夹
}

// OneDrive 配置
export interface OneDriveConfig {
  enabled: boolean;
  preferredMode: TransferMode;
  cachePath: string;
  autoSync: boolean;
  maxCacheSize: number;  // MB
}

export class OneDriveManager {
  private static instance: OneDriveManager;
  private config: OneDriveConfig;
  private cachedFiles: Map<string, OneDriveFile> = new Map();

  private constructor() {
    this.config = {
      enabled: true,
      preferredMode: TransferMode.SHARED_FOLDER,
      cachePath: '/data/storage/el2/base/files/onedrive',
      autoSync: false,
      maxCacheSize: 1024  // 1GB
    };
  }

  public static getInstance(): OneDriveManager {
    if (!OneDriveManager.instance) {
      OneDriveManager.instance = new OneDriveManager();
    }
    return OneDriveManager.instance;
  }

  /**
   * 初始化 OneDrive 缓存
   */
  public async initialize(): Promise<boolean> {
    try {
      // 初始化缓存目录
      try { fs.mkdirSync(this.config.cachePath); } catch (_) { /* already exists */ }
      
      // 扫描现有缓存文件
      await this.scanCacheDirectory();
      
      console.info('[OneDriveManager] Initialized successfully');
      return true;
    } catch (e) {
      console.error('[OneDriveManager] Initialization failed:', e);
      return false;
    }
  }

  /**
   * 获取配置
   */
  public getConfig(): OneDriveConfig {
    return { ...this.config };
  }

  /**
   * 更新配置
   */
  public updateConfig(config: Partial<OneDriveConfig>): void {
    this.config = { ...this.config, ...config };
  }

  /**
   * 获取缓存的 OneDrive 文件列表
   */
  public getCachedFiles(): OneDriveFile[] {
    return Array.from(this.cachedFiles.values());
  }

  /**
   * 从 VM 的 OneDrive 导入文件到鸿蒙沙箱
   * 用户需要先在 VM 里把文件复制到共享文件夹
   */
  public async importFromVMShared(vmName: string, fileName: string): Promise<boolean> {
    try {
      console.info(`[OneDriveManager] Importing ${fileName} from VM ${vmName}`);
      
      // 从 VM 共享目录复制到 OneDrive 缓存
      const success = false;
      console.warn(`[OneDriveManager] VM shared-folder import requires manual copy: ${vmName}/${fileName}`);
      
      if (success) {
        // 更新缓存文件列表
        await this.scanCacheDirectory();
        console.info(`[OneDriveManager] Import successful: ${fileName}`);
      }
      
      return success;
    } catch (e) {
      console.error('[OneDriveManager] Import failed:', e);
      return false;
    }
  }

  /**
   * 导出文件到 VM 的共享文件夹
   * 然后用户可以在 VM 里把文件拖到 OneDrive
   */
  public async exportToVMShared(vmName: string, fileName: string): Promise<boolean> {
    try {
      console.info(`[OneDriveManager] Exporting ${fileName} to VM ${vmName}`);
      
      const sourcePath = `${this.config.cachePath}/${fileName}`;
      
      // 复制到 VM 共享目录
      const success = false;
      console.warn(`[OneDriveManager] VM shared-folder export requires manual copy: ${vmName}/${fileName}`);
      
      if (success) {
        console.info(`[OneDriveManager] Export successful: ${fileName}`);
      }
      
      return success;
    } catch (e) {
      console.error('[OneDriveManager] Export failed:', e);
      return false;
    }
  }

  /**
   * 获取 Virtio-9p 挂载后在 VM 中的路径
   */
  public getVirtio9pMountPoint(): string {
    // 用户需要在 Windows VM 中执行:
    // net use O: \\10.0.2.4\onedrive
    // 或在 Linux VM 中:
    // mount -t 9p -o trans=virtio onedrive /mnt/onedrive
    return 'O:';  // 建议的盘符
  }

  /**
   * 获取 VM 内访问 OneDrive 缓存的说明
   */
  public getAccessInstructions(_mode: TransferMode): string[] {
    return [
      '1. 在虚拟机中打开命令提示符（管理员）',
      '2. 执行: net use O: \\10.0.2.4\shared',
      '3. 打开 O: 盘即可访问共享文件夹',
      '4. 将 OneDrive 中的文件复制到 O: 盘',
      '5. 文件将同步到鸿蒙设备的 OneDrive 缓存目录'
    ];
  }

  /**
   * 删除缓存文件
   */
  public async deleteCachedFile(fileName: string): Promise<boolean> {
    try {
      const filePath = `${this.config.cachePath}/${fileName}`;
      fs.unlinkSync(filePath);
      this.cachedFiles.delete(fileName);
      console.info(`[OneDriveManager] Deleted cached file: ${fileName}`);
      return true;
    } catch (e) {
      console.error('[OneDriveManager] Delete failed:', e);
      return false;
    }
  }

  /**
   * 清空缓存
   */
  public async clearCache(): Promise<boolean> {
    try {
      const files: string[] = fs.listFileSync(this.config.cachePath);
      for (const file of files) {
        await this.deleteCachedFile(file);
      }
      console.info('[OneDriveManager] Cache cleared');
      return true;
    } catch (e) {
      console.error('[OneDriveManager] Clear cache failed:', e);
      return false;
    }
  }

  /**
   * 获取缓存大小 (MB)
   */
  public getCacheSize(): number {
    let totalSize = 0;
    for (const file of this.cachedFiles.values()) {
      totalSize += file.size;
    }
    return totalSize / (1024 * 1024);
  }

  /**
   * 检查缓存是否超过限制
   */
  public isCacheFull(): boolean {
    return this.getCacheSize() >= this.config.maxCacheSize;
  }

  /**
   * 获取诊断信息
   */
  public getDiagnostics(): string[] {
    const diagnostics: string[] = [];
    
    diagnostics.push(`OneDrive 集成: ${this.config.enabled ? '启用' : '禁用'}`);
    diagnostics.push(`首选模式: ${this.config.preferredMode}`);
    diagnostics.push(`缓存路径: ${this.config.cachePath}`);
    diagnostics.push(`自动同步: ${this.config.autoSync ? '启用' : '禁用'}`);
    diagnostics.push(`缓存大小: ${this.getCacheSize().toFixed(2)} MB / ${this.config.maxCacheSize} MB`);
    diagnostics.push(`缓存文件数: ${this.cachedFiles.size}`);
    
    return diagnostics;
  }

  // === 私有方法 ===

  /**
   * 扫描缓存目录
   */
  private async scanCacheDirectory(): Promise<void> {
    try {
      this.cachedFiles.clear();
      
      const files: string[] = fs.listFileSync(this.config.cachePath);
      for (const fileName of files) {
        const filePath = `${this.config.cachePath}/${fileName}`;
        try {
          const stat = fs.statSync(filePath);
          const file: OneDriveFile = {
            name: fileName,
            path: filePath,
            size: stat.size,
            modifiedTime: new Date(stat.mtime),
            isDirectory: stat.isDirectory(),
            syncStatus: OneDriveSyncStatus.COMPLETED
          };
          this.cachedFiles.set(fileName, file);
        } catch (e) {
          console.warn(`[OneDriveManager] Failed to stat file: ${fileName}`);
        }
      }
      
      console.info(`[OneDriveManager] Scanned ${this.cachedFiles.size} files in cache`);
    } catch (e) {
      console.error('[OneDriveManager] Scan failed:', e);
    }
  }
}
