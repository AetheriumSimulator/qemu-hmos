/**
 * 存储路径常量和工具函数
 * 定义应用沙箱中的目录结构
 */
import fs from '@ohos.file.fs'
import hilog from '@ohos.hilog'
import common from '@ohos.app.ability.common'
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl'
import bundleManager from '@ohos.bundle.bundleManager'

/**
 * 目录结构说明：
 * 
 * 内部沙箱（不暴露给文件管理）:
 * /data/storage/el2/base/haps/entry/files/
 * ├── vms/                    # 内部目录
 * │   └── <vm-name>/
 * │       ├── disk.qcow2      # 虚拟磁盘
 * │       ├── config.json     # VM 配置
 * │       ├── qemu.log        # QEMU 日志
 * │       └── qmp.sock        # QMP 控制 socket
 * ├── isos/                   # ISO 镜像目录
 * ├── firmware/               # 固件文件
 * └── logs/                   # 应用日志
 * 
 * 公开目录（应用内，可通过分享功能导出）:
 * /data/storage/el2/base/haps/entry/files/public/
 * ├── .qemu_hmos_version      # 版本标记文件 (内容: "1.0")
 * ├── 日志/                   # 日志导出目录
 * │   └── <vm-name>-<timestamp>.log
 * ├── 虚拟机磁盘/             # VM 共享文件夹（映射到来宾）
 * │   └── <vm-name>/
 * └── OneDrive文件/           # OneDrive 同步目录（可选）
 * 
 * 注意：HarmonyOS 普通应用无法直接写入系统 Download 目录，
 * 需要系统级权限 (FILE_ACCESS_MANAGER)。用户可通过应用内的
 * "分享"功能将文件导出到其他位置。
 */

// 包名常量
const BUNDLE_NAME = 'com.cloudshin.aetherengine'

// VM 完整性检查结果接口
interface VmIntegrityResult {
  hasDir: boolean
  hasDisk: boolean
  hasConfig: boolean
  hasLog: boolean
  diskSize: number
}

// 存储统计接口
interface StorageStatsResult {
  vmsSize: number
  isosSize: number
  sharedSize: number
  totalSize: number
}

/** Stable diagnostics returned by exportVmLog for UI and support logs. */
export type VmLogExportStage =
  | 'success'
  | 'source_missing'
  | 'source_permission'
  | 'target_directory'
  | 'target_permission'
  | 'copy_failed'

export interface VmLogExportResult {
  ok: boolean
  stage: VmLogExportStage
  code: string
  message: string
  path?: string
}

interface StorageErrorLike {
  code?: number | string
  message?: string
}

interface StorageErrorDetails {
  code: string
  message: string
}

export class StoragePaths {
  private static importSequence: number = 0
  // 内部沙箱基础路径（不暴露给文件管理）
  static readonly INTERNAL_BASE = '/data/storage/el2/base/haps/entry/files'
  
  // 共享目录基础路径（文件管理可见）
  // 这是系统为应用创建的共享目录，文件管理器会自动识别
  static readonly SHARED_BASE = `/data/storage/el2/base/${BUNDLE_NAME}/files`
  
  // 内部目录（不暴露给文件管理）
  static readonly VMS_DIR = `${StoragePaths.INTERNAL_BASE}/vms`
  static readonly FIRMWARE_DIR = `${StoragePaths.INTERNAL_BASE}/firmware`
  static readonly LOGS_DIR = `${StoragePaths.INTERNAL_BASE}/logs`
  static readonly ISOS_DIR = `${StoragePaths.INTERNAL_BASE}/isos`
  
  // 共享目录（暴露给文件管理）
  static readonly SHARED_VM_DISKS = `${StoragePaths.SHARED_BASE}/虚拟机磁盘`
  static readonly SHARED_ONEDRIVE = `${StoragePaths.SHARED_BASE}/OneDrive文件`
  
  // 兼容旧路径
  static readonly BASE_PATH = StoragePaths.INTERNAL_BASE
  static readonly SHARED_DIR = StoragePaths.SHARED_VM_DISKS
  
  /**
   * 从 Context 获取实际的 filesDir（推荐使用）
   */
  static getFilesDir(context: common.Context): string {
    return context.filesDir
  }
  
  /**
   * 获取指定 VM 的目录路径
   */
  static getVmDir(vmName: string): string {
    return `${StoragePaths.VMS_DIR}/${vmName}`
  }
  
  /**
   * 获取指定 VM 的磁盘路径
   */
  static getVmDiskPath(vmName: string): string {
    return `${StoragePaths.getVmDir(vmName)}/disk.qcow2`
  }
  
  /**
   * 获取指定 VM 的配置文件路径
   */
  static getVmConfigPath(vmName: string): string {
    return `${StoragePaths.getVmDir(vmName)}/config.json`
  }
  
  /**
   * 获取指定 VM 的日志路径
   */
  static getVmLogPath(vmName: string): string {
    return `${StoragePaths.getVmDir(vmName)}/qemu.log`
  }
  
  /**
   * 获取指定 VM 的 QMP socket 路径
   */
  static getVmQmpPath(vmName: string): string {
    return `${StoragePaths.getVmDir(vmName)}/qmp.sock`
  }
  
  /**
   * 获取指定 VM 的共享目录路径（文件管理可见）
   */
  static getVmSharedDir(vmName: string): string {
    return `${StoragePaths.SHARED_VM_DISKS}/${vmName}`
  }
  
  /**
   * 确保所有必要的目录存在
   */
  static async ensureDirectories(): Promise<void> {
    // 内部目录
    const internalDirs = [
      StoragePaths.VMS_DIR,
      StoragePaths.ISOS_DIR,
      StoragePaths.FIRMWARE_DIR,
      StoragePaths.LOGS_DIR
    ]
    
    // 共享目录（文件管理可见）
    const sharedDirs = [
      StoragePaths.SHARED_BASE,
      StoragePaths.SHARED_VM_DISKS,
      StoragePaths.SHARED_ONEDRIVE
    ]
    
    for (const dir of internalDirs) {
      await StoragePaths.ensureDirectory(dir)
    }
    // Sharing is optional; its separate base may be unavailable on a device.
    for (const dir of sharedDirs) {
      try {
        await StoragePaths.ensureDirectory(dir)
      } catch (e) {
        hilog.warn(0x0000, 'STORAGE', '共享目录不可用: %{public}s', (e as Error).message)
      }
    }
  }

  private static async ensureDirectory(path: string): Promise<void> {
    try {
      await fs.mkdir(path, true)
    } catch (e) {
      // Only an existing directory is success. Permission/full-disk/file errors
      // must reach the caller before it publishes a VM or an imported path.
      if (!StoragePaths.isExistsError(e as Error)) throw new Error((e as Error).message)
    }
    const stat = await fs.stat(path)
    if (!stat.isDirectory()) throw new Error(`不是目录: ${path}`)
  }

  private static isExistsError(error: Error): boolean {
    const code = StoragePaths.errorDetails(error).code
    return code === '13900015' || code === 'EEXIST'
  }
  
  /**
   * 确保指定 VM 的目录存在
   */
  static async ensureVmDirectories(vmName: string): Promise<void> {
    await StoragePaths.ensureDirectories()
    await StoragePaths.ensureDirectory(StoragePaths.getVmDir(vmName))
    try {
      await StoragePaths.ensureDirectory(StoragePaths.getVmSharedDir(vmName))
    } catch (e) {
      hilog.warn(0x0000, 'STORAGE', 'VM 共享目录不可用: %{public}s', (e as Error).message)
    }
  }

  /** Reserve a new VM directory without ever reusing another VM's disk. */
  static async reserveVmName(requestedName: string, existingNames: string[]): Promise<string> {
    const base = requestedName.trim()
    if (!base || base === '.' || base === '..' || /[/\\\x00-\x1f]/.test(base)) {
      throw new Error('虚拟机名称不能包含路径分隔符或控制字符')
    }
    await StoragePaths.ensureDirectories()
    for (let index = 0; index < 1000; index++) {
      const name = index === 0 ? base : `${base} (${index + 1})`
      if (existingNames.includes(name)) continue
      try {
        // mkdir without recursion exclusively reserves the name, including
        // across overlapping callbacks and orphaned directories after a crash.
        await fs.mkdir(StoragePaths.getVmDir(name))
        return name
      } catch (e) {
        if (!StoragePaths.isExistsError(e as Error)) throw new Error((e as Error).message)
      }
    }
    throw new Error('无法分配虚拟机目录，请使用其他名称')
  }

  /** Picker URIs must be opened intact; stripping file:// loses their grant. */
  private static async copyImportedFile(source: string, target: string): Promise<number> {
    const input = await fs.open(source, fs.OpenMode.READ_ONLY)
    let copied = false
    try {
      const sourceStat = await fs.stat(input.fd)
      if (!sourceStat.isFile() || sourceStat.size <= 0) throw new Error('所选镜像为空或不是普通文件')
      await fs.copyFile(input.fd, target)
      const targetStat = await fs.stat(target)
      if (!targetStat.isFile() || targetStat.size !== sourceStat.size) {
        throw new Error('镜像复制不完整，请重试')
      }
      copied = true
      return targetStat.size
    } finally {
      try { await fs.close(input) } catch (e) {
        hilog.warn(0x0000, 'STORAGE', '关闭导入源失败: %{public}s', (e as Error).message)
      }
      if (!copied) {
        // target belongs to this import's exclusively reserved directory.
        try { await fs.unlink(target) } catch (_) { /* absent/failed partial copy */ }
      }
    }
  }

  static async importIso(source: string): Promise<string> {
    await StoragePaths.ensureDirectory(StoragePaths.ISOS_DIR)
    for (let attempt = 0; attempt < 1000; attempt++) {
      const token = `${Date.now()}-${StoragePaths.importSequence++}`
      const directory = `${StoragePaths.ISOS_DIR}/import-${token}`
      try {
        await fs.mkdir(directory)
      } catch (e) {
        if (StoragePaths.isExistsError(e as Error)) continue
        throw new Error((e as Error).message)
      }
      const target = `${directory}/image.iso`
      await StoragePaths.copyImportedFile(source, target)
      return target
    }
    throw new Error('无法分配 ISO 目录，请重试')
  }

  /** Only called for a directory allocated by reserveVmName in this creation. */
  static async importVmDisk(source: string, vmName: string): Promise<number> {
    await StoragePaths.ensureVmDirectories(vmName)
    const target = StoragePaths.getVmDiskPath(vmName)
    try {
      await fs.stat(target)
      throw new Error('目标磁盘已存在，拒绝覆盖')
    } catch (e) {
      if (!StoragePaths.isMissingError(e as Error)) throw new Error((e as Error).message)
    }
    return StoragePaths.copyImportedFile(source, target)
  }

  /** Validate old sandbox paths in place; only external legacy paths migrate. */
  static async prepareIso(source: string): Promise<string> {
    if (!source) return ''
    if (!source.startsWith(`${StoragePaths.ISOS_DIR}/`)) return StoragePaths.importIso(source)
    const stat = await fs.stat(source)
    if (!stat.isFile() || stat.size <= 0) throw new Error('ISO 文件不存在或为空，请重新选择')
    return source
  }


  /**
   * 检查并申请媒体读写权限
   */
  static async requestMediaPermissions(context: common.UIAbilityContext): Promise<boolean> {
    const permissionList: Permissions[] = [
      'ohos.permission.READ_MEDIA',
      'ohos.permission.WRITE_MEDIA',
      // 鸿蒙公开下载目录专用权限
      'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
    ]
    
    try {
      const atManager = abilityAccessCtrl.createAtManager()
      const bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      const tokenId = bundleInfo.appInfo.accessTokenId
      
      // 检查是否已有权限
      let allGranted = true
      for (const perm of permissionList) {
        const status = atManager.checkAccessTokenSync(tokenId, perm)
        if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          allGranted = false
          break
        }
      }
      
      if (allGranted) {
        hilog.info(0x0000, 'STORAGE', '媒体权限已授予')
        return true
      }
      
      // 动态申请权限
      hilog.info(0x0000, 'STORAGE', '申请媒体读写权限...')
      
      return new Promise<boolean>((resolve): void => {
        atManager.requestPermissionsFromUser(context, permissionList).then((result): void => {
          if (result && result.authResults) {
            for (let i = 0; i < result.authResults.length; i++) {
              if (result.authResults[i] !== 0) {
                hilog.error(0x0000, 'STORAGE', '权限被拒绝: %{public}s', permissionList[i])
                resolve(false)
                return
              }
            }
            hilog.info(0x0000, 'STORAGE', '媒体权限申请成功')
            resolve(true)
          } else {
            resolve(false)
          }
        }).catch((e: Error): void => {
          hilog.error(0x0000, 'STORAGE', '权限申请异常: %{public}s', e.message)
          resolve(false)
        })
      })
    } catch (e) {
      hilog.error(0x0000, 'STORAGE', '申请权限失败: %{public}s', (e as Error).message)
      return false
    }
  }
  
  /**
   * 获取公共 Downloads 目录下的应用子目录
   * 需要先调用 requestMediaPermissions 获取权限
   */
  static async getPublicAppDir(context?: common.UIAbilityContext): Promise<string> {
    try {
      // 尝试获取外部 Downloads 目录
      let downloadsDir: string | null = null
      const candidates: string[] = [
        // 通过 context 推测出来的 Download 目录
        context ? context.getApplicationContext().filesDir.replace('/files', '/Download') : '',
        '/storage/Users/currentUser/Download',
        '/storage/media/100/local/files/Download',
        '/data/storage/el2/base/files/Download'
      ]

      for (const path of candidates) {
        if (!path) continue
        try {
          await fs.access(path)
          downloadsDir = path
          hilog.info(0x0000, 'STORAGE', '找到 Download 目录: %{public}s', path)
          break
        } catch (_) {
          // 不存在或无权限，继续尝试下一个
        }
      }
      
      // 如果无法获取外部目录，使用沙箱内目录
      if (!downloadsDir) {
        downloadsDir = `${StoragePaths.INTERNAL_BASE}/public`
        hilog.info(0x0000, 'STORAGE', '使用沙箱内公开目录: %{public}s', downloadsDir)
      }
      
      const appDir = `${downloadsDir}/${BUNDLE_NAME}`
      
      // 确保目录存在
      try {
        await fs.access(appDir)
      } catch (_) {
        // 先确保父目录存在
        try {
          await fs.access(downloadsDir)
        } catch (_) {
          await fs.mkdir(downloadsDir)
        }
        await fs.mkdir(appDir)
        hilog.info(0x0000, 'STORAGE', '创建公开应用目录: %{public}s', appDir)
      }
      
      return appDir
    } catch (e) {
      const details = StoragePaths.errorDetails(e as Error)
      hilog.error(0x0000, 'STORAGE', '获取公开目录失败: %{public}s', details.message)
      throw new Error(`${details.code}: ${details.message}`)
    }
  }
  
  // 期望的公共目录结构（使用 ASCII 名称，避免编码导致创建失败）
  private static readonly EXPECTED_PUBLIC_STRUCTURE: string[] = ['logs', 'vm-disks', 'onedrive']
  
  // 目录结构版本（用于检测结构变更）
  private static readonly STRUCTURE_VERSION = '1.0'
  private static readonly VERSION_FILE = '.qemu_hmos_version'
  
  /**
   * 检查公共目录结构是否符合预期
   */
  private static async verifyPublicStructure(appDir: string): Promise<boolean> {
    try {
      // 检查版本文件
      const versionFile = `${appDir}/${StoragePaths.VERSION_FILE}`
      try {
        const file = await fs.open(versionFile, fs.OpenMode.READ_ONLY)
        const buf = new ArrayBuffer(64)
        const readLen = await fs.read(file.fd, buf)
        await fs.close(file)
        const version = String.fromCharCode(...new Uint8Array(buf.slice(0, readLen)))
        if (version.trim() !== StoragePaths.STRUCTURE_VERSION) {
          hilog.info(0x0000, 'STORAGE', '目录版本不匹配: %{public}s vs %{public}s', version.trim(), StoragePaths.STRUCTURE_VERSION)
          return false
        }
      } catch (_) {
        // 版本文件不存在
        return false
      }
      
      // 检查所有期望的子目录是否存在且是目录
      for (const sub of StoragePaths.EXPECTED_PUBLIC_STRUCTURE) {
        const subPath = `${appDir}/${sub}`
        try {
          const stat = await fs.stat(subPath)
          if (!stat.isDirectory()) {
            hilog.info(0x0000, 'STORAGE', '%{public}s 不是目录', subPath)
            return false
          }
        } catch (_) {
          hilog.info(0x0000, 'STORAGE', '子目录不存在: %{public}s', subPath)
          return false
        }
      }
      
      return true
    } catch (e) {
      hilog.error(0x0000, 'STORAGE', '验证目录结构失败: %{public}s', (e as Error).message)
      return false
    }
  }
  
  /**
   * 递归删除目录及其内容
   */
  private static async removeDir(path: string): Promise<void> {
    try {
      const stat = await fs.stat(path)
      if (stat.isDirectory()) {
        const entries = await fs.listFile(path)
        for (const entry of entries) {
          await StoragePaths.removeDir(`${path}/${entry}`)
        }
        await fs.rmdir(path)
      } else {
        await fs.unlink(path)
      }
    } catch (_) {
      // 忽略删除失败
    }
  }
  
  /**
   * 写入版本文件
   */
  private static async writeVersionFile(appDir: string): Promise<void> {
    try {
      const versionFile = `${appDir}/${StoragePaths.VERSION_FILE}`
      const file = await fs.open(versionFile, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      const content = StoragePaths.STRUCTURE_VERSION
      await fs.write(file.fd, content)
      await fs.close(file)
    } catch (e) {
      hilog.error(0x0000, 'STORAGE', '写入版本文件失败: %{public}s', (e as Error).message)
    }
  }
  
  /**
   * 初始化公共目录结构（应用启动时调用）
   * 如果目录结构不符合预期，会删除并重建
   * @param context 可选，传入则尝试使用系统 Download 目录
   */
  static async initPublicDirs(context?: common.UIAbilityContext): Promise<void> {
    hilog.info(0x0000, 'STORAGE', '========== 开始初始化公共目录 ==========')
    
    try {
      let appDir: string
      let usePublicDownload = false
      
      // 如果有 context，尝试申请权限并使用系统 Download 目录
      if (context) {
        const hasPermission = await StoragePaths.requestMediaPermissions(context)
        if (hasPermission) {
          // 公共 Download 目录路径
          // 鸿蒙系统的公共下载目录
          const possibleDownloadPaths = [
            '/storage/Users/currentUser/Download',
            '/data/storage/el2/base/files/Download',
            '/storage/media/100/local/files/Download'
          ]
          
          let downloadBase: string | null = null
          for (const path of possibleDownloadPaths) {
            try {
              await fs.access(path)
              downloadBase = path
              hilog.info(0x0000, 'STORAGE', '找到 Download 目录: %{public}s', path)
              break
            } catch (_) {
              hilog.info(0x0000, 'STORAGE', 'Download 目录不存在: %{public}s', path)
            }
          }
          
          if (downloadBase) {
            appDir = `${downloadBase}/${BUNDLE_NAME}`
            usePublicDownload = true
            hilog.info(0x0000, 'STORAGE', '使用公共 Download 目录: %{public}s', appDir)
          } else {
            hilog.warn(0x0000, 'STORAGE', '未找到公共 Download 目录，使用沙箱目录')
            appDir = `${StoragePaths.INTERNAL_BASE}/public`
          }
        } else {
          hilog.warn(0x0000, 'STORAGE', '媒体权限被拒绝，使用沙箱目录')
          appDir = `${StoragePaths.INTERNAL_BASE}/public`
        }
      } else {
        appDir = `${StoragePaths.INTERNAL_BASE}/public`
      }
      
      hilog.info(0x0000, 'STORAGE', '目标公开目录: %{public}s (公共=%{public}s)', appDir, String(usePublicDownload))
      
      // 检查应用目录是否存在
      let dirExists = false
      try {
        await fs.access(appDir)
        dirExists = true
        hilog.info(0x0000, 'STORAGE', '公开目录已存在: %{public}s', appDir)
      } catch (_) {
        dirExists = false
        hilog.info(0x0000, 'STORAGE', '公开目录不存在，需要创建: %{public}s', appDir)
      }
      
      // 如果目录存在，验证结构
      if (dirExists) {
        const isValid = await StoragePaths.verifyPublicStructure(appDir)
        if (!isValid) {
          hilog.info(0x0000, 'STORAGE', '目录结构不符合预期，删除并重建: %{public}s', appDir)
          await StoragePaths.removeDir(appDir)
          dirExists = false
        } else {
          hilog.info(0x0000, 'STORAGE', '目录结构验证通过: %{public}s', appDir)
          return
        }
      }
      
      // 创建主目录
      try {
        await fs.mkdir(appDir)
        hilog.info(0x0000, 'STORAGE', '成功创建公开目录: %{public}s', appDir)
      } catch (e) {
        hilog.error(0x0000, 'STORAGE', '创建公开目录失败: %{public}s, 错误: %{public}s', appDir, (e as Error).message)
        return
      }
      
      // 创建子目录
      for (const sub of StoragePaths.EXPECTED_PUBLIC_STRUCTURE) {
        const subPath = `${appDir}/${sub}`
        try {
          await fs.mkdir(subPath)
          hilog.info(0x0000, 'STORAGE', '成功创建子目录: %{public}s', subPath)
        } catch (e) {
          hilog.error(0x0000, 'STORAGE', '创建子目录失败: %{public}s, 错误: %{public}s', subPath, (e as Error).message)
        }
      }
      
      // 写入版本文件
      await StoragePaths.writeVersionFile(appDir)
      
      hilog.info(0x0000, 'STORAGE', '========== 公共目录初始化完成 ==========')
      hilog.info(0x0000, 'STORAGE', '路径: %{public}s', appDir)
    } catch (e) {
      hilog.error(0x0000, 'STORAGE', '初始化公共目录失败: %{public}s', (e as Error).message)
    }
  }

  private static errorDetails(error: Error): StorageErrorDetails {
    const candidate = error as StorageErrorLike
    const code = candidate && candidate.code !== undefined ? String(candidate.code) : ''
    const message = candidate && candidate.message ? candidate.message : String(error)
    return { code, message }
  }

  private static isMissingError(error: Error): boolean {
    const details = StoragePaths.errorDetails(error)
    const value = `${details.code} ${details.message}`.toLowerCase()
    return value.includes('enoent') || value.includes('13900002') ||
      value.includes('no such file') || value.includes('not found') ||
      value.includes('does not exist') || value.includes('不存在')
  }

  private static isPermissionError(error: Error): boolean {
    const details = StoragePaths.errorDetails(error)
    const value = `${details.code} ${details.message}`.toLowerCase()
    return value.includes('eacces') || value.includes('eperm') ||
      value.includes('13900013') || value.includes('13900012') ||
      value.includes('permission') || value.includes('denied') ||
      value.includes('not permitted') || value.includes('readonly')
  }

  private static exportFailure(stage: VmLogExportStage, message: string): VmLogExportResult {
    return {
      ok: false,
      stage,
      code: `VM_LOG_${stage.toUpperCase()}`,
      message
    }
  }

  /**
   * 导出指定 VM 的 qemu.log 到公共 Download/com.cloudshin.aetherengine/日志 目录
   * 返回带稳定阶段码的结果，供 UI 显示可操作的错误信息。
   */
  static async exportVmLog(context: common.Context, vmName: string): Promise<VmLogExportResult> {
    const src = StoragePaths.getVmLogPath(vmName)
    try {
      await fs.access(src)
    } catch (e) {
      const details = StoragePaths.errorDetails(e as Error)
      const stage: VmLogExportStage = StoragePaths.isMissingError(e as Error) ? 'source_missing' : 'source_permission'
      const message = stage === 'source_missing'
        ? '源日志不存在，请先启动虚拟机并重试'
        : '无法读取源日志，请检查应用文件权限'
      hilog.error(0x0000, 'STORAGE', '导出阶段=%{public}s code=%{public}s path=%{public}s detail=%{public}s',
        stage, `VM_LOG_${stage.toUpperCase()}`, src, details.message)
      return StoragePaths.exportFailure(stage, message)
    }

    let appDir: string
    try {
      appDir = await StoragePaths.getPublicAppDir()
    } catch (e) {
      const stage: VmLogExportStage = StoragePaths.isPermissionError(e as Error) ? 'target_permission' : 'target_directory'
      const message = stage === 'target_permission'
        ? '无法写入导出目录，请授予存储权限'
        : '无法准备导出目录，请检查存储空间和目录状态'
      const details = StoragePaths.errorDetails(e as Error)
      hilog.error(0x0000, 'STORAGE', '导出阶段=%{public}s code=%{public}s detail=%{public}s',
        stage, `VM_LOG_${stage.toUpperCase()}`, details.message)
      return StoragePaths.exportFailure(stage, message)
    }

    const logsDir = `${appDir}/logs`
    try {
      await fs.access(logsDir)
    } catch (e) {
      if (!StoragePaths.isMissingError(e as Error)) {
        const details = StoragePaths.errorDetails(e as Error)
        const stage: VmLogExportStage = StoragePaths.isPermissionError(e as Error) ? 'target_permission' : 'target_directory'
        const message = stage === 'target_permission'
          ? '无法访问导出目录，请检查存储权限'
          : '无法访问导出目录，请检查目录状态'
        hilog.error(0x0000, 'STORAGE', '导出阶段=%{public}s code=%{public}s detail=%{public}s',
          stage, `VM_LOG_${stage.toUpperCase()}`, details.message)
        return StoragePaths.exportFailure(stage, message)
      }
      try {
        await fs.mkdir(logsDir)
      } catch (mkdirError) {
        const stage: VmLogExportStage = StoragePaths.isPermissionError(mkdirError as Error) ? 'target_permission' : 'target_directory'
        const message = stage === 'target_permission'
          ? '无法创建导出目录，请授予存储权限'
          : '无法创建导出目录，请检查存储空间和目录状态'
        const details = StoragePaths.errorDetails(mkdirError as Error)
        hilog.error(0x0000, 'STORAGE', '导出阶段=%{public}s code=%{public}s detail=%{public}s',
          stage, `VM_LOG_${stage.toUpperCase()}`, details.message)
        return StoragePaths.exportFailure(stage, message)
      }
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-')
    const safeName = vmName.replace(/[^\w.-]/g, '_')
    const dst = `${logsDir}/${safeName}-${timestamp}.log`
    try {
      await fs.copyFile(src, dst)
    } catch (e) {
      const details = StoragePaths.errorDetails(e as Error)
      hilog.error(0x0000, 'STORAGE', '导出阶段=copy_failed code=VM_LOG_COPY_FAILED detail=%{public}s', details.message)
      return StoragePaths.exportFailure('copy_failed', '复制日志失败，请重试或检查存储空间')
    }

    hilog.info(0x0000, 'STORAGE', '导出阶段=success code=VM_LOG_SUCCESS path=%{public}s', dst)
    return { ok: true, stage: 'success', code: 'VM_LOG_SUCCESS', message: '日志导出成功', path: dst }
  }

  /**
   * 检查 VM 目录完整性
   */
  static async checkVmIntegrity(vmName: string): Promise<VmIntegrityResult> {
    const result: VmIntegrityResult = {
      hasDir: false,
      hasDisk: false,
      hasConfig: false,
      hasLog: false,
      diskSize: 0
    }
    
    try {
      const vmDir = StoragePaths.getVmDir(vmName)
      await fs.access(vmDir)
      result.hasDir = true
      
      // 检查磁盘
      const diskPath = StoragePaths.getVmDiskPath(vmName)
      try {
        const diskStat = await fs.stat(diskPath)
        result.hasDisk = true
        result.diskSize = diskStat.size
      } catch (_) { }
      
      // 检查配置
      try {
        await fs.access(StoragePaths.getVmConfigPath(vmName))
        result.hasConfig = true
      } catch (_) { }
      
      // 检查日志
      try {
        await fs.access(StoragePaths.getVmLogPath(vmName))
        result.hasLog = true
      } catch (_) { }
      
    } catch (e) {
      // 目录不存在
    }
    
    return result
  }
  
  /**
   * 删除 VM 的所有文件（包括磁盘、配置、日志）
   */
  static async deleteVmFiles(vmName: string): Promise<boolean> {
    try {
      const vmDir = StoragePaths.getVmDir(vmName)
      const sharedDir = StoragePaths.getVmSharedDir(vmName)
      
      // 删除 VM 目录
      try {
        await fs.rmdir(vmDir)
        hilog.info(0x0000, 'STORAGE', '删除 VM 目录: %{public}s', vmDir)
      } catch (e) {
        // 尝试递归删除
        try {
          const files = await fs.listFile(vmDir)
          for (const file of files) {
            await fs.unlink(`${vmDir}/${file}`)
          }
          await fs.rmdir(vmDir)
        } catch (_) { }
      }
      
      // 删除共享目录
      try {
        await fs.rmdir(sharedDir)
        hilog.info(0x0000, 'STORAGE', '删除共享目录: %{public}s', sharedDir)
      } catch (_) { }
      
      return true
    } catch (e) {
      hilog.error(0x0000, 'STORAGE', '删除 VM 文件失败: %{public}s', (e as Error).message)
      return false
    }
  }
  
  /**
   * 获取存储使用统计
   */
  static async getStorageStats(): Promise<StorageStatsResult> {
    const stats: StorageStatsResult = {
      vmsSize: 0,
      isosSize: 0,
      sharedSize: 0,
      totalSize: 0
    }
    
    // 计算 VMs 目录大小
    try {
      const vmDirs = await fs.listFile(StoragePaths.VMS_DIR)
      for (const vmDir of vmDirs) {
        try {
          const files = await fs.listFile(`${StoragePaths.VMS_DIR}/${vmDir}`)
          for (const file of files) {
            try {
              const stat = await fs.stat(`${StoragePaths.VMS_DIR}/${vmDir}/${file}`)
              stats.vmsSize += stat.size
            } catch (_) { }
          }
        } catch (_) { }
      }
    } catch (_) { }
    
    // 计算 ISOs 目录大小
    try {
      const isoFiles = await fs.listFile(StoragePaths.ISOS_DIR)
      for (const file of isoFiles) {
        try {
          const stat = await fs.stat(`${StoragePaths.ISOS_DIR}/${file}`)
          stats.isosSize += stat.size
        } catch (_) { }
      }
    } catch (_) { }
    
    // 计算共享目录大小
    try {
      const sharedDirs = await fs.listFile(StoragePaths.SHARED_DIR)
      for (const dir of sharedDirs) {
        try {
          const files = await fs.listFile(`${StoragePaths.SHARED_DIR}/${dir}`)
          for (const file of files) {
            try {
              const stat = await fs.stat(`${StoragePaths.SHARED_DIR}/${dir}/${file}`)
              stats.sharedSize += stat.size
            } catch (_) { }
          }
        } catch (_) { }
      }
    } catch (_) { }
    
    stats.totalSize = stats.vmsSize + stats.isosSize + stats.sharedSize
    return stats
  }
}
